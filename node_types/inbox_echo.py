"""InboxEcho — post a message into the inbox.

Verb: ``post`` — payload ``{to, body, summary?, kind?, sender?}``.
Returns ``last_post: {posted, to, reason}`` via view-state.

Smallest possible inbox primitive. Composes with ``chat_router`` (for
echo on chat sends), ``session_*`` nodes (for status/event reporting),
and any future node that wants to surface a body in the inbox without
reimplementing the post call.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="InboxEcho",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description="Posts a body to the inbox; returns posted+to+reason.",
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"InboxEcho id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "post":
        to = payload.get("to") or "maintainer"
        body = payload.get("body") or ""
        summary = payload.get("summary") or (body.replace("\n", " ")[:80] if body else "")
        kind = payload.get("kind") or "chat"
        sender = payload.get("sender") or "maintainer"
        inbox = (engine.cache.get("__workflow__") or {}).get("inbox")
        if inbox is None:
            return {"last_post": {"posted": False, "to": to, "reason": "no inbox"}}
        try:
            inbox.post(to=to, kind=kind, summary=summary, body=body, sender=sender)
        except Exception as exc:
            return {"last_post": {
                "posted": False, "to": to, "reason": f"inbox.post failed: {exc}",
            }}
        return {"last_post": {"posted": True, "to": to, "reason": f"posted to {to}"}}
    return None
