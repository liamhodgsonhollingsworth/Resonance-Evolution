"""Sidebar scene picker.

Lists every JSON file under ``scenes/`` and lets the maintainer switch
which scene is loaded into the shared engine. Switching reloads the
scene + reruns precompute; existing FileSource cache entries are
overwritten naturally.
"""

from __future__ import annotations

import streamlit as st

from tools.workflow_streamlit.panels._common import MOUNT_SIDEBAR, PanelContext, PanelManifest


def manifest() -> PanelManifest:
    return PanelManifest(
        name="scene-picker",
        description="Sidebar scene selector — choose which scene the engine renders.",
        mount_point=MOUNT_SIDEBAR,
        order=20,
    )


def render(ctx: PanelContext) -> None:
    st.markdown("### Scenes")
    scenes_dir = ctx.apeiron_root / "scenes"
    if not scenes_dir.exists():
        st.markdown('<div class="empty-hint">No scenes/ directory.</div>', unsafe_allow_html=True)
        return
    scenes = sorted(p.name for p in scenes_dir.glob("*.json"))
    if not scenes:
        st.markdown('<div class="empty-hint">No scenes found.</div>', unsafe_allow_html=True)
        return

    current = st.session_state.get("current_scene") or ctx.config.default_scene
    if current not in scenes:
        current = scenes[0]

    choice = st.selectbox(
        "scene",
        scenes,
        index=scenes.index(current),
        key="scene-picker-selectbox",
        label_visibility="collapsed",
    )
    if choice != current:
        st.session_state["current_scene"] = choice
        try:
            ctx.engine.load_scene(ctx.apeiron_root / "scenes" / choice)
            ctx.engine.precompute()
        except Exception as exc:
            st.error(f"scene load failed: {exc}")
            return
        st.rerun()
