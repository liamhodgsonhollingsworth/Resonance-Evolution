"""AuthGate — surface-independent password authentication.

Lift #8 of the chat_router architectural arc. Before this node, the
Streamlit login panel called ``tools.workflow.auth.authenticate``
directly. The HTML surface (planned) and the MCP-tool surface (for
authenticated remote callers) need the exact same check, against the
exact same accounts store, with no Streamlit dependency.

Verbs:
  - ``authenticate`` — verify (username, password) against the accounts
    file; returns ok/fail + the reason.
  - ``has_any_account`` — return True if the store has at least one
    account (used by the HTML surface's first-run flow to decide
    between "sign in" and "create initial account").
  - ``list_accounts`` — return the usernames (no password material).

The node reads ``accounts_path`` from the workflow singleton at
``engine.cache["__workflow__"]["accounts_path"]``.

The node deliberately does NOT touch ``st.session_state`` or call
``st.rerun`` — those decisions belong to the surface. The Streamlit
panel composes ``auth_gate.authenticate`` + ``st.session_state["user"]
= username`` + ``st.rerun``; an HTML surface composes the same first
verb with its own session-cookie write.

The result lands in view-state under ``last_authenticate`` so any
surface can read the most recent attempt's outcome without depending
on a side-channel.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="AuthGate",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Surface-independent password authentication. Verbs: "
            "authenticate / has_any_account / list_accounts. Reads "
            "accounts_path from the workflow singleton."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"AuthGate id={ctx.node.id}"


def _accounts_path(engine: Any) -> Optional[Path]:
    workflow = engine.cache.get("__workflow__") or {}
    ap = workflow.get("accounts_path")
    return Path(ap) if ap is not None else None


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    accounts_path = _accounts_path(engine)
    if accounts_path is None:
        return {"last_error": "no accounts_path on workflow singleton"}

    if action_name == "authenticate":
        username = (payload.get("username") or "").strip()
        password = payload.get("password") or ""
        if not username:
            return {"last_authenticate": {
                "ok": False, "reason": "username required",
            }}
        if not password:
            return {"last_authenticate": {
                "ok": False, "username": username,
                "reason": "password required",
            }}
        from tools.workflow import auth as auth_module
        ok = auth_module.authenticate(
            username, password, accounts_path=accounts_path
        )
        return {"last_authenticate": {
            "ok": ok, "username": username,
            "reason": "ok" if ok else "incorrect username or password",
        }}

    if action_name == "has_any_account":
        from tools.workflow import auth as auth_module
        try:
            present = auth_module.has_any_account(accounts_path=accounts_path)
        except Exception as exc:
            return {"last_has_any_account": {
                "ok": False, "reason": f"store read failed: {exc}",
            }}
        return {"last_has_any_account": {"ok": True, "present": bool(present)}}

    if action_name == "list_accounts":
        from tools.workflow import auth as auth_module
        try:
            names: List[str] = auth_module.list_accounts(
                accounts_path=accounts_path
            )
        except Exception as exc:
            return {"last_list_accounts": {
                "ok": False, "reason": f"store read failed: {exc}",
            }}
        return {"last_list_accounts": {"ok": True, "accounts": list(names)}}

    return None
