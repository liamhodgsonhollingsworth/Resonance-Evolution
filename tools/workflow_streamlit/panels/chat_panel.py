"""Chat panel — inbox messages above, text input below.

The send action dispatches ``chat.send <text>`` through the registry so
the typed message is logged in the terminal as the CLI form a typist
would run. The same command works from the terminal, from the bridge
queue, or from ``python -m tools.workflow_streamlit.cli chat.send …``.

Per the maintainer's preference, the chat surface shows only inbox
messages (``Alethea-cc/nodes/inbox_msg_*.md``-style files) — never raw
stream-json from the Claude Code subprocess.
"""

from __future__ import annotations

import time
from html import escape
from typing import Any, List

import streamlit as st

from tools.workflow_streamlit.panels._common import (
    MOUNT_BOTTOM,
    PanelContext,
    PanelManifest,
)


MAX_MESSAGES = 40


def manifest() -> PanelManifest:
    return PanelManifest(
        name="chat",
        description="Chat with the active workflow-management session, via inbox.",
        mount_point=MOUNT_BOTTOM,
        order=10,
    )


def render(ctx: PanelContext) -> None:
    registry = ctx.scratch.get("command_registry")
    if registry is None:
        st.warning("command registry missing; chat disabled")
        return

    st.markdown("## Chat")
    messages = _load_chat_messages(ctx)
    if not messages:
        st.markdown(
            '<div class="empty-hint">No messages yet. Type below to start.</div>',
            unsafe_allow_html=True,
        )
    else:
        for msg in messages:
            _render_message(msg, ctx.user or "maintainer")

    sid = ctx.active_session_id
    disabled = sid is None
    placeholder = (
        "no active session — spawn one from the sidebar"
        if disabled
        else "send a message to the workflow-management session…"
    )
    user_text = st.chat_input(placeholder, disabled=disabled, key="chat-input")
    if user_text:
        result = registry.run_gui("chat.send", ctx.as_command_context(), user_text)
        if not result.ok:
            st.error(result.message)
        st.rerun()


def _load_chat_messages(ctx: PanelContext) -> List[Any]:
    try:
        all_msgs = ctx.inbox.list_all(unread_only=False)
    except Exception:
        return []
    sid = ctx.active_session_id
    rel = [m for m in all_msgs if _is_chat_message(m, sid)]
    return rel[-MAX_MESSAGES:]


def _is_chat_message(msg: Any, session_id: str | None) -> bool:
    if msg.to == "maintainer":
        return True
    if session_id and msg.to == session_id and msg.sender == "maintainer":
        return True
    return False


def _render_message(msg: Any, current_user: str) -> None:
    is_self = msg.sender == "maintainer"
    klass = "chat-msg from-maintainer" if is_self else "chat-msg from-session"
    when = time.strftime("%H:%M:%S", time.localtime(msg.ts)) if msg.ts else ""
    sender = msg.sender or "?"
    summary = msg.summary or ""
    body = (msg.body or "").strip()
    body_html = (
        f'<div class="body">{escape(body)}</div>'
        if body and body != summary
        else ""
    )
    st.markdown(
        f'<div class="{klass}">'
        f'  <div class="from">{escape(when)}  ·  {escape(sender)}  ·  to {escape(msg.to)}</div>'
        f'  <div class="summary">{escape(summary)}</div>'
        f"  {body_html}"
        f"</div>",
        unsafe_allow_html=True,
    )
