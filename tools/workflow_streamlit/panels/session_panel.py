"""Sidebar session-status panel.

Shows the current default workflow-management session (id, status,
display name) plus a small "respawn" button for the case where the
session has died. Other panels read ``ctx.active_session_id`` so this
panel does not change that field — the driver fills it in from the
runtime's persisted marker.
"""

from __future__ import annotations

import streamlit as st

from tools.workflow_streamlit.panels._common import MOUNT_SIDEBAR, PanelContext, PanelManifest


def manifest() -> PanelManifest:
    return PanelManifest(
        name="session-status",
        description="Active workflow-management session info, in the sidebar.",
        mount_point=MOUNT_SIDEBAR,
        order=10,
    )


def render(ctx: PanelContext) -> None:
    st.markdown("### Session")
    sid = ctx.active_session_id
    if not sid:
        st.markdown(
            '<div class="empty-hint">No active session. '
            'Ensure `claude` CLI is on PATH and reload.</div>',
            unsafe_allow_html=True,
        )
        if st.button("retry spawn", key="session-respawn"):
            # Clear the cached runtime so boot_runtime re-runs.
            st.cache_resource.clear()
            st.rerun()
        return

    rec = ctx.session_manager.get(sid)
    if rec is None:
        st.markdown(
            '<div class="empty-hint">Session marker present but record missing.</div>',
            unsafe_allow_html=True,
        )
        return

    pill_class = _status_pill_class(rec.status)
    st.markdown(
        f'<div class="panel-card">'
        f'  <div class="title">{rec.display_name}</div>'
        f'  <div class="meta">id {rec.id[:8]} · type {rec.session_type}</div>'
        f'  <div style="margin-top:6px;"><span class="{pill_class}">{rec.status}</span></div>'
        f"</div>",
        unsafe_allow_html=True,
    )

    if rec.status == "archived":
        if st.button("re-spawn", key="session-respawn-archived"):
            st.cache_resource.clear()
            st.rerun()


def _status_pill_class(status: str) -> str:
    mapping = {
        "active": "status-pill status-pill-in_progress",
        "idle": "status-pill status-pill-ok",
        "archived": "status-pill status-pill-cancelled",
        "error": "status-pill status-pill-alert",
    }
    return mapping.get(status, "status-pill status-pill-pending")
