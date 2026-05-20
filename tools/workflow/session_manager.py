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

import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


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
DEFAULT_PERMISSION_MODE = "auto"


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
        with self._lock:
            s = self._sessions.get(session_id)
        if s is None:
            raise SessionError(f"Unknown session: {session_id}")
        if s.child is not None and s.child.poll() is None:
            return s.record
        self._launch(s, seed_message=None, resume=True)
        return s.record

    def archive(self, session_id: str) -> None:
        with self._lock:
            s = self._sessions.get(session_id)
        if s is None:
            return
        if s.child is not None and s.child.poll() is None:
            try:
                s.child.terminate()
            except Exception:
                pass
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
                try:
                    s.child.terminate()
                    s.child.wait(timeout=2)
                except Exception:
                    try:
                        s.child.kill()
                    except Exception:
                        pass
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
        try:
            child = subprocess.Popen(
                args,
                cwd=s.record.cwd,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,  # line-buffered
                encoding="utf-8",
                env=env,
            )
        except FileNotFoundError as exc:
            s.record.status = "error"
            self._persist(s.record)
            raise SessionError(f"failed to spawn claude: {exc}") from exc

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
