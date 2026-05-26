"""ChatRouter core — single canonical implementation of SPEC-002 routing.

The three GUI surfaces (Tk ``gui_shell.py``, Streamlit ``commands.py``
chat send, Resonance-Website ``action_dispatch._route_natural_language``)
all routed chat-submit bodies through their own copies of the routing
logic prior to this module. Deferred-concerns #17 named the divergence
explicitly: subtly different fallback ordering and slightly different
priority rules across the three implementations. This module is the
single canonical resolver they all call.

The module exposes two surfaces:

``route_chat(text, *, session_manager, ...)`` — the routing decision
function. Pure-Python; takes injected dependencies; returns the same
routing-decision dict shape the legacy implementations returned so the
three callers' downstream code (the chat-input writeback, the
view-state merge, the terminal response payload) keeps working
unchanged.

``ensure_default_workflow_mgmt_session(*, session_manager, ...)`` —
the marker-file + spawn helper that Tk + Streamlit both called inline.
Folds the racy marker-check + spawn into a single lock-protected
critical section (deferred-concerns #13 + #14) and routes spawn-failure
through the same ``surface_failure`` hook the routing path uses
(deferred-concerns #16 — failure surfacing parity).

The functions accept optional callable hooks so each surface keeps
control of its own UX:

  - ``surface_failure(reason, hint)`` — called on every soft-fail.
    Tk writes back into the chat input; terminal prints; the website
    folds it into the response payload.

  - ``audit_log(entry)`` — called with the routing-decision dict on
    every successful + soft-fail invocation. The website's existing
    ``_log_entry`` is plugged in here; the Apeiron-side surfaces
    (Tk gui_shell, terminal/Streamlit chat_router node) pass the
    default JSONL writer from ``route_chat_audit_log.audit_log_writer()``
    so routing decisions land at
    ``<apeiron-root>/state/workflow/route_chat_decisions.jsonl``
    with 10 MB rotation (deferred-concerns #15, closed 2026-05-26).
    Pass ``None`` to suppress audit logging entirely.

  - ``default_target_picker(sessions)`` — selects a fallback target
    when the caller's explicit ``active_session_id`` is ``None``. The
    website uses the workflow-management-preference picker; Tk +
    Streamlit pass ``None`` so the active-session-only behavior
    matches their pre-consolidation flow.

  - ``auto_spawn_handler(text)`` — invoked when no target resolves
    and the caller wants auto-spawn (the website's MVP path). Returns
    ``{ok: bool, session_id: str | None, error: str | None}``. Tk +
    Streamlit pass ``None`` to disable auto-spawn (they bootstrap via
    ``ensure_default_workflow_mgmt_session`` at boot instead).

The routing logic itself preserves the v2 ChatRouter parsing:
  - ``/all body`` → broadcast to every non-archived session.
  - ``@<name-or-id> body`` → resolve and route to that session,
    reactivating if archived.
  - bare body → echo (if inbox provided) + deliver to target.

Returns dict shape (unchanged from the prior three implementations'
intersection)::

    {"routed": bool,
     "target": str | "all" | None,
     "delivered_to": [str, ...],
     "message": str,
     "reason": str}
"""

from __future__ import annotations

import os
import threading
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional


# Type aliases for readability.
SurfaceFailureHook = Callable[[str, Optional[str]], None]
AuditLogHook = Callable[[Dict[str, Any]], None]
DefaultTargetPicker = Callable[[List[Dict[str, Any]]], Optional[Dict[str, Any]]]
AutoSpawnHandler = Callable[[str], Dict[str, Any]]


# ---------------------------------------------------------------------
# Public surface — route_chat
# ---------------------------------------------------------------------


def route_chat(
    text: str,
    *,
    session_manager: Any,
    inbox: Any = None,
    active_session_id: Optional[str] = None,
    default_target_picker: Optional[DefaultTargetPicker] = None,
    surface_failure: Optional[SurfaceFailureHook] = None,
    audit_log: Optional[AuditLogHook] = None,
    lock: Optional[threading.Lock] = None,
    auto_spawn_handler: Optional[AutoSpawnHandler] = None,
    actor: str = "maintainer",
) -> Dict[str, Any]:
    """Route a chat-submit body to the appropriate session.

    The single canonical implementation of SPEC-002 chat routing.
    Replaces three pre-existing implementations (Tk gui_shell.route_chat,
    Streamlit chat_router node-type _send, website
    _route_natural_language).

    Parsing:
      - ``/all body`` → broadcast to every non-archived session.
      - ``@<name-or-id> body`` → resolve + route to that session,
        reactivating if archived.
      - bare body → echo (if inbox) + deliver to fallback target.

    Fallback chain for bare-body routing:
      1. ``active_session_id`` if explicitly provided (the user's
         clicked-active target).
      2. ``default_target_picker(sessions)`` if provided — picks
         from the SessionManager registry (website's
         workflow-management-preference).
      3. ``auto_spawn_handler(text)`` if provided — spawns a fresh
         session with the text as seed prompt (website's MVP path).
      4. Soft-fail with ``routed=False, reason="no active session"``.

    Lock semantics: when ``lock`` is provided, the active-session
    resolution + auto-spawn flow is serialized through it. Closes
    deferred-concerns #13 + #14 — concurrent calls from the Tk UI
    thread and the text-API thread cannot race against each other.

    Failure semantics: every soft-fail dispatches to
    ``surface_failure(reason, hint=None)`` if provided. Closes
    deferred-concerns #16 — the GUI shell no longer silently swallows
    spawn failures.

    Returns the routing-decision dict the callers' downstream code
    consumes unchanged.
    """
    text = (text or "").strip()
    if not text:
        result = {
            "routed": False,
            "target": None,
            "delivered_to": [],
            "message": "",
            "reason": "empty body",
        }
        _emit(audit_log, result, actor, input_session=active_session_id)
        _surface_if_failed(surface_failure, result)
        return result

    # /all body → broadcast.
    if text == "/all" or text.startswith("/all "):
        result = _broadcast(
            text[len("/all"):].strip(),
            session_manager=session_manager,
        )
        _emit(audit_log, result, actor, input_session=active_session_id)
        _surface_if_failed(surface_failure, result)
        return result

    # @<name-or-id> body → resolve + send.
    if text.startswith("@"):
        head, _, body = text[1:].partition(" ")
        result = _route_at(
            head.strip(),
            body.strip(),
            session_manager=session_manager,
            inbox=inbox,
        )
        _emit(audit_log, result, actor, input_session=active_session_id)
        _surface_if_failed(surface_failure, result)
        return result

    # Bare body — resolve target through fallback chain.
    _lock = lock or _NoLock()
    with _lock:
        target = active_session_id
        if not target and default_target_picker is not None:
            picked = _safe_pick(default_target_picker, session_manager)
            if picked is not None:
                target = picked.get("id") or picked.get("session_id")
        # Auto-spawn if still no target and handler provided.
        if not target and auto_spawn_handler is not None:
            spawn_result = _safe_call(auto_spawn_handler, text) or {}
            if spawn_result.get("ok"):
                # Auto-spawn handlers seed the session with the text
                # itself, so the explicit send-step is skipped — the
                # session already received the message at spawn time.
                new_sid = str(spawn_result.get("session_id") or "")
                result = {
                    "routed": True,
                    "target": new_sid or None,
                    "delivered_to": [new_sid] if new_sid else [],
                    "message": text,
                    "reason": (
                        f"auto-spawned workflow_management session "
                        f"{new_sid[:8] if new_sid else '?'} "
                        f"with your message as the seed prompt"
                    ),
                }
                _emit(audit_log, result, actor, input_session=active_session_id)
                return result
            err = spawn_result.get("error") or "auto-spawn failed"
            result = {
                "routed": False,
                "target": None,
                "delivered_to": [],
                "message": text,
                "reason": f"natural-language routing failed: {err}",
            }
            _emit(audit_log, result, actor, input_session=active_session_id)
            _surface_if_failed(surface_failure, result)
            return result

    if target is None:
        result = {
            "routed": False,
            "target": None,
            "delivered_to": [],
            "message": text,
            "reason": "no active session — open Chat tab to pick one",
        }
        _emit(audit_log, result, actor, input_session=active_session_id)
        _surface_if_failed(surface_failure, result)
        return result

    # Deliver to the resolved target.
    result = _direct_send(
        target,
        text,
        session_manager=session_manager,
        inbox=inbox,
    )
    _emit(audit_log, result, actor, input_session=active_session_id)
    _surface_if_failed(surface_failure, result)
    return result


# ---------------------------------------------------------------------
# Public surface — ensure_default_workflow_mgmt_session
# ---------------------------------------------------------------------


def ensure_default_workflow_mgmt_session(
    *,
    session_manager: Any,
    seed_builder: Callable[[], str],
    cwd: Path,
    surface_failure: Optional[SurfaceFailureHook] = None,
    lock: Optional[threading.Lock] = None,
    marker_filename: str = "default_workflow_mgmt.txt",
    display_name: str = "workflow-mgmt-default",
) -> Optional[str]:
    """Ensure a workflow-management session exists; return its id.

    Single canonical implementation; replaces the three near-duplicate
    copies that lived in:

      - ``tools/workflow/shell.py::Shell.ensure_default_workflow_mgmt_session``
      - ``tools/workflow_gui/gui_shell.py::GuiShell.ensure_default_workflow_mgmt_session``
      - ``tools/workflow_streamlit/runtime.py::_ensure_default_session``

    Lock-protects the marker-check + spawn so two concurrent boot paths
    cannot orphan-spawn (closes deferred-concerns #13 — the
    ``filelock``-style atomic protection requested in the entry, but
    using a process-local threading lock since all three callers run
    in the same process). Cross-process collisions remain a (narrower)
    open window; a future arc can add an OS-level file lock if needed.

    Spawn failure routes through ``surface_failure(reason, hint)`` so
    the GUI shell + Streamlit no longer silently swallow it (closes
    deferred-concerns #16).

    Returns the active session id, or ``None`` if spawn failed.
    """
    _lock = lock or _NoLock()
    with _lock:
        marker = Path(session_manager.state_dir) / marker_filename
        existing_id: Optional[str] = None
        if marker.exists():
            try:
                existing_id = marker.read_text(encoding="utf-8").strip() or None
            except Exception:
                existing_id = None

        if existing_id:
            try:
                rec = session_manager.get(existing_id)
            except Exception:
                rec = None
            if rec is not None and getattr(rec, "status", None) != "archived":
                return existing_id

        # Fresh spawn (the marker is absent OR the recorded session is
        # archived/gone — fall through to a new spawn). Build the seed
        # lazily so callers that don't need it (the resume branch above)
        # don't pay for it.
        try:
            seed = seed_builder()
        except Exception as exc:
            _safe_call(surface_failure, f"seed_builder failed: {exc}", None)
            return None

        try:
            rec = session_manager.spawn(
                session_type="workflow-management",
                display_name=display_name,
                cwd=cwd,
                seed_message=seed,
            )
        except Exception as exc:
            _safe_call(
                surface_failure,
                f"could not auto-spawn workflow-management session: {exc}",
                "spawn manually with `/spawn workflow-management <name>` "
                "once `claude` is on PATH.",
            )
            return None

        # Write marker. The lock above already serialized the
        # marker-check + spawn against concurrent in-process callers,
        # so a plain overwrite is correct: the only writer in this
        # critical section is this thread. Cross-process collisions
        # (e.g., the GUI shell and the terminal shell running in
        # separate Python processes) would still race, but the
        # threading lock here closes the in-process window which is
        # what deferred-concerns #13 named. A future arc can add an
        # OS-level file lock if cross-process protection becomes
        # necessary; the surface is in one place.
        #
        # Plain write preserves the legacy semantics: when the
        # marker held an archived sid above, this overwrites with
        # the fresh sid so the next call resumes correctly.
        try:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(rec.id, encoding="utf-8")
        except Exception:
            # Marker write failed (disk full, permission, etc.); the
            # session is still spawned + usable. Persistence across
            # restarts is best-effort, not load-bearing.
            pass

        return rec.id


# ---------------------------------------------------------------------
# Sub-routines.
# ---------------------------------------------------------------------


def _direct_send(
    target: str,
    text: str,
    *,
    session_manager: Any,
    inbox: Any = None,
) -> Dict[str, Any]:
    """Bare-body delivery to a single resolved target. Optionally echoes
    the body to the inbox first; an inbox failure is fatal because the
    chat panels render from the inbox file, so a dropped echo means the
    UI loses the maintainer's typed-but-never-rendered message.
    """
    # Reactivate if archived/idle so the next message lands cleanly.
    try:
        rec = session_manager.get(target)
        if rec is not None and getattr(rec, "status", None) in ("archived", "idle"):
            try:
                session_manager.reactivate(target)
            except Exception:
                pass
    except Exception:
        pass

    if inbox is not None:
        try:
            inbox.post(to=target, body=text, sender="maintainer")
        except Exception as exc:
            return {
                "routed": False,
                "target": target,
                "delivered_to": [],
                "message": text,
                "reason": f"inbox.post failed: {exc}",
            }

    try:
        session_manager.send(target, text)
    except Exception as exc:
        return {
            "routed": False,
            "target": target,
            "delivered_to": [],
            "message": text,
            "reason": f"send failed: {exc}",
        }
    return {
        "routed": True,
        "target": target,
        "delivered_to": [target],
        "message": text,
        "reason": f"routed to {target}",
    }


def _route_at(
    head: str,
    body: str,
    *,
    session_manager: Any,
    inbox: Any = None,
) -> Dict[str, Any]:
    """@<name-or-id> body — resolve via session_manager, then deliver."""
    if not head or not body:
        return {
            "routed": False,
            "target": head or None,
            "delivered_to": [],
            "message": body,
            "reason": "@-prefix requires `@<name> <body>`",
        }
    sid = _resolve_session_id(head, session_manager=session_manager)
    if sid is None:
        return {
            "routed": False,
            "target": head,
            "delivered_to": [],
            "message": body,
            "reason": f"no session matched name/id {head!r}",
        }
    return _direct_send(sid, body, session_manager=session_manager, inbox=inbox)


def _broadcast(
    body: str,
    *,
    session_manager: Any,
) -> Dict[str, Any]:
    """/all body — enumerate sessions, deliver to each non-archived one."""
    if not body:
        return {
            "routed": False,
            "target": "all",
            "delivered_to": [],
            "message": "",
            "reason": "/all with empty body",
        }
    try:
        records = list(session_manager.list())
    except Exception as exc:
        return {
            "routed": False,
            "target": "all",
            "delivered_to": [],
            "message": body,
            "reason": f"sm.list failed: {exc}",
        }
    delivered: List[str] = []
    errors: List[str] = []
    for rec in records:
        if getattr(rec, "status", None) == "archived":
            continue
        sid = getattr(rec, "id", None)
        if not sid:
            continue
        try:
            session_manager.send(sid, body)
            delivered.append(sid)
        except Exception as exc:
            errors.append(f"{sid}: {exc}")
    # Preserve the legacy Tk semantics: /all is "routed" even when zero
    # sessions exist (the broadcast intent was satisfied — there were
    # just no recipients). Only flip ``routed=False`` when every active
    # send raised, which the per-error append above captures.
    all_sends_failed = bool(errors) and not delivered
    return {
        "routed": (not all_sends_failed),
        "target": "all",
        "delivered_to": delivered,
        "message": body,
        "reason": (
            f"broadcast to {len(delivered)} session(s)"
            + (f"; errors: {errors}" if errors else "")
        ),
    }


def _resolve_session_id(
    sid_or_name: str,
    *,
    session_manager: Any,
) -> Optional[str]:
    """Look up a session by exact id, then display_name, then id-prefix
    (≥4 chars). Returns None on no match OR ambiguous prefix.
    """
    if not sid_or_name:
        return None
    # Exact id match.
    try:
        rec = session_manager.get(sid_or_name)
    except Exception:
        rec = None
    if rec is not None:
        return rec.id
    # display_name match + id-prefix match.
    try:
        records = list(session_manager.list())
    except Exception:
        return None
    for rec in records:
        if getattr(rec, "display_name", None) == sid_or_name:
            return rec.id
    if len(sid_or_name) >= 4:
        prefix_matches = [
            rec.id for rec in records
            if getattr(rec, "id", "").startswith(sid_or_name)
        ]
        if len(prefix_matches) == 1:
            return prefix_matches[0]
        # Ambiguous prefix — return None so caller surfaces "no match"
        # rather than silently picking the wrong session.
    return None


# ---------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------


class _NoLock:
    """Context-manager that does nothing. Used when no real lock is
    supplied so the ``with lock:`` block doesn't need a None-check.
    """

    def __enter__(self) -> "_NoLock":
        return self

    def __exit__(self, *_args: Any) -> None:
        return None


def _emit(
    audit_log: Optional[AuditLogHook],
    result: Dict[str, Any],
    actor: str,
    input_session: Optional[str] = None,
) -> None:
    """Best-effort audit-log emit. Never raises.

    ``input_session`` carries the caller-supplied ``active_session_id``
    so the audit consumer can discriminate the active-session path
    from the default-picker path without re-running the routing
    logic. Defaults to ``None`` for backward-compatibility with
    hooks that don't need it (the website's ``_audit`` ignores it).
    """
    if audit_log is None:
        return
    try:
        entry = dict(result)
        entry["actor"] = actor
        if input_session is not None:
            entry["input_session"] = input_session
        audit_log(entry)
    except Exception:
        pass


def _surface_if_failed(
    surface_failure: Optional[SurfaceFailureHook],
    result: Dict[str, Any],
) -> None:
    """Best-effort failure-surfacing emit. Never raises. Only fires on
    soft-fail results (routed=False)."""
    if surface_failure is None or result.get("routed"):
        return
    try:
        surface_failure(result.get("reason", ""), None)
    except Exception:
        pass


def _safe_call(fn: Optional[Callable[..., Any]], *args: Any) -> Any:
    """Call ``fn(*args)`` swallowing exceptions. Returns the result or
    None on failure (or when fn is None).
    """
    if fn is None:
        return None
    try:
        return fn(*args)
    except Exception:
        return None


def _safe_pick(
    picker: DefaultTargetPicker,
    session_manager: Any,
) -> Optional[Dict[str, Any]]:
    """Call the default-target picker against the session list. Returns
    None on any exception so the caller proceeds to the next fallback."""
    try:
        records = list(session_manager.list())
    except Exception:
        return None
    # Convert records to dicts so the picker signature is uniform across
    # callers (the website passes registry dicts; Tk passes
    # SessionManager records).
    sessions = []
    for rec in records:
        if getattr(rec, "status", None) == "archived":
            continue
        sessions.append({
            "id": getattr(rec, "id", None),
            "display_name": getattr(rec, "display_name", None),
            "session_type": getattr(rec, "session_type", None),
            "last_seen": getattr(rec, "last_active_at", None)
                or getattr(rec, "spawned_at", None),
            "status": getattr(rec, "status", None),
        })
    try:
        return picker(sessions)
    except Exception:
        return None
