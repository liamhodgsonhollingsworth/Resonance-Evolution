"""Right-sidebar idea queue (the "anything queue" the maintainer named).

A persistent queue with up / down / delete / add affordances. Every
button dispatches through the ``CommandRegistry`` so the equivalent
CLI command (``idea-queue.add "fix the oscillation"``) appears in the
terminal log on click — the GUI↔CLI 1:1 property.

Storage is a markdown checklist at
``state/workflow/idea_queue.md``; the handler in
``tools.workflow_streamlit.commands`` is the single source of truth.
"""

from __future__ import annotations

import streamlit as st

from tools.workflow_streamlit.commands import _load_idea_queue
from tools.workflow_streamlit.panels._common import (
    MOUNT_SIDEBAR,
    PanelContext,
    PanelManifest,
)


def manifest() -> PanelManifest:
    return PanelManifest(
        name="idea-queue",
        description="Sidebar drag-rearrangeable idea queue, persisted to disk.",
        mount_point=MOUNT_SIDEBAR,
        order=30,
    )


def render(ctx: PanelContext) -> None:
    registry = ctx.scratch.get("command_registry")
    if registry is None:
        st.warning("command registry missing; idea queue disabled")
        return

    st.markdown("### Ideas queue")

    cctx = ctx.as_command_context()
    items = _load_idea_queue(cctx)

    # Add box.
    new_text = st.text_input(
        "add an idea",
        key="idea-queue-add",
        placeholder="add…",
        label_visibility="collapsed",
    )
    if st.button("add", key="idea-queue-add-btn") and new_text.strip():
        registry.run_gui("idea-queue.add", cctx, new_text.strip())
        try:
            del st.session_state["idea-queue-add"]
        except KeyError:
            pass
        st.rerun()

    if not items:
        st.markdown('<div class="empty-hint">queue is empty.</div>', unsafe_allow_html=True)
        return

    for idx, text in enumerate(list(items)):
        cols = st.columns([0.65, 0.1, 0.1, 0.15])
        with cols[0]:
            st.markdown(f"- {text}")
        with cols[1]:
            if st.button("↑", key=f"iq-up-{idx}", disabled=(idx == 0)):
                registry.run_gui("idea-queue.up", cctx, str(idx))
                st.rerun()
        with cols[2]:
            if st.button("↓", key=f"iq-down-{idx}", disabled=(idx == len(items) - 1)):
                registry.run_gui("idea-queue.down", cctx, str(idx))
                st.rerun()
        with cols[3]:
            if st.button("✕", key=f"iq-del-{idx}"):
                registry.run_gui("idea-queue.delete", cctx, str(idx))
                st.rerun()
