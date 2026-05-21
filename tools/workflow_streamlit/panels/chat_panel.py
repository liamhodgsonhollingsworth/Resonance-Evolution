"""Chat panel — inbox messages above, text input below.

Per the maintainer's preference, the chat surface shows only **inbox
messages** (``Alethea-cc/nodes/inbox_msg_*.md``-style files) — never raw
stream-json from the Claude Code subprocess. Sessions post visible chat
turns via the inbox; the rest of their output stays under the hood. The
seed prompt in ``runtime.py::_default_seed_message`` tells the session
this protocol.

User input flows through two paths so both surfaces see it:

1. The text is sent to the session via ``SessionManager.send`` (stdin to
   the claude CLI subprocess), so the session sees it as a new turn.
2. The same text is also posted as an inbox message from
   ``maintainer`` to ``<session id>``, so it appears in the chat
   history immediately rather than waiting for the session to echo it.
"""

from __future__ import annotations

import time
from html import escape
from typing import Any, List

import streamlit as st

from tools.workflow_streamlit.panels._common import MOUNT_BOTTOM, PanelContext, PanelManifest


# How many recent inbox messages to surface. Older ones still exist on
# disk; this limit only governs the visible window per render.
MAX_MESSAGES = 40


def manifest() -> PanelManifest:
    return PanelManifest(
        name="chat",
        description="Chat with the active workflow-management session, via inbox.",
        mount_point=MOUNT_BOTTOM,
        order=10,
    )


def render(ctx: PanelContext) -> None:
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

    _render_input(ctx)


def _load_chat_messages(ctx: PanelContext) -> List[Any]:
    """Pull recent inbox messages relevant to the maintainer-↔-session chat.

    "Relevant" = either addressed to ``maintainer`` (session→maintainer
    direction) or addressed to the active session and from
    ``maintainer`` (maintainer→session direction). Anything else is
    out-of-band inter-session chatter we don't render here.
    """
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


def _render_input(ctx: PanelContext) -> None:
    sid = ctx.active_session_id
    disabled = sid is None
    placeholder = (
        "no active session — spawn one from the sidebar"
        if disabled
        else "send a message to the workflow-management session…"
    )
    user_text = st.chat_input(placeholder, disabled=disabled, key="chat-input")
    if not user_text:
        return
    # Path 1: post visible inbox message so the user sees their own send.
    try:
        ctx.inbox.post(
            to=sid or "maintainer",
            kind="chat",
            summary=_truncate_summary(user_text),
            body=user_text,
            sender="maintainer",
        )
    except Exception as exc:
        st.error(f"failed to log message in inbox: {exc}")
    # Path 2: deliver to the session over stdin.
    if sid:
        try:
            ctx.session_manager.send(sid, user_text)
        except Exception as exc:
            st.error(f"session send failed: {exc}")
    st.rerun()


def _truncate_summary(text: str, max_len: int = 80) -> str:
    one_line = text.replace("\n", " ").strip()
    if len(one_line) <= max_len:
        return one_line
    return one_line[: max_len - 1] + "…"
