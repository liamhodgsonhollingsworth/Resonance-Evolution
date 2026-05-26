"""
SessionManager — spawn / send / resume / archive Claude Code sessions
running in stream-json mode.

The Python sibling of the cockpit's TypeScript SessionManager at
[cockpit/src/main/session_manager.ts](../../../../../Alethea/.claude/worktrees/nervous-lalande-93b4ea/cockpit/src/main/session_manager.ts)
in the cockpit worktree; same CLI invocation, same three output channels
(communication / activity / diagnostic), same per-session silence watchdog.

Per the feasibility audit (CLI 2.1.87 schema):

    claude --print --output-format stream-json --input-format stream-json
           --include-partial-messages --verbose
           --permission-mode auto --session-id <uuid>

`--verbose` is REQUIRED with stream-json output or claude exits with an
error. We generate a UUID up-front and pass it via `--session-id` so resume
is reliable across restarts. On Windows the binary is `claude.cmd`; we use
shutil.which to find the right shim.

Output channels:

1. `communication` — text content from `assistant.message.content[type=text]`.
   This is what the chat user sees in the shell.
2. `activity` — tool_use events, lifecycle pings, end-of-turn markers,
   stderr lines, unknown event types. The workflow shell shows these in a
   secondary "activity" feed.
3. `diagnostic` — every raw stream-json line, appended to
   `state/raw_logs/<session_id>.jsonl`. Surfaces parse drift when claude's
   CLI schema changes.

Threading model: each session has a reader thread that pulls lines from
the subprocess's stdout and pushes events to the shared
`event_queue`. The shell consumes the queue from the main thread. stdin
writes are direct (no thread); they block briefly while the kernel queues
the write to the subprocess. The watchdog runs on a single shared timer
thread (one per SessionManager instance) that fires every 30s and emits
`silent_too_long` for any session that hasn't produced text in 5 minutes.

Failure modes covered:
- `claude` binary not on PATH → spawn raises `SessionError`; shell surfaces
  the error and refuses to spawn that session.
- subprocess crashes mid-conversation → exit handler fires `session_error`
  with the exit code, status flips to `error`.
- stream-json schema drift (unknown event types) → emitted as
  `activity` events with the unknown type recorded; the parser doesn't
  crash on novel shapes.
- non-JSON noise on stdout → silently dropped (claude occasionally emits
  blank lines or non-JSON status during init).
"""

from __future__ import annotations

import ctypes
import json
import logging
import os
import platform
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


_log = logging.getLogger(__name__)


# ----- public types -----


@dataclass
class SessionRecord:
    """Persistent description of a Claude Code session."""

    id: str
    display_name: str
    session_type: str
    status: str  # "spawning" | "active" | "idle" | "error" | "archived"
    cwd: str
    spawned_at: str
    last_active_at: str
    concerns: List[str] = field(default_factory=list)
    pid: Optional[int] = None


@dataclass
class SessionEvent:
    """One event emitted by the SessionManager to the consumer queue."""

    kind: str  # see EVENT_KINDS
    session_id: str
    session_display_name: str
    payload: Dict[str, Any] = field(default_factory=dict)
    ts: float = field(default_factory=time.time)


EVENT_KINDS = (
    "spawned",
    "communication",
    "activity",
    "tool_use",
    "tool_result",
    "turn_complete",
    "session_idle",
    "session_error",
    "archived",
    "silent_too_long",
)


class SessionError(RuntimeError):
    """Raised on spawn / send failures the caller should report."""


# ----- internal state -----


@dataclass
class _Internal:
    """Live state per session, not persisted."""

    record: SessionRecord
    child: Optional[subprocess.Popen] = None
    raw_log: Optional[Any] = None  # file handle
    reader_thread: Optional[threading.Thread] = None
    stderr_thread: Optional[threading.Thread] = None
    partials: Dict[str, str] = field(default_factory=dict)
    last_text_at: float = field(default_factory=time.time)


CLAUDE_BIN_ENV = "CLAUDE_BIN"
SILENT_THRESHOLD_S = 5 * 60  # 5 min — matches cockpit V4 watchdog
DEFAULT_PERMISSION_MODE = "bypassPermissions"


# ----- SessionManager -----


class SessionManager:
    """
    Spawn, send to, and reactivate Claude Code sessions.

    Events surface on an internal `queue.Queue[SessionEvent]`; consumers
    drain it via `drain_events()` from a single thread (typically the
    shell's main loop).
    """

    def __init__(
        self,
        state_dir: Path,
        claude_bin: Optional[str] = None,
        on_event: Optional[Callable[[SessionEvent], None]] = None,
    ):
        self.state_dir = Path(state_dir)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.sessions_dir = self.state_dir / "sessions"
        self.sessions_dir.mkdir(exist_ok=True)
        self.raw_logs_dir = self.state_dir / "raw_logs"
        self.raw_logs_dir.mkdir(exist_ok=True)
        self.archive_dir = self.state_dir / "archive"
        self.archive_dir.mkdir(exist_ok=True)

        self.claude_bin = claude_bin or os.environ.get(CLAUDE_BIN_ENV) or _detect_claude()
        self.event_queue: "queue.Queue[SessionEvent]" = queue.Queue()
        self.on_event = on_event  # optional sync callback (in addition to queue)
        self._sessions: Dict[str, _Internal] = {}
        self._lock = threading.Lock()
        self._watchdog_stop = threading.Event()
        self._watchdog_thread = threading.Thread(target=self._watchdog_loop, daemon=True)
        self._watchdog_thread.start()

    # ----- discovery / lifecycle -----

    def list(self) -> List[SessionRecord]:
        self._hydrate()
        with self._lock:
            return [s.record for s in self._sessions.values()]

    def get(self, session_id: str) -> Optional[SessionRecord]:
        with self._lock:
            s = self._sessions.get(session_id)
        return s.record if s else None

    def _hydrate(self) -> None:
        """Load any persisted session records from disk."""
        for json_file in self.sessions_dir.glob("*.json"):
            sid = json_file.stem
            with self._lock:
                if sid in self._sessions:
                    continue
            try:
                data = json.loads(json_file.read_text())
                rec = SessionRecord(**data)
                # Loaded from disk → idle until reactivated (unless archived).
                if rec.status != "archived":
                    rec.status = "idle"
                with self._lock:
                    self._sessions[sid] = _Internal(record=rec)
            except Exception:
                continue  # skip malformed

    def _persist(self, rec: SessionRecord) -> None:
        path = self.sessions_dir / f"{rec.id}.json"
        path.write_text(json.dumps(asdict(rec), indent=2))

    # ----- spawn / send / reactivate / archive -----

    def spawn(
        self,
        session_type: str,
        display_name: Optional[str] = None,
        seed_message: Optional[str] = None,
        cwd: Optional[Path] = None,
        concerns: Optional[List[str]] = None,
    ) -> SessionRecord:
        sid = str(uuid.uuid4())
        display = display_name or f"{session_type}-{sid[:8]}"
        cwd_path = str(cwd or Path.cwd())
        now = _iso_now()
        rec = SessionRecord(
            id=sid,
            display_name=display,
            session_type=session_type,
            status="spawning",
            cwd=cwd_path,
            spawned_at=now,
            last_active_at=now,
            concerns=concerns or [],
        )
        internal = _Internal(record=rec)
        with self._lock:
            self._sessions[sid] = internal
        self._persist(rec)
        self._launch(internal, seed_message=seed_message, resume=False)
        # SPEC-079: register the session in the cross-process active
        # registry so other sessions can discover it. Soft-fail: a
        # registry write error must not block the spawn.
        try:
            from tools.active_sessions import register_session
            register_session(
                rec.id,
                project=_project_slug_for_cwd(cwd_path),
                session_type=session_type,
                focus=display,
                pid=internal.child.pid if internal.child is not None else None,
                cwd=cwd_path,
                state_dir=self.state_dir,
            )
        except Exception:
            pass
        return rec

    def send(self, session_id: str, body: str) -> None:
        # Cross-process hydration: a fresh SessionManager has no entries
        # in _sessions until _hydrate() reads sessions/*.json. Without
        # this, a website-bridge-side session.send fails with "Unknown
        # session" for any session it did not spawn itself. Surfaced
        # 2026-05-26 Phase 1b functional verification (SPEC-148).
        self._hydrate()
        with self._lock:
            s = self._sessions.get(session_id)
        if s is None:
            raise SessionError(f"Unknown session: {session_id}")
        if s.child is None or s.child.poll() is not None:
            self._launch(s, seed_message=None, resume=True)
            with self._lock:
                s = self._sessions[session_id]
        envelope = {"type": "user", "message": {"role": "user", "content": body}}
        line = json.dumps(envelope) + "\n"
        try:
            assert s.child is not None and s.child.stdin is not None
            s.child.stdin.write(line)
            s.child.stdin.flush()
        except (BrokenPipeError, AssertionError) as exc:
            raise SessionError(f"send to {session_id} failed: {exc}") from exc
        s.last_text_at = time.time()
        s.record.last_active_at = _iso_now()
        self._persist(s.record)

    def reactivate(self, session_id: str) -> SessionRecord:
        # Cross-process hydration; same rationale as send / archive.
        self._hydrate()
        with self._lock:
            s = self._sessions.get(session_id)
        if s is None:
            raise SessionError(f"Unknown session: {session_id}")
        if s.child is not None and s.child.poll() is None:
            return s.record
        self._launch(s, seed_message=None, resume=True)
        return s.record

    def archive(self, session_id: str) -> None:
        # Cross-process hydration before lookup. A fresh SessionManager
        # spawned via the website's HTTP bridge has an empty _sessions
        # dict; without this hydrate call, archive() silently returns
        # and the session file stays in sessions/. Surfaced 2026-05-26
        # Phase 1b functional verification (SPEC-148 undo path).
        self._hydrate()
        with self._lock:
            s = self._sessions.get(session_id)
        if s is None:
            return
        if s.child is not None and s.child.poll() is None:
            # Tree-kill on Windows (cmd.exe wrapper + claude grandchild);
            # plain terminate on POSIX. See _kill_child_tree docstring +
            # deferred-concerns entry #21.
            _kill_child_tree(s.child)
        s.record.status = "archived"
        self._persist(s.record)
        # Move the session JSON into archive/.
        src = self.sessions_dir / f"{s.record.id}.json"
        dst = self.archive_dir / f"session_{s.record.id}.json"
        try:
            if src.exists():
                src.replace(dst)
        except Exception:
            pass
        # SPEC-079: drop the entry from the cross-process registry so
        # other sessions see the session is gone. Soft-fail.
        try:
            from tools.active_sessions import unregister_session
            unregister_session(s.record.id, state_dir=self.state_dir)
        except Exception:
            pass
        self._emit(SessionEvent(kind="archived", session_id=s.record.id,
                                session_display_name=s.record.display_name))

    def shutdown(self) -> None:
        """Terminate every running subprocess and stop the watchdog."""
        self._watchdog_stop.set()
        with self._lock:
            ids = list(self._sessions.keys())
        for sid in ids:
            with self._lock:
                s = self._sessions.get(sid)
            if s is None:
                continue
            if s.child is not None and s.child.poll() is None:
                # Tree-kill on Windows; terminate+wait+kill-fallback on
                # POSIX. The previous inline pattern only killed the
                # cmd.exe wrapper on Windows, orphaning claude — see
                # _kill_child_tree + deferred-concerns entry #21.
                _kill_child_tree(s.child)
            if s.raw_log is not None:
                try:
                    s.raw_log.close()
                except Exception:
                    pass

    # ----- queue draining -----

    def drain_events(self) -> List[SessionEvent]:
        """Pull every event currently queued (non-blocking)."""
        out: List[SessionEvent] = []
        while True:
            try:
                out.append(self.event_queue.get_nowait())
            except queue.Empty:
                break
        return out

    # ----- internals -----

    def _launch(self, s: _Internal, seed_message: Optional[str], resume: bool) -> None:
        if self.claude_bin is None:
            s.record.status = "error"
            raise SessionError(
                "claude binary not found. Set CLAUDE_BIN env var or put `claude` on PATH."
            )

        log_path = self.raw_logs_dir / f"{s.record.id}.jsonl"
        s.raw_log = open(log_path, "a", encoding="utf-8")
        s.partials.clear()

        args = [self.claude_bin]
        if resume:
            args += ["--resume", s.record.id]
        args += [
            "--print",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--permission-mode", DEFAULT_PERMISSION_MODE,
            "--allow-dangerously-skip-permissions",
        ]
        if not resume:
            args += ["--session-id", s.record.id]

        # Windows: claude.cmd needs shell=False via shutil.which resolution.
        # Use text mode so stream-json reads as str rather than bytes.
        #
        # Critical: strip billing-mode env vars from the inherited
        # environment so the spawned ``claude`` subprocess uses the
        # maintainer's logged-in plan (OAuth) instead of per-call API
        # billing. If the maintainer has ``ANTHROPIC_API_KEY`` set in
        # their user environment for other tools, that key would be
        # inherited here and force the spawned session into API mode,
        # which charges separately from their Claude Code plan. The
        # default is "use the plan"; opting back into API billing
        # would require a dedicated flag (not yet implemented — file an
        # SPEC entry if a maintainer ever needs the carve-out).
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
        ):
            env.pop(key, None)
        # Supervisor primitive: on Linux we install PR_SET_PDEATHSIG via
        # preexec_fn so the kernel kills the child on uncatchable parent
        # death. On Windows the equivalent (Job Object assignment) happens
        # AFTER Popen returns. On macOS / other POSIX, neither path applies
        # (logged once inside _install_supervisor below).
        popen_kwargs: Dict[str, Any] = dict(
            cwd=s.record.cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,  # line-buffered
            encoding="utf-8",
            env=env,
        )
        if _is_linux():
            popen_kwargs["preexec_fn"] = _set_pdeathsig
        try:
            child = subprocess.Popen(args, **popen_kwargs)
        except FileNotFoundError as exc:
            s.record.status = "error"
            self._persist(s.record)
            raise SessionError(f"failed to spawn claude: {exc}") from exc

        # Windows: assign to the process-wide Job Object so the OS kills the
        # child on uncatchable parent death. Linux: no-op (PDEATHSIG already
        # installed via preexec_fn above). macOS: logged-once skip.
        # See _install_supervisor for the per-platform contract.
        _install_supervisor(child)

        s.child = child
        s.record.pid = child.pid
        s.record.status = "active"
        s.record.last_active_at = _iso_now()
        s.last_text_at = time.time()
        self._persist(s.record)

        # Reader threads.
        s.reader_thread = threading.Thread(
            target=self._read_stdout, args=(s,), daemon=True
        )
        s.reader_thread.start()
        s.stderr_thread = threading.Thread(
            target=self._read_stderr, args=(s,), daemon=True
        )
        s.stderr_thread.start()
        # Exit watcher.
        threading.Thread(target=self._watch_exit, args=(s,), daemon=True).start()

        self._emit(SessionEvent(
            kind="spawned",
            session_id=s.record.id,
            session_display_name=s.record.display_name,
            payload={"resumed": resume},
        ))

        if seed_message:
            try:
                self.send(s.record.id, seed_message)
            except SessionError:
                pass  # already reported via _emit

    def _read_stdout(self, s: _Internal) -> None:
        assert s.child is not None and s.child.stdout is not None
        for line in s.child.stdout:
            if not line.strip():
                continue
            try:
                if s.raw_log is not None:
                    s.raw_log.write(line if line.endswith("\n") else line + "\n")
                    s.raw_log.flush()
            except Exception:
                pass
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            self._dispatch(s, ev)

    def _read_stderr(self, s: _Internal) -> None:
        assert s.child is not None and s.child.stderr is not None
        for line in s.child.stderr:
            try:
                if s.raw_log is not None:
                    s.raw_log.write(f"STDERR {line}")
                    s.raw_log.flush()
            except Exception:
                pass
            self._emit(SessionEvent(
                kind="activity",
                session_id=s.record.id,
                session_display_name=s.record.display_name,
                payload={"stderr": line.rstrip()},
            ))

    def _watch_exit(self, s: _Internal) -> None:
        assert s.child is not None
        code = s.child.wait()
        s.record.pid = None
        # If archive() already set status to "archived" before terminate
        # caused the subprocess to exit, preserve that status — the
        # session is gone for good, not idle. (Bug surfaced by the
        # default-session respawn test: status flipped from archived
        # back to idle when the subprocess exited cleanly during archive.)
        if s.record.status != "archived":
            s.record.status = "idle" if code == 0 else "error"
        try:
            self._persist(s.record)
        except Exception:
            pass
        kind = "session_idle" if code == 0 else "session_error"
        self._emit(SessionEvent(
            kind=kind,
            session_id=s.record.id,
            session_display_name=s.record.display_name,
            payload={"exit_code": code},
        ))

    def _dispatch(self, s: _Internal, ev: Dict[str, Any]) -> None:
        s.record.last_active_at = _iso_now()
        kind = ev.get("type")
        if kind == "system":
            return
        if kind == "assistant":
            content = (ev.get("message") or {}).get("content")
            if not isinstance(content, list):
                return
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get("type") == "text" and c.get("text"):
                    s.last_text_at = time.time()
                    self._emit(SessionEvent(
                        kind="communication",
                        session_id=s.record.id,
                        session_display_name=s.record.display_name,
                        payload={
                            "text": c["text"],
                            "full_message_id": (ev.get("message") or {}).get("id"),
                        },
                    ))
                elif c.get("type") == "tool_use":
                    self._emit(SessionEvent(
                        kind="tool_use",
                        session_id=s.record.id,
                        session_display_name=s.record.display_name,
                        payload={"name": c.get("name"), "id": c.get("id")},
                    ))
            return
        if kind == "user":
            content = (ev.get("message") or {}).get("content")
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        self._emit(SessionEvent(
                            kind="tool_result",
                            session_id=s.record.id,
                            session_display_name=s.record.display_name,
                            payload={"tool_use_id": c.get("tool_use_id")},
                        ))
            return
        if kind == "result":
            self._emit(SessionEvent(
                kind="turn_complete",
                session_id=s.record.id,
                session_display_name=s.record.display_name,
                payload={
                    "duration_ms": ev.get("duration_ms"),
                    "total_cost_usd": ev.get("total_cost_usd"),
                    "usage": ev.get("usage"),
                    "is_error": ev.get("is_error"),
                },
            ))
            return
        # Unknown event type — surface as activity.
        self._emit(SessionEvent(
            kind="activity",
            session_id=s.record.id,
            session_display_name=s.record.display_name,
            payload={"unknown_event_type": kind},
        ))

    def _emit(self, event: SessionEvent) -> None:
        try:
            self.event_queue.put_nowait(event)
        except queue.Full:
            pass
        if self.on_event is not None:
            try:
                self.on_event(event)
            except Exception:
                pass

    def _watchdog_loop(self) -> None:
        while not self._watchdog_stop.wait(30.0):
            now = time.time()
            with self._lock:
                items = list(self._sessions.items())
            for sid, s in items:
                if s.child is None or s.child.poll() is not None:
                    continue
                silent_for = now - s.last_text_at
                if silent_for > SILENT_THRESHOLD_S:
                    self._emit(SessionEvent(
                        kind="silent_too_long",
                        session_id=sid,
                        session_display_name=s.record.display_name,
                        payload={"silent_for_s": silent_for},
                    ))
                    s.last_text_at = now  # only fire once per threshold


# ----- helpers -----


def _iso_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _project_slug_for_cwd(cwd: str) -> str:
    """Compute a short project slug from a cwd path.

    Used by the SPEC-079 active-sessions registry so spawn entries
    carry a human-readable project field. Strategy: take the last
    path component, lowercase, replace path-unfriendly chars. Falls
    back to the full cwd if anything goes wrong.
    """
    try:
        name = Path(cwd).name or cwd
        return name.lower().replace(" ", "-")
    except Exception:
        return str(cwd)


def _detect_claude() -> Optional[str]:
    """Locate the claude CLI. Honors CLAUDE_BIN; falls back to PATH."""
    explicit = os.environ.get(CLAUDE_BIN_ENV)
    if explicit:
        if Path(explicit).exists():
            return explicit
        # Maybe it's a name (e.g. "claude") not an absolute path.
        resolved = shutil.which(explicit)
        if resolved:
            return resolved
    # Try common names; on Windows the binary is claude.cmd.
    for name in ("claude.cmd", "claude.exe", "claude"):
        resolved = shutil.which(name)
        if resolved:
            return resolved
    return None


# ----- supervisor primitive: kill children when the parent dies uncatchably -----
#
# Why this exists: ``_kill_child_tree`` above handles *cooperative* shutdown
# (the explicit ``archive`` / ``shutdown`` paths). If the parent process dies
# *uncatchably* — SIGKILL on POSIX, ``taskkill /F`` on Windows, OOM killer,
# kernel panic, segfault — those code paths never run and the spawned
# children orphan. Wave 1c's supervisor-marked test
# ``tests/test_streamjson_orphan_cleanup.py`` characterised the bug; this
# block ships the OS-level supervisor primitives that close the gap.
#
# Strategy per platform:
# - Windows: assign each spawned subprocess to a process-wide Job Object
#   that has ``JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE``. The job handle is owned
#   by the parent process; when the parent dies (cleanly or uncatchably),
#   the OS closes every handle the process owned, which triggers
#   KILL_ON_JOB_CLOSE and unconditionally terminates every assigned child.
# - POSIX Linux: pass ``preexec_fn`` to ``subprocess.Popen`` that calls
#   ``prctl(PR_SET_PDEATHSIG, SIGKILL)`` in the child *after fork, before
#   exec*. The kernel then automatically delivers SIGKILL to the child the
#   instant the parent dies.
# - POSIX non-Linux (macOS, BSDs): no PR_SET_PDEATHSIG equivalent exists.
#   The fallback would be a parent-side SIGCHLD watcher + setpgrp tree-kill
#   on shutdown — significantly more complex and out of scope for this arc.
#   We log once and skip cleanly; on those platforms the cooperative
#   ``_kill_child_tree`` path remains the only line of defence.
#
# Composes with the existing ``_kill_child_tree`` (Wave 1a, deferred-concerns
# #21): that handles the explicit shutdown path; this handles uncatchable
# parent death. Neither obsoletes the other.
#
# Implemented via ctypes (not pywin32) to keep the dependency surface clean.
# pyproject.toml has no Windows-specific dependency today and we want to
# keep it that way.


# Windows Job Object constants — values from windows.h (winnt.h, jobapi2.h).
_JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000
_JobObjectExtendedLimitInformation = 9
_PROCESS_ALL_ACCESS = 0x1F0FFF
_PROCESS_TERMINATE = 0x0001
_PROCESS_SET_QUOTA = 0x0100

# Linux prctl constant. PR_SET_PDEATHSIG = 1. See <sys/prctl.h>.
_PR_SET_PDEATHSIG = 1


def _is_windows() -> bool:
    return sys.platform == "win32"


def _is_linux() -> bool:
    return sys.platform.startswith("linux")


# Module-level cache: one Job Object per Python process. Lazily created on
# first ``_install_supervisor`` call. Held as a ctypes HANDLE so the OS keeps
# the job alive for the process lifetime; releasing the handle (whether by
# clean GC or by parent-process death) closes the job, which terminates every
# assigned child via KILL_ON_JOB_CLOSE.
_win_job_handle: Optional[Any] = None
_win_job_lock = threading.Lock()
_macos_skip_logged = False


class _JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("PerProcessUserTimeLimit", ctypes.c_int64),
        ("PerJobUserTimeLimit", ctypes.c_int64),
        ("LimitFlags", ctypes.c_uint32),
        ("MinimumWorkingSetSize", ctypes.c_size_t),
        ("MaximumWorkingSetSize", ctypes.c_size_t),
        ("ActiveProcessLimit", ctypes.c_uint32),
        ("Affinity", ctypes.c_size_t),
        ("PriorityClass", ctypes.c_uint32),
        ("SchedulingClass", ctypes.c_uint32),
    ]


class _IO_COUNTERS(ctypes.Structure):
    _fields_ = [
        ("ReadOperationCount", ctypes.c_uint64),
        ("WriteOperationCount", ctypes.c_uint64),
        ("OtherOperationCount", ctypes.c_uint64),
        ("ReadTransferCount", ctypes.c_uint64),
        ("WriteTransferCount", ctypes.c_uint64),
        ("OtherTransferCount", ctypes.c_uint64),
    ]


class _JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("BasicLimitInformation", _JOBOBJECT_BASIC_LIMIT_INFORMATION),
        ("IoInfo", _IO_COUNTERS),
        ("ProcessMemoryLimit", ctypes.c_size_t),
        ("JobMemoryLimit", ctypes.c_size_t),
        ("PeakProcessMemoryUsed", ctypes.c_size_t),
        ("PeakJobMemoryUsed", ctypes.c_size_t),
    ]


def _get_or_create_win_job() -> Optional[Any]:
    """Return the process-wide Job Object handle, creating it on first call.

    Returns None if the Job Object could not be created or configured (e.g.
    the running platform isn't Windows, or the Win32 APIs returned NULL).
    Callers must treat None as "supervisor unavailable; orphans possible if
    parent dies uncatchably" and degrade gracefully.

    The handle is intentionally NOT closed — it lives for the process
    lifetime. When the process dies (cleanly or via SIGKILL / taskkill /F /
    OOM / kernel panic), the OS releases every handle the process owned,
    which closes the job, which triggers JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    and terminates every assigned child unconditionally.
    """
    global _win_job_handle
    if not _is_windows():
        return None
    with _win_job_lock:
        if _win_job_handle is not None:
            return _win_job_handle
        try:
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        except OSError:
            return None

        # HANDLE CreateJobObjectW(LPSECURITY_ATTRIBUTES, LPCWSTR);
        kernel32.CreateJobObjectW.restype = ctypes.c_void_p
        kernel32.CreateJobObjectW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p]

        # BOOL SetInformationJobObject(HANDLE, JOBOBJECTINFOCLASS, LPVOID, DWORD);
        kernel32.SetInformationJobObject.restype = ctypes.c_int
        kernel32.SetInformationJobObject.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
        ]

        job = kernel32.CreateJobObjectW(None, None)
        if not job:
            err = ctypes.get_last_error()
            _log.warning(
                "SessionManager: CreateJobObjectW failed (err=%s); "
                "spawned children will orphan if parent dies uncatchably.",
                err,
            )
            return None

        info = _JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
        info.BasicLimitInformation.LimitFlags = _JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        ok = kernel32.SetInformationJobObject(
            job,
            _JobObjectExtendedLimitInformation,
            ctypes.byref(info),
            ctypes.sizeof(info),
        )
        if not ok:
            err = ctypes.get_last_error()
            _log.warning(
                "SessionManager: SetInformationJobObject(KILL_ON_JOB_CLOSE) "
                "failed (err=%s); spawned children will orphan if parent dies "
                "uncatchably.",
                err,
            )
            # Best effort: still cache the handle. It won't kill on close,
            # but it doesn't hurt anything either.
        _win_job_handle = job
        return job


def _set_pdeathsig() -> None:
    """preexec_fn for subprocess.Popen on Linux: ask the kernel to SIGKILL
    this child the moment its parent dies, regardless of cause.

    Runs in the child between fork() and exec(). Failure here must not raise
    — we don't want preexec_fn errors to take down the spawn — so we
    swallow exceptions. The worst case is the same as the pre-fix behaviour:
    the child orphans on uncatchable parent death.
    """
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        # int prctl(int option, unsigned long arg2, ...);
        libc.prctl(_PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0)
    except Exception:
        pass


def _install_supervisor(child: subprocess.Popen) -> None:
    """Register ``child`` with the OS-level supervisor so it dies when the
    parent dies, even on uncatchable parent death.

    Windows: assign to the process-wide Job Object created by
    ``_get_or_create_win_job``. Linux: no-op (PR_SET_PDEATHSIG was already
    installed via preexec_fn during spawn). macOS / other POSIX: log once
    and skip cleanly — no equivalent primitive ships in those kernels.

    Safe to call on already-dead children (the AssignProcessToJobObject call
    will fail; we log and move on).
    """
    if child.pid is None:
        return
    if _is_windows():
        job = _get_or_create_win_job()
        if job is None:
            return  # already logged inside _get_or_create_win_job
        try:
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        except OSError:
            return

        # HANDLE OpenProcess(DWORD, BOOL, DWORD);
        kernel32.OpenProcess.restype = ctypes.c_void_p
        kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        # BOOL AssignProcessToJobObject(HANDLE, HANDLE);
        kernel32.AssignProcessToJobObject.restype = ctypes.c_int
        kernel32.AssignProcessToJobObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        # BOOL CloseHandle(HANDLE);
        kernel32.CloseHandle.restype = ctypes.c_int
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]

        # PROCESS_TERMINATE + PROCESS_SET_QUOTA are the access rights
        # AssignProcessToJobObject requires; PROCESS_ALL_ACCESS is a superset
        # that also works and matches the standard pattern.
        proc_handle = kernel32.OpenProcess(_PROCESS_ALL_ACCESS, 0, ctypes.c_uint32(child.pid))
        if not proc_handle:
            err = ctypes.get_last_error()
            _log.warning(
                "SessionManager: OpenProcess(pid=%s) failed (err=%s); "
                "child not assigned to Job Object — will orphan on uncatchable "
                "parent death.",
                child.pid, err,
            )
            return
        try:
            ok = kernel32.AssignProcessToJobObject(job, proc_handle)
            if not ok:
                err = ctypes.get_last_error()
                # ERROR_ACCESS_DENIED (5) can occur if the child is already
                # in another job that doesn't allow breakaway. Rare but not
                # fatal; log and move on.
                _log.warning(
                    "SessionManager: AssignProcessToJobObject(pid=%s) failed "
                    "(err=%s); child will orphan on uncatchable parent death.",
                    child.pid, err,
                )
        finally:
            kernel32.CloseHandle(proc_handle)
        return

    if _is_linux():
        # Already installed via preexec_fn at spawn time; nothing to do here.
        return

    # POSIX non-Linux (macOS, BSDs). No PR_SET_PDEATHSIG equivalent.
    global _macos_skip_logged
    if not _macos_skip_logged:
        _macos_skip_logged = True
        _log.info(
            "SessionManager: no uncatchable-parent-death supervisor available "
            "on platform=%s; spawned children may orphan on parent SIGKILL. "
            "Cooperative shutdown (archive/shutdown) still works via "
            "_kill_child_tree.",
            sys.platform,
        )


def _kill_child_tree(child: subprocess.Popen, wait_timeout_s: float = 2.0) -> None:
    """Terminate ``child`` AND every descendant it spawned.

    Why this exists: on Windows, ``SessionManager`` invokes
    ``claude.cmd``, which is a batch shim that ``cmd.exe`` interprets.
    The ``subprocess.Popen`` object is the ``cmd.exe`` wrapper, not the
    spawned ``claude`` (and its grandchildren). Calling ``child.terminate()``
    only signals the wrapper; the real ``claude`` process is orphaned,
    keeps holding file handles, and keeps writing to log files that the
    archive flow expected to be quiescent. This is deferred-concerns
    entry #21 (HIGH severity).

    Strategy:
    - Windows: ``taskkill /PID <pid> /T /F``. ``/T`` walks the process
      tree, ``/F`` forces unconditional termination. Non-zero exit from
      taskkill (e.g. PID already gone) is treated as success — the goal
      is "child + descendants are dead at end of call", not "taskkill
      succeeded".
    - POSIX: existing ``terminate()`` + ``wait()`` is sufficient because
      ``claude`` is the direct child (no shim layer), and SIGTERM
      propagation is the OS's job.

    Pattern lifted from ``Resonance-Website/tools/launch_mvp_helper._kill_pid_tree``;
    duplicated rather than cross-repo imported because the two projects
    don't depend on each other.

    Safe to call when the child has already exited (no-op on POSIX
    because ``terminate()`` after exit is harmless; no-op on Windows
    because taskkill returns non-zero which we treat as success).
    """
    if child.poll() is not None:
        return  # already dead
    if sys.platform == "win32":
        try:
            subprocess.run(
                ["taskkill", "/PID", str(child.pid), "/T", "/F"],
                capture_output=True,
                timeout=10.0,
            )
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            # taskkill missing or hung — fall back to terminate() so the
            # cmd.exe wrapper at least dies. The grandchild may orphan
            # in that degraded path; surface no exception either way.
            try:
                child.terminate()
            except Exception:
                pass
        # Best-effort reap so the Popen object's poll() reflects death.
        try:
            child.wait(timeout=wait_timeout_s)
        except subprocess.TimeoutExpired:
            pass
        except Exception:
            pass
        return
    # POSIX: terminate the child; the OS handles signal propagation.
    try:
        child.terminate()
        try:
            child.wait(timeout=wait_timeout_s)
        except subprocess.TimeoutExpired:
            # Escalate to SIGKILL if the child ignored SIGTERM.
            try:
                child.kill()
                child.wait(timeout=wait_timeout_s)
            except Exception:
                pass
    except Exception:
        pass
