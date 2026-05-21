"""ChatRouter — routes chat-submit bodies through SessionManager + Inbox.

A logic node-type that lives in the scene and handles ``send`` actions
dispatched via ``engine.actions.dispatch_action``. Both the Tk surface
(``tools/workflow_gui/``) and the Streamlit surface
(``tools/workflow_streamlit/``) route their chat input through this
node so chat semantics are identical across renderers — the first
concrete demonstration of the maintainer's 2026-05-21 directive:

    *"the nodes that handle the logic for a GUI should be the same if
    the GUI is coded in html or in some other language."*

A surface no longer reimplements chat routing inline. Instead, it
calls::

    engine.actions.dispatch_action(
        engine, "chat_router_main", "send",
        payload={"text": user_text, "session_id": active_session_id},
    )

The handler reads the result from
``engine.cache['__view_state__']['chat_router_main']['last_route']``
which holds the routing-decision dict.

Workflow-layer dependencies (``SessionManager``, ``Inbox``) live in
``engine.cache['__workflow__']`` per a new convention this node
introduces. Surfaces register their workflow singletons at boot::

    engine.cache["__workflow__"] = {
        "session_manager": sm,
        "inbox": inbox,
    }

The handler reads them lazily — if a surface forgets to register, the
``send`` action soft-fails with a clear reason rather than crashing.
This keeps the node usable from headless contexts (tests, MCP-tool
invocations) where workflow singletons may not exist.

v1 ships the ``send`` action only (one body, one target). The
``/all`` broadcast and ``@<name>`` routing currently live in
``tools/workflow_gui/gui_shell.py::route_chat`` and are scheduled for
migration into this node-type in a follow-up arc.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="ChatRouter",
        version="1.0",
        renderer_id="logic",
        inputs={"default_target": "string"},
        outputs={},
        description=(
            "Routes chat-submit bodies through SessionManager + Inbox. "
            "Both Tk and Streamlit surfaces dispatch 'send' actions "
            "here so chat semantics are identical across renderers."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "default_target": params.get("default_target") or None,
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return (
        f"ChatRouter id={ctx.node.id} "
        f"default_target={state.get('default_target')!r}"
    )


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    """Action surface entry; both shells dispatch here.

    ``send``: route one body to one session. Payload keys::
        text       — the message body
        session_id — explicit target (None falls back to ``default_target``)
    Result is merged into the renderer's view-state as ``last_route``.

    ``set_default_target``: change the default routing target so
    subsequent ``send`` calls without an explicit ``session_id`` use
    the new default. Payload: ``{"session_id": str | None}``.

    Build-time vs runtime state. ``state`` is ``node.state`` (the
    build() output, treated as immutable runtime defaults). Runtime
    mutations live in view-state — ``engine.cache['__view_state__'][node.id]``
    — which is what handlers' state-delta returns merge into. For a
    field like ``default_target`` that the build() seeds but
    set_default_target mutates at runtime, read from view-state first
    and fall back to node.state. This is the same separation that
    ``architecture.md`` commits to and that ``engine/actions.py``
    enforces on the engine side.
    """
    view = engine.cache.setdefault("__view_state__", {}).setdefault(node.id, {})
    current_default = view.get("default_target", state.get("default_target"))

    if action_name == "send":
        text = (payload.get("text") or "").strip()
        target = payload.get("session_id") or current_default
        result = _send(engine, target, text)
        return {"last_route": result}
    if action_name == "set_default_target":
        new_sid = payload.get("session_id")
        return {"default_target": new_sid}
    return None


def _send(engine: Any, target: Optional[str], text: str) -> Dict[str, Any]:
    """Route one chat-submit body. v2: parses /all + @<name> + bare.

    Composes other nodes via dispatch_action — does NOT call inbox.post
    or sm.send directly. The composition surface:
      - ``inbox_echo_main`` — for the inbox-echo step (post to inbox).
      - ``session_resolver_main`` — for @<name> → session_id resolution.
      - ``session_sender_main`` — for the actual stdin delivery.
      - ``session_lister_main`` — for the /all broadcast enumeration.

    Three syntactic forms:
      - ``/all body`` — broadcast to every non-archived session.
      - ``@<name-or-id> body`` — resolve and route to that session.
      - bare body — echo + (if target) deliver to target.

    Outcomes follow the v1 contract: ``routed=True/False`` +
    ``target`` + ``delivered_to`` + ``reason`` for caller inspection.
    """
    text = (text or "").strip()
    if not text:
        return {"routed": False, "target": target, "reason": "empty body"}

    # /all body → broadcast
    if text == "/all" or text.startswith("/all "):
        body = text[len("/all"):].strip()
        if not body:
            return {
                "routed": False, "target": "all", "delivered_to": [],
                "reason": "/all with empty body",
            }
        return _broadcast(engine, body)

    # @<name-or-id> body → resolve + send
    if text.startswith("@"):
        head, _, body = text[1:].partition(" ")
        head, body = head.strip(), body.strip()
        if not head or not body:
            return {
                "routed": False, "target": head or None, "delivered_to": [],
                "reason": "@-prefix requires `@<name> <body>`",
            }
        return _route_at(engine, head, body)

    # Bare body → echo + deliver to target.
    return _direct_send(engine, target, text)


# ---------------------------------------------------------------------
# Sub-routines that compose other nodes via dispatch_action.
# ---------------------------------------------------------------------


def _dispatch(engine: Any, renderer_id: str, action_name: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """Helper: dispatch + return view-state dict for the renderer."""
    from engine import actions as eng_actions
    eng_actions.dispatch_action(
        engine, renderer_id=renderer_id, action_name=action_name, payload=payload
    )
    return eng_actions.get_view_state(engine, renderer_id)


def _echo(engine: Any, to: str, body: str) -> Dict[str, Any]:
    """Echo via inbox_echo_main."""
    view = _dispatch(
        engine, "inbox_echo_main", "post",
        payload={"to": to, "body": body, "sender": "maintainer"},
    )
    return view.get("last_post", {})


def _sender_send(engine: Any, session_id: str, body: str) -> Dict[str, Any]:
    """Deliver via session_sender_main."""
    view = _dispatch(
        engine, "session_sender_main", "send",
        payload={"session_id": session_id, "body": body},
    )
    return view.get("last_send", {})


def _direct_send(engine: Any, target: Optional[str], text: str) -> Dict[str, Any]:
    """Bare-body path: echo + (if target) deliver."""
    echo_to = target or "maintainer"
    echo = _echo(engine, echo_to, text)
    if not echo.get("posted"):
        # Inbox echo failure is non-fatal when no inbox is registered
        # (test/headless contexts); but a real post error fails the route.
        if echo.get("reason", "") != "no inbox":
            return {
                "routed": False, "target": target, "delivered_to": [],
                "reason": f"inbox.post failed: {echo.get('reason')}",
            }

    if not target:
        return {
            "routed": True, "target": None, "delivered_to": [],
            "message": text,
            "reason": "echoed; no active session to deliver to",
        }

    send = _sender_send(engine, target, text)
    if not send.get("sent"):
        return {
            "routed": False, "target": target, "delivered_to": [],
            "reason": send.get("reason") or "session_sender unavailable",
        }
    return {
        "routed": True, "target": target, "delivered_to": [target],
        "message": text, "reason": f"routed to {target}",
    }


def _route_at(engine: Any, name: str, body: str) -> Dict[str, Any]:
    """@<name> path: resolve via session_resolver_main, then deliver."""
    res_view = _dispatch(
        engine, "session_resolver_main", "resolve",
        payload={"name_or_id": name},
    )
    res = res_view.get("last_resolution", {})
    if not res.get("resolved"):
        return {
            "routed": False, "target": name, "delivered_to": [],
            "reason": res.get("reason") or f"unresolved: {name!r}",
        }
    sid = res["session_id"]
    # Echo + deliver via the existing sub-routines.
    echo = _echo(engine, sid, body)
    if not echo.get("posted") and echo.get("reason", "") != "no inbox":
        return {
            "routed": False, "target": sid, "delivered_to": [],
            "reason": f"inbox.post failed: {echo.get('reason')}",
        }
    send = _sender_send(engine, sid, body)
    if not send.get("sent"):
        return {
            "routed": False, "target": sid, "delivered_to": [],
            "reason": send.get("reason") or "session_sender unavailable",
        }
    return {
        "routed": True, "target": sid, "delivered_to": [sid],
        "message": body, "reason": f"routed via @-prefix to {sid}",
    }


def _broadcast(engine: Any, body: str) -> Dict[str, Any]:
    """/all path: enumerate sessions via session_lister_main, deliver to each."""
    list_view = _dispatch(engine, "session_lister_main", "refresh", payload={})
    sessions = list_view.get("sessions") or []
    delivered: list = []
    errors: list = []
    for s in sessions:
        if s.get("status") == "archived":
            continue
        sid = s.get("id")
        if not sid:
            continue
        send = _sender_send(engine, sid, body)
        if send.get("sent"):
            delivered.append(sid)
        else:
            errors.append((sid, send.get("reason")))
    return {
        "routed": bool(delivered),
        "target": "all",
        "delivered_to": delivered,
        "message": body,
        "reason": (
            f"broadcast to {len(delivered)} session(s)"
            + (f"; errors: {errors}" if errors else "")
        ),
    }
