"""
Active-session discovery — SPEC-079.

A session that needs to coordinate with another session must first
know that the other session exists. This module provides the
discovery primitive: a shared registry file at
``state/active_sessions.json`` listing every session running on the
maintainer's machine + accessible network with at least
``(id, project, type, focus, last_seen)`` fields.

Maintainer directive (session da9df8be, 2026-05-19) verbatim:

    "a system where the sessions can talk to each other... start a
    session, tell it that other sessions are also running... it can
    automatically check what other sessions are running and what they
    are doing, and communicate with them if it needs."

SPEC-017 (file-based inbox) is the message-passing layer; this
module is the discovery layer on top.

How it works
------------

Sessions write entries to ``state/active_sessions.json`` on:

- **startup** — call ``register_session(id, project, session_type, ...)``.
- **periodic heartbeat** — call ``heartbeat(id, focus=...)`` every few
  minutes (or on each turn) to refresh ``last_seen``.
- **shutdown** — call ``unregister_session(id)``.

Discovery is via ``list_active_sessions()`` which reads the file,
filters entries older than ``stale_after_min`` minutes, and returns
``List[ActiveSession]``. Stale entries are dropped on the next write
so the file size stays bounded.

The registry composes with:

- **SessionManager** (SPEC-022) — spawned subprocesses register on
  ``spawn`` and unregister on shutdown / archive.
- **Inbox** (SPEC-017) — once a session is discovered, callers route
  inbox messages to its ``id``.
- **Silence watchdog** (SPEC-023) — ``last_seen`` feeds the watchdog;
  entries older than the silent threshold trigger watchdog events.

Concurrent writes
-----------------

Writes use a temp-file + atomic ``os.replace`` pattern so an
interrupted write never leaves the registry corrupted. On Windows
``os.replace`` is atomic across same-volume renames, so two
simultaneous writers see one of their states preserved (not a
merged-corrupted blob). The cost is that an interleaved
register + unregister can race; for v1 this is acceptable since the
worst case is a stale entry that gets cleaned on the next write.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Public dataclass.
# ---------------------------------------------------------------------------


@dataclass
class ActiveSession:
    """One entry in the active-sessions registry.

    All fields are simple JSON-serializable types so the registry file
    round-trips cleanly through any JSON tool. ``focus`` is a one-line
    description of what the session is currently working on; sessions
    update it via ``heartbeat`` to reflect their current state.
    """

    id: str
    project: str
    session_type: str
    focus: str = ""
    last_seen: str = ""       # ISO 8601 with timezone (UTC)
    started_at: str = ""      # ISO 8601 with timezone (UTC)
    pid: Optional[int] = None
    cwd: str = ""
    metadata: Dict[str, Any] = field(default_factory=dict)

    @property
    def is_stale(self) -> bool:
        """True if last_seen is too old to consider the session live.

        Uses the default 10-minute threshold. Callers wanting a
        different threshold should use ``last_seen_age_seconds`` and
        decide themselves.
        """
        return self.last_seen_age_seconds() > 10 * 60

    def last_seen_age_seconds(self) -> float:
        """Seconds since ``last_seen``. Returns ``inf`` if the field
        is missing or unparseable (so callers treat the entry as
        infinitely stale rather than crash)."""
        if not self.last_seen:
            return float("inf")
        try:
            ts = _iso_to_epoch(self.last_seen)
            return max(0.0, time.time() - ts)
        except Exception:
            return float("inf")


# ---------------------------------------------------------------------------
# Registry file location + helpers.
# ---------------------------------------------------------------------------


DEFAULT_REGISTRY_NAME = "active_sessions.json"


def registry_path(state_dir: Optional[Path] = None) -> Path:
    """Return the on-disk path to the active-sessions registry.

    When ``state_dir`` is None, falls back to ``./state/`` relative
    to the current working directory. Callers should always pass the
    actual state dir from their config; the fallback exists for tests.
    """
    base = Path(state_dir) if state_dir is not None else Path("state")
    return base / DEFAULT_REGISTRY_NAME


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _iso_to_epoch(iso: str) -> float:
    """Parse an ISO 8601 datetime to epoch seconds. Accepts strings
    with or without trailing ``Z`` (datetime.fromisoformat doesn't
    accept ``Z`` on Python <3.11)."""
    if iso.endswith("Z"):
        iso = iso[:-1] + "+00:00"
    return datetime.fromisoformat(iso).timestamp()


def _atomic_write(path: Path, payload: List[Dict[str, Any]]) -> None:
    """Write ``payload`` to ``path`` atomically.

    Uses a same-directory temp file + ``os.replace`` so a crash
    mid-write never leaves the registry partially populated. The
    parent directory is created if missing.

    On TypeError (non-JSON-serializable payload) the temp file is
    cleaned up rather than leaving an orphan ``.tmp.<pid>.<ns>``
    behind. Bug-fix 2026-05-20 (stress-test).
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}.{time.time_ns()}")
    try:
        tmp.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    except TypeError:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass
        raise
    # Bug-fix 2026-05-20 (stress-test): on Windows ``os.replace`` can
    # raise PermissionError when the target is briefly held by AV /
    # a sibling process, even under the cross-process lock. Retry
    # with small backoff before propagating.
    last_exc: Optional[PermissionError] = None
    for _ in range(20):
        try:
            os.replace(tmp, path)
            return
        except PermissionError as exc:
            last_exc = exc
            time.sleep(0.01)
    # Cleanup the orphan tmp on final failure.
    try:
        tmp.unlink(missing_ok=True)
    except Exception:
        pass
    if last_exc is not None:
        raise last_exc


# ---------------------------------------------------------------------------
# Cross-process lock for concurrent writes.
# ---------------------------------------------------------------------------


_LOCK_TIMEOUT_S = 5.0
_LOCK_RETRY_S = 0.01


def _acquire_lock(path: Path) -> Optional[int]:
    """Acquire an exclusive cross-process lock on ``path.lock`` via
    ``O_CREAT|O_EXCL``. Returns the file descriptor to release later,
    or None if the lock could not be acquired within the timeout
    (caller should retry the surrounding read-modify-write).

    Bug-fix 2026-05-20 (stress-test): without locking, concurrent
    register_session calls produced lost updates (50 threads → 2
    surviving entries). The lock serializes the read-modify-write
    cycle so each writer sees a consistent base before replacing.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(path.suffix + ".lock")
    deadline = time.time() + _LOCK_TIMEOUT_S
    while time.time() < deadline:
        try:
            fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_RDWR)
            return fd
        except (FileExistsError, PermissionError):
            # FileExistsError is the POSIX shape; Windows can raise
            # PermissionError on the same condition (especially when
            # the lock file was just unlinked by another thread and
            # is in the process of being released by the OS). Both
            # mean "lock is held; retry."
            #
            # Check for stale lock (older than the timeout — the
            # process that held it crashed).
            try:
                age = time.time() - lock_path.stat().st_mtime
                if age > _LOCK_TIMEOUT_S * 2:
                    lock_path.unlink(missing_ok=True)
                    continue
            except FileNotFoundError:
                continue
            except Exception:
                pass
            time.sleep(_LOCK_RETRY_S)
    return None


def _release_lock(path: Path, fd: Optional[int]) -> None:
    """Release a lock acquired via ``_acquire_lock``. Idempotent +
    soft-fails so a missing lock file doesn't crash the caller."""
    if fd is None:
        return
    try:
        os.close(fd)
    except Exception:
        pass
    try:
        lock_path = path.with_suffix(path.suffix + ".lock")
        lock_path.unlink(missing_ok=True)
    except Exception:
        pass


def _load(path: Path) -> List[Dict[str, Any]]:
    """Load + parse the registry file. Returns an empty list if the
    file is missing or malformed (defensive: a corrupted registry
    must never block discovery for healthy sessions)."""
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, list):
            return data
        return []
    except Exception:
        return []


def _prune_stale(
    entries: List[Dict[str, Any]],
    stale_after_min: float,
) -> List[Dict[str, Any]]:
    """Drop entries older than ``stale_after_min`` minutes.

    Entries with no ``last_seen`` or unparseable timestamps are also
    dropped (treated as infinitely stale). This is the GC path:
    every write prunes, keeping the file size bounded as sessions
    come and go.
    """
    cutoff = time.time() - stale_after_min * 60
    out: List[Dict[str, Any]] = []
    for entry in entries:
        ts_str = entry.get("last_seen", "")
        if not ts_str:
            continue
        try:
            ts = _iso_to_epoch(ts_str)
        except Exception:
            continue
        if ts >= cutoff:
            out.append(entry)
    return out


# ---------------------------------------------------------------------------
# Public API: register / heartbeat / unregister / list.
# ---------------------------------------------------------------------------


def register_session(
    session_id: str,
    project: str,
    session_type: str,
    *,
    focus: str = "",
    pid: Optional[int] = None,
    cwd: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None,
    state_dir: Optional[Path] = None,
) -> ActiveSession:
    """Add or refresh a session entry in the registry.

    Idempotent: calling ``register_session`` twice with the same id
    updates the existing entry (focus, pid, cwd, metadata, last_seen)
    rather than producing duplicates. Returns the persisted
    ``ActiveSession``.

    Bug-fix 2026-05-20 (stress-test): validates ``session_id`` is a
    non-empty string; previously empty/None ids were silently stored
    as orphan entries. Wraps the read-modify-write cycle in a
    cross-process lock so concurrent writers don't lose-update each
    other.
    """
    if not isinstance(session_id, str) or not session_id:
        raise ValueError(
            f"register_session: session_id must be a non-empty str; "
            f"got {session_id!r}"
        )
    path = registry_path(state_dir)
    lock_fd = _acquire_lock(path)
    try:
        entries = _load(path)

        now = _now_iso()
        existing_idx: Optional[int] = None
        for idx, e in enumerate(entries):
            if e.get("id") == session_id:
                existing_idx = idx
                break

        entry = ActiveSession(
            id=session_id,
            project=project,
            session_type=session_type,
            focus=focus,
            last_seen=now,
            started_at=(
                entries[existing_idx].get("started_at", now)
                if existing_idx is not None
                else now
            ),
            pid=pid if pid is not None else (
                entries[existing_idx].get("pid") if existing_idx is not None else None
            ),
            cwd=cwd or (
                entries[existing_idx].get("cwd", "") if existing_idx is not None else ""
            ),
            metadata=dict(metadata or (
                entries[existing_idx].get("metadata", {}) if existing_idx is not None else {}
            )),
        )

        if existing_idx is not None:
            entries[existing_idx] = asdict(entry)
        else:
            entries.append(asdict(entry))

        # Prune stale entries on every write so the file stays bounded.
        entries = _prune_stale(entries, stale_after_min=60)  # generous on write
        # And make sure our just-added entry is preserved even if the
        # prune dropped it for any clock weirdness.
        if all(e.get("id") != session_id for e in entries):
            entries.append(asdict(entry))

        _atomic_write(path, entries)
        return entry
    finally:
        _release_lock(path, lock_fd)


def heartbeat(
    session_id: str,
    *,
    focus: Optional[str] = None,
    state_dir: Optional[Path] = None,
) -> bool:
    """Refresh the session's ``last_seen`` (and optionally ``focus``).

    Returns True if the entry was found + updated; False if the id
    is not in the registry (caller may want to register_session first).

    Bug-fix 2026-05-20: locks the read-modify-write cycle.
    """
    if not isinstance(session_id, str) or not session_id:
        return False
    path = registry_path(state_dir)
    lock_fd = _acquire_lock(path)
    try:
        entries = _load(path)
        found = False
        for entry in entries:
            if entry.get("id") == session_id:
                entry["last_seen"] = _now_iso()
                if focus is not None:
                    entry["focus"] = focus
                found = True
                break
        if not found:
            return False
        entries = _prune_stale(entries, stale_after_min=60)
        _atomic_write(path, entries)
        return True
    finally:
        _release_lock(path, lock_fd)


def unregister_session(
    session_id: str,
    *,
    state_dir: Optional[Path] = None,
) -> bool:
    """Remove a session entry from the registry.

    Returns True if the entry was found + removed; False if the id
    was not registered. No-op + return False on missing files.

    Bug-fix 2026-05-20: locks the read-modify-write cycle.
    """
    if not isinstance(session_id, str) or not session_id:
        return False
    path = registry_path(state_dir)
    if not path.exists():
        return False
    lock_fd = _acquire_lock(path)
    try:
        entries = _load(path)
        before = len(entries)
        entries = [e for e in entries if e.get("id") != session_id]
        if len(entries) == before:
            return False
        _atomic_write(path, entries)
        return True
    finally:
        _release_lock(path, lock_fd)


def list_active_sessions(
    *,
    state_dir: Optional[Path] = None,
    stale_after_min: float = 10.0,
    include_stale: bool = False,
) -> List[ActiveSession]:
    """Return live sessions from the registry.

    By default filters entries whose ``last_seen`` is more than
    ``stale_after_min`` minutes old. Pass ``include_stale=True`` to
    surface every entry regardless of age (useful for diagnostics).
    """
    path = registry_path(state_dir)
    raw = _load(path)
    if not include_stale:
        raw = _prune_stale(raw, stale_after_min)
    out: List[ActiveSession] = []
    for entry in raw:
        try:
            # Only the documented fields go into the dataclass; ignore
            # extras so an old client with extra fields can talk to a
            # new schema (and vice versa).
            valid_keys = {
                "id", "project", "session_type", "focus", "last_seen",
                "started_at", "pid", "cwd", "metadata",
            }
            kwargs = {k: v for k, v in entry.items() if k in valid_keys}
            out.append(ActiveSession(**kwargs))
        except Exception:
            continue
    # Sort by last_seen descending so the freshest session is first.
    out.sort(key=lambda s: s.last_seen, reverse=True)
    return out


def get_active_session(
    session_id: str,
    *,
    state_dir: Optional[Path] = None,
) -> Optional[ActiveSession]:
    """Lookup a single session by id. Returns None if absent or stale
    by the default threshold."""
    for entry in list_active_sessions(state_dir=state_dir):
        if entry.id == session_id:
            return entry
    return None


# ---------------------------------------------------------------------------
# CLI.
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    import argparse
    import sys

    parser = argparse.ArgumentParser(
        prog="tools.active_sessions",
        description="Active-session discovery primitive (SPEC-079).",
    )
    parser.add_argument(
        "--state-dir",
        default=None,
        help="Override the state dir holding active_sessions.json.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="List active sessions")
    p_list.add_argument("--include-stale", action="store_true")
    p_list.add_argument(
        "--stale-after-min", type=float, default=10.0,
        help="Filter entries older than this many minutes (default 10).",
    )

    p_reg = sub.add_parser("register", help="Register or refresh a session")
    p_reg.add_argument("id")
    p_reg.add_argument("project")
    p_reg.add_argument("session_type")
    p_reg.add_argument("--focus", default="")

    p_hb = sub.add_parser("heartbeat", help="Heartbeat a session")
    p_hb.add_argument("id")
    p_hb.add_argument("--focus", default=None)

    p_un = sub.add_parser("unregister", help="Unregister a session")
    p_un.add_argument("id")

    args = parser.parse_args(argv)
    state_dir = Path(args.state_dir) if args.state_dir else None

    if args.cmd == "list":
        sessions = list_active_sessions(
            state_dir=state_dir,
            stale_after_min=args.stale_after_min,
            include_stale=args.include_stale,
        )
        if not sessions:
            print("(no active sessions)")
            return 0
        for s in sessions:
            stale_tag = " [stale]" if s.is_stale else ""
            print(
                f"{s.id}  project={s.project}  type={s.session_type}  "
                f"focus={s.focus!r}  last_seen={s.last_seen}{stale_tag}"
            )
        return 0

    if args.cmd == "register":
        s = register_session(
            args.id, args.project, args.session_type,
            focus=args.focus, state_dir=state_dir,
        )
        print(f"registered: {s.id}")
        return 0

    if args.cmd == "heartbeat":
        ok = heartbeat(args.id, focus=args.focus, state_dir=state_dir)
        print("ok" if ok else "not found")
        return 0 if ok else 1

    if args.cmd == "unregister":
        ok = unregister_session(args.id, state_dir=state_dir)
        print("removed" if ok else "not found")
        return 0 if ok else 1

    sys.stderr.write(f"unknown command: {args.cmd}\n")
    return 2


__all__ = [
    "ActiveSession",
    "register_session",
    "heartbeat",
    "unregister_session",
    "list_active_sessions",
    "get_active_session",
    "registry_path",
    "main",
]


if __name__ == "__main__":
    raise SystemExit(main())
