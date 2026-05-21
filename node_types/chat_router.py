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
    """Deliver one body to one session. Returns a routing-decision dict.

    Three outcomes:
      - ``routed=True, delivered_to=[<sid>]`` — full echo + delivery
        (target known + reachable).
      - ``routed=True, delivered_to=[]`` — echo-only (no target; chat
        panel still wants the message rendered locally, so we post to
        the inbox with ``to=maintainer`` as a placeholder).
      - ``routed=False`` — hard failure (empty body, inbox post error,
        session send error, or session_manager missing when a target
        was named). The reason field carries the operator-facing
        explanation.

    Soft-fails on missing workflow singletons so headless contexts
    (tests, MCP-tool callers, future renderer-only consumers) can
    still dispatch without crashing.
    """
    if not text:
        return {"routed": False, "target": target, "reason": "empty body"}

    workflow = engine.cache.get("__workflow__", {})
    sm = workflow.get("session_manager")
    inbox = workflow.get("inbox")

    # Inbox echo so the chat panel renders the outgoing message. If
    # there's no target, echo to the maintainer placeholder so the
    # surface still shows the typed body — same behaviour the inline
    # _chat_send used to provide.
    echo_to = target or "maintainer"
    if inbox is not None:
        try:
            summary = text.replace("\n", " ")[:80]
            inbox.post(
                to=echo_to,
                kind="chat",
                summary=summary,
                body=text,
                sender="maintainer",
            )
        except Exception as exc:
            return {
                "routed": False,
                "target": target,
                "reason": f"inbox.post failed: {exc}",
            }

    # Echo-only when no target.
    if not target:
        return {
            "routed": True,
            "target": None,
            "delivered_to": [],
            "message": text,
            "reason": "echoed; no active session to deliver to",
        }

    if sm is None:
        return {
            "routed": False,
            "target": target,
            "reason": "engine.cache['__workflow__']['session_manager'] missing",
        }
    try:
        sm.send(target, text)
    except Exception as exc:
        return {
            "routed": False,
            "target": target,
            "reason": f"sm.send failed: {exc}",
        }
    return {
        "routed": True,
        "target": target,
        "delivered_to": [target],
        "message": text,
        "reason": f"routed to {target}",
    }
