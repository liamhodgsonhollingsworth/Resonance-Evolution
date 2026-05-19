"""
TrustedSendersSource — emits the trusted-senders list (sender-trust or
session-trust) as panel items, with a per-item ``revoke-trust`` action.

Composes with ``trust.TrustSet``. The ``kind`` parameter picks which
trust-set to read:

- ``sender`` → the maintainer's inbox trust-set (SPEC-057).
- ``session`` → the per-session trust-set (SPEC-059).

The action handlers are stored alongside items in
``engine.cache[node_id]`` under ``_action_handlers``. The ListRenderer's
``handle_action`` delegates ``revoke-trust`` to this dict and clears the
expanded-item view-state on success so the panel returns to its list
view immediately.

Note: pattern-default-trust (e.g. ``node_types/*.py``) entries that the
TrustSet treats as trusted-by-default do not appear in
``list_trusted()`` and so will not appear in the panel — only
explicitly-added identities are listed. Removing a default-pattern
match is not meaningful; only explicit trust grants are revocable.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="TrustedSendersSource",
        version="1.0",
        renderer_id="raster",
        inputs={
            "root": "string",
            "user": "string",
            "kind": "string",
        },
        outputs={"items": "list_of_dict"},
        description=(
            "Trusted senders (sender-trust or session-trust). Per-item "
            "action: revoke-trust."
        ),
    )


def build(params):
    return {
        "root": str(params.get("root", ".")),
        "user": str(params.get("user", "")),
        "kind": str(params.get("kind", "sender")),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    return []


def precompute_hook(state, engine, node):
    from tools.workflow.trust import sender_trust_set, session_trust_set

    root = Path(state["root"])
    user = state["user"] or None
    kind = state["kind"]

    try:
        ts = session_trust_set(root, user) if kind == "session" else sender_trust_set(root, user)
        senders = ts.list_trusted()
    except Exception as e:
        return {"items": [], "error": f"TrustedSendersSource: {e}"}

    items: List[Dict[str, Any]] = []
    for sender in senders:
        items.append({
            "id": f"trusted:{kind}:{sender}",
            "title": sender,
            "body": (
                f"{kind}-trust granted to {sender!r}.\n"
                f"Trust file: {ts.path}\n"
                "Action 'revoke-trust' removes this entry."
            ),
            "status": "granted",
            "meta": {"sender": sender, "trust_kind": kind},
            "actions": ["expand", "revoke-trust"],
        })

    handlers = _build_action_handlers(root, user or "", kind)
    return {"items": items, "error": None, "_action_handlers": handlers}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    cache = ctx.engine.cache.get(ctx.node.id, {}) or {}
    return {
        "items": cache.get("items", []),
        "source_error": cache.get("error"),
    }


def describe(state, ctx: EmitContext) -> str:
    cache = ctx.engine.cache.get(ctx.node.id, {}) or {}
    items = cache.get("items", [])
    err = cache.get("error")
    if err:
        return f"TrustedSendersSource: error — {err}"
    return f"TrustedSendersSource(kind={state['kind']!r}, items={len(items)})"


def _build_action_handlers(root: Path, user: str, kind: str):
    from tools.workflow.trust import sender_trust_set, session_trust_set

    def _get_ts():
        if kind == "session":
            return session_trust_set(root, user or None)
        return sender_trust_set(root, user or None)

    def _revoke(payload, engine, node):
        item = payload.get("item") or {}
        sender = (item.get("meta") or {}).get("sender")
        if not sender:
            return None
        ts = _get_ts()
        ts.remove(sender)
        engine.precompute()
        return {
            "recent_action": ("revoke-trust", sender),
            "expanded_item": None,
        }

    return {"revoke-trust": _revoke}
