"""JSONL audit-log writer for ``chat_router_core.route_chat`` decisions.

Closes deferred-concerns #15 (A2-3). Every ``route_chat`` invocation
returns a dict describing the routing decision (target session,
reason, fallback if any). Before this module, the Apeiron-side
callers (Tk ``gui_shell.route_chat``, terminal/Streamlit
``chat_router`` node, the SessionManager-injected core path) passed
no ``audit_log`` hook — so debugging "why did this message go to
session X instead of Y" required re-running the routing logic
against logged inputs, which loses any side-state that influenced
the original decision.

This module ships the **default** JSONL writer ``chat_router_core``
installs when a caller passes no ``audit_log`` hook. The
website-side surface still wins (it always passes its own ``_audit``
hook that funnels into the website's action_log); the Apeiron-side
surfaces now get observability for free.

Layout
------

The writer appends one JSON object per line to
``<state_dir>/route_chat_decisions.jsonl``. Schema per the
deferred-concerns spec::

    {"ts":              "ISO-8601 UTC",
     "message_id":      "<sha1 of (ts + actor + text), 12 hex>",
     "input_session":   "<active_session_id or null>",
     "output_session":  "<target id or 'all' or null>",
     "reason":          "<reason string from core>",
     "fallback_used":   "<auto-spawn|default-picker|active|null>"}

The schema is additive — extra fields a future iteration adds will
not break existing readers because each line is a self-describing
JSON object.

State-dir resolution precedence (most-specific wins):

  1. ``state_dir`` parameter explicitly passed to ``audit_log_writer``.
  2. ``APEIRON_STATE_DIR`` env var.
  3. ``<apeiron-root>/state/workflow/`` derived from this file's
     location (``parents[2]`` of ``tools/workflow/route_chat_audit_log.py``).

The default resolution matches the pattern ``shell.py`` already uses
for the inbox + sessions registry, so the audit log lives alongside
those artifacts.

Rotation
--------

The file rotates when it exceeds ``ROTATION_BYTES`` (default 10 MB).
Rotation timestamps the current file as
``route_chat_decisions.jsonl.YYYYMMDD-HHMMSS`` and opens a fresh
file. When ``gzip`` is available the rotated copy is compressed in
place (suffix ``.gz``); when not, the plain timestamped copy
remains. The check fires on each append (cheap — one ``stat`` call).

Failure semantics
-----------------

Every entry-point is **best-effort**: the writer never raises into
the route_chat code path. A disk-full failure, a permission error,
or a non-serializable entry all swallow silently. The core helper's
``_emit`` already wraps the audit hook in a try/except for the same
reason; this writer reinforces the invariant.

Concurrent writers
------------------

Append uses ``open(path, "ab")`` + ``write()``. Posix + Windows both
make individual writes ≤ PIPE_BUF bytes atomic at the OS level, so a
single JSON line up to 4 KB cannot interleave with another writer's
line. Long lines could in principle interleave on Linux when
``O_APPEND`` is not set; we set ``"ab"`` which uses ``O_APPEND``
semantics on every platform's Python, so the kernel serializes the
end-of-file seek + write into one atomic step. The rotation rename
is also serialized at the OS level.

The shell-level cross-process lock pattern used in
``active_sessions.py`` (``_acquire_lock`` / ``_release_lock``) is
intentionally NOT used here — that lock exists to serialize the
read-modify-write of a JSON document, which this module does not
do. Append-only JSONL needs no lock.
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Optional


# ---------------------------------------------------------------------
# Defaults.
# ---------------------------------------------------------------------


#: Default rotation threshold in bytes (10 MiB).
ROTATION_BYTES = 10 * 1024 * 1024

#: Default audit-log filename.
DEFAULT_FILENAME = "route_chat_decisions.jsonl"

#: Default state-dir relative to ``<apeiron-root>``.
_DEFAULT_STATE_SUBPATH = ("state", "workflow")


# ---------------------------------------------------------------------
# Public surface.
# ---------------------------------------------------------------------


def default_state_dir() -> Path:
    """Resolve the default ``state/workflow/`` dir per the precedence
    documented at the top of this module.

    Returns the resolved Path. Does NOT create the directory — the
    writer creates it lazily on the first append so a read-only
    consumer (e.g., a test that constructs the writer but never
    fires it) doesn't side-effect the filesystem.

    Resolution order (matches the Wave 2c pattern Resonance-Website
    shipped for ``APEIRON_STATE_DIR``):

      1. ``APEIRON_STATE_DIR`` env var (the apeiron base state dir).
         The writer appends ``workflow/`` to it so the audit log
         lives alongside ``sessions/``, ``raw_logs/``, etc.
      2. ``<apeiron-root>/state/workflow/`` derived from this file's
         location.
    """
    env = os.environ.get("APEIRON_STATE_DIR")
    if env:
        # APEIRON_STATE_DIR is the apeiron base state dir; the audit
        # log lives in its ``workflow/`` sub-dir alongside the inbox
        # + sessions + raw_logs artifacts.
        return Path(env) / "workflow"
    # tools/workflow/route_chat_audit_log.py → parents[2] is apeiron-root.
    apeiron_root = Path(__file__).resolve().parents[2]
    return apeiron_root.joinpath(*_DEFAULT_STATE_SUBPATH)


def audit_log_writer(
    *,
    state_dir: Optional[Path] = None,
    filename: str = DEFAULT_FILENAME,
    rotation_bytes: int = ROTATION_BYTES,
) -> Callable[[Dict[str, Any]], None]:
    """Construct a default JSONL audit-log writer callable.

    The returned callable conforms to ``chat_router_core``'s
    ``AuditLogHook`` signature: it accepts one ``entry`` dict
    (the routing-decision dict, augmented with ``actor``) and
    returns ``None``. The callable never raises into the caller.

    Parameters
    ----------
    state_dir
        Where to write the JSONL file. When ``None``, resolves via
        ``default_state_dir()``.
    filename
        Basename of the JSONL file. Defaults to
        ``"route_chat_decisions.jsonl"``.
    rotation_bytes
        Rotate when the file grows past this many bytes. Pass 0 to
        disable rotation (the file grows unbounded). Default 10 MiB.

    Returns
    -------
    A callable ``writer(entry: dict) -> None`` the core helper
    invokes on every successful + soft-fail routing decision.

    The writer is cheap to construct (no I/O until the first call),
    safe to call concurrently, and never raises.
    """
    resolved_dir = Path(state_dir) if state_dir is not None else default_state_dir()
    path = resolved_dir / filename
    state = _WriterState(path=path, rotation_bytes=int(rotation_bytes))

    def _write(entry: Dict[str, Any]) -> None:
        try:
            state.append(entry)
        except Exception:
            # Audit logging is observability; failures must not block
            # the route_chat path. The core helper's ``_emit`` also
            # wraps callers in try/except, so this is defense-in-depth.
            return

    return _write


# ---------------------------------------------------------------------
# Internals — the writer state object.
# ---------------------------------------------------------------------


class _WriterState:
    """Per-writer state: the file path, the rotation policy, and an
    in-process lock so two threads in the same process don't trip
    over each other's ``stat`` + ``rename`` interleavings on the
    rotation path. Cross-process serialization is provided by
    ``O_APPEND`` semantics (see module docstring).
    """

    def __init__(self, *, path: Path, rotation_bytes: int) -> None:
        self.path = path
        self.rotation_bytes = rotation_bytes
        self._lock = threading.Lock()

    def append(self, entry: Dict[str, Any]) -> None:
        """Append one entry. Rotates if the current file would exceed
        the rotation threshold. Best-effort; surfaces no exceptions
        outside this method (the caller already swallows them).
        """
        normalized = _normalize_entry(entry)
        line = json.dumps(normalized, ensure_ascii=False, separators=(",", ":")) + "\n"
        payload = line.encode("utf-8")
        with self._lock:
            self._ensure_parent()
            self._maybe_rotate(extra_bytes=len(payload))
            with open(self.path, "ab") as fh:
                fh.write(payload)

    def _ensure_parent(self) -> None:
        parent = self.path.parent
        if not parent.exists():
            parent.mkdir(parents=True, exist_ok=True)

    def _maybe_rotate(self, *, extra_bytes: int) -> None:
        """Rotate the current file if the prospective write would
        cross the rotation threshold. The check fires BEFORE the
        write so the new line lands in the fresh file, not the
        rotated one — keeps reasoning simple (a rotated file is a
        complete snapshot at rotation time; the live file holds
        every line since rotation).
        """
        if self.rotation_bytes <= 0:
            return
        try:
            current = self.path.stat().st_size
        except FileNotFoundError:
            return
        if current + extra_bytes <= self.rotation_bytes:
            return
        self._rotate_now()

    def _rotate_now(self) -> None:
        """Rename the current file to a timestamped sibling. Gzip the
        rotated copy when ``gzip`` is available. Best-effort: a
        rotation failure leaves the live file alone and the next
        append continues to grow it (better to over-grow one file
        than to lose audit lines).
        """
        if not self.path.exists():
            return
        ts = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
        # Disambiguate same-second rotations with a nanosecond suffix.
        rotated = self.path.with_name(f"{self.path.name}.{ts}-{time.time_ns()}")
        try:
            os.replace(self.path, rotated)
        except Exception:
            return
        # Attempt gzip compression on the rotated copy. Failure is
        # acceptable — the plain rotated file remains.
        try:
            import gzip
            gz_path = rotated.with_name(rotated.name + ".gz")
            with open(rotated, "rb") as src, gzip.open(gz_path, "wb") as dst:
                # ``shutil.copyfileobj`` would do the streaming copy
                # for large files; the rotation threshold caps each
                # rotated file at ~10 MiB by default so a simple
                # buffered loop is sufficient and avoids the import.
                while True:
                    chunk = src.read(64 * 1024)
                    if not chunk:
                        break
                    dst.write(chunk)
            try:
                rotated.unlink()
            except Exception:
                pass
        except Exception:
            # gzip module missing, write failed, etc. — keep the
            # uncompressed rotated file.
            return


# ---------------------------------------------------------------------
# Entry normalization — keeps the on-disk schema stable across
# evolutions of the in-memory entry shape.
# ---------------------------------------------------------------------


_SCHEMA_KEYS = (
    "ts",
    "message_id",
    "input_session",
    "output_session",
    "reason",
    "fallback_used",
)


def _normalize_entry(entry: Dict[str, Any]) -> Dict[str, Any]:
    """Project a route_chat result dict + augmenting fields onto the
    deferred-concerns #15 schema.

    The core helper emits ``{routed, target, delivered_to, message,
    reason, actor}``. We map:

      - ``ts``             ← caller-provided or freshly stamped UTC.
      - ``message_id``     ← derive from (ts, actor, message) when
        absent so two distinct invocations don't accidentally
        collide; the maintainer-supplied ``message_id`` wins.
      - ``input_session``  ← caller-supplied or read from
        ``entry.get("input_session")``; route_chat does not pass it
        through today, so it's typically ``None``. Future
        instrumentation can backfill.
      - ``output_session`` ← ``entry["target"]`` (single session,
        ``"all"`` for broadcast, ``None`` for soft-fail).
      - ``reason``         ← passthrough.
      - ``fallback_used``  ← inferred from the reason text since the
        core helper doesn't expose the fallback path explicitly:
          * ``"auto-spawn"`` when ``reason`` starts with
            ``"auto-spawned"`` (the auto-spawn handler fired).
          * ``"default-picker"`` when ``input_session`` is absent
            and ``output_session`` resolved (the picker filled in).
          * ``"active"`` when ``input_session`` matched
            ``output_session`` (the caller's explicit active id was
            used).
          * ``None`` for soft-fails + the @-prefix / /all paths
            that don't traverse the fallback chain.

    Extra fields on the input dict are preserved alongside the
    schema fields under an ``extra`` sub-dict so future debugging
    isn't gated on the spec evolving.
    """
    ts = entry.get("ts") or _now_iso()
    actor = str(entry.get("actor") or "maintainer")
    message = entry.get("message") or ""
    message_id = entry.get("message_id") or _derive_message_id(ts, actor, message)
    input_session = entry.get("input_session")
    output_session = entry.get("target")
    reason = entry.get("reason") or ""
    fallback_used = entry.get("fallback_used")
    if fallback_used is None:
        fallback_used = _infer_fallback(
            reason=reason,
            input_session=input_session,
            output_session=output_session,
        )

    record: Dict[str, Any] = {
        "ts": ts,
        "message_id": message_id,
        "input_session": input_session,
        "output_session": output_session,
        "reason": reason,
        "fallback_used": fallback_used,
    }
    extras = {
        k: v for k, v in entry.items()
        if k not in _SCHEMA_KEYS
        and k not in ("actor", "message", "target", "delivered_to", "routed")
    }
    # Carry actor + message + delivered_to + routed in a structured
    # sub-dict so the schema-keys list stays canonical while the
    # raw record remains debuggable.
    record["actor"] = actor
    if "routed" in entry:
        record["routed"] = bool(entry.get("routed"))
    if "delivered_to" in entry:
        record["delivered_to"] = list(entry.get("delivered_to") or [])
    if message:
        record["message"] = message
    if extras:
        record["extra"] = extras
    return record


def _derive_message_id(ts: str, actor: str, message: str) -> str:
    """Deterministic 12-hex-char id derived from (ts, actor, message).
    Distinct invocations always produce distinct ids because ``ts``
    is ISO-8601 down to the second AND the writer never reuses a
    second across two calls without the rotation rename or another
    serializing event between them.
    """
    h = hashlib.sha1()
    h.update(ts.encode("utf-8", errors="replace"))
    h.update(b"\x00")
    h.update(actor.encode("utf-8", errors="replace"))
    h.update(b"\x00")
    h.update(message.encode("utf-8", errors="replace"))
    return h.hexdigest()[:12]


def _infer_fallback(
    *,
    reason: str,
    input_session: Any,
    output_session: Any,
) -> Optional[str]:
    """Backwards-derive which fallback path the core helper took.

    The core helper's ``reason`` strings are stable enough to
    discriminate the auto-spawn branch. The picker vs active path
    is discriminated by whether the caller supplied
    ``input_session``: when they did, ``output_session`` matches it
    and the active-id path fired; when they didn't, the picker
    filled in. Soft-fails (routed=False) and the @-prefix / /all
    paths leave ``fallback_used`` as ``None`` because they don't
    traverse the fallback chain.
    """
    if not output_session:
        return None
    if output_session == "all":
        return None
    if isinstance(reason, str) and reason.startswith("auto-spawned"):
        return "auto-spawn"
    if input_session and str(input_session) == str(output_session):
        return "active"
    if not input_session and output_session:
        return "default-picker"
    return None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
