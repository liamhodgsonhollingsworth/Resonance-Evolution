"""Right-sidebar idea queue (the "anything queue" the maintainer named).

A persistent drag-droppable list. Items live on disk at
``state/workflow/idea_queue.md`` so they survive process restarts and
are visible to other surfaces (the file can be read by Apeiron sessions
or watched by other tools).

Streamlit's native widget set doesn't include true drag-and-drop, so
v1 ships with explicit up / down / delete buttons per row plus an
input to add. v2 can swap in ``streamlit-sortables`` (already a
permissive dep) without changing the storage format — the data shape
is just a markdown checklist.
"""

from __future__ import annotations

from typing import List

import streamlit as st

from tools.workflow_streamlit.panels._common import MOUNT_SIDEBAR, PanelContext, PanelManifest


def manifest() -> PanelManifest:
    return PanelManifest(
        name="idea-queue",
        description="Sidebar drag-rearrangeable idea queue, persisted to disk.",
        mount_point=MOUNT_SIDEBAR,
        order=30,
    )


def render(ctx: PanelContext) -> None:
    st.markdown("### Ideas queue")
    path = ctx.config.state_dir / "idea_queue.md"
    items = _load(path)

    # Add box.
    new_text = st.text_input(
        "add an idea",
        key="idea-queue-add",
        placeholder="add…",
        label_visibility="collapsed",
    )
    if st.button("add", key="idea-queue-add-btn") and new_text.strip():
        items.append(new_text.strip())
        _save(path, items)
        st.session_state["idea-queue-add"] = ""
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
                items[idx - 1], items[idx] = items[idx], items[idx - 1]
                _save(path, items)
                st.rerun()
        with cols[2]:
            if st.button("↓", key=f"iq-down-{idx}", disabled=(idx == len(items) - 1)):
                items[idx + 1], items[idx] = items[idx], items[idx + 1]
                _save(path, items)
                st.rerun()
        with cols[3]:
            if st.button("✕", key=f"iq-del-{idx}"):
                del items[idx]
                _save(path, items)
                st.rerun()


def _load(path) -> List[str]:
    if not path.exists():
        return []
    try:
        out: List[str] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("- "):
                out.append(line[2:].strip())
        return out
    except Exception:
        return []


def _save(path, items: List[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "# Idea queue\n\n" + "\n".join(f"- {it}" for it in items) + "\n"
    path.write_text(body, encoding="utf-8")
