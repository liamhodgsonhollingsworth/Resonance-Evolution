"""Streamlit driver — discovers panels and renders the page each rerun.

Thin by design. The driver does five things:

1. Resolves runtime config from env (``config.load_config``).
2. Fetches the cached runtime — engine, session manager, inbox, file
   watcher — boot-on-first-rerun via ``runtime.get_runtime``.
3. Discovers panels under ``panels/`` (registry).
4. Runs the gate panel(s) first; if any sets ``ctx.scratch['gate']``
   to ``"block"``, halts before rendering the main surface.
5. Renders sidebar → main → bottom in that order, each panel inside
   its declared container.

Everything else is in panels. To add a new surface, drop
``panels/<name>.py`` with ``manifest()`` + ``render(ctx)``; the next
Streamlit autoreload picks it up — no edit to this file required.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Allow `streamlit run tools/workflow_streamlit/app.py` from the Apeiron repo
# root without needing the project to be pip-installed first. The repo root
# is two levels up from this file (tools/workflow_streamlit/app.py).
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import streamlit as st
from streamlit_autorefresh import st_autorefresh

from tools.workflow_streamlit import style
from tools.workflow_streamlit.config import load_config
from tools.workflow_streamlit.panels._common import (
    MOUNT_BOTTOM,
    MOUNT_GATE,
    MOUNT_MAIN,
    MOUNT_SIDEBAR,
    PanelContext,
)
from tools.workflow_streamlit.registry import discover_panels, panels_for_mount
from tools.workflow_streamlit.runtime import get_runtime


def main() -> None:
    st.set_page_config(
        page_title="Apeiron",
        page_icon="◈",
        layout="wide",
        initial_sidebar_state="expanded",
    )
    style.inject(st)

    cfg = load_config(apeiron_root=_REPO_ROOT)
    runtime = get_runtime(cfg)

    # Autorefresh every 2s so newly-arrived inbox messages and updated
    # FileSource caches surface without manual reload. The interval is
    # short because the engine.precompute call below is cheap.
    st_autorefresh(interval=2000, key="apeiron-autorefresh")

    # Re-precompute on each refresh tick so FileSource items mirror disk.
    try:
        runtime.engine.precompute()
    except Exception:
        pass

    ctx = PanelContext(
        engine=runtime.engine,
        session_manager=runtime.session_manager,
        inbox=runtime.inbox,
        file_watcher=runtime.file_watcher,
        config=cfg,
        apeiron_root=cfg.apeiron_root,
        user=None,
        active_session_id=runtime.default_session_id,
    )

    panels = discover_panels()

    # 1. Gate panels first — they can short-circuit the page.
    for p in panels_for_mount(panels, MOUNT_GATE):
        p.render(ctx)
    if ctx.scratch.get("gate") == "block":
        return  # auth panel rendered the login form and called st.stop indirectly

    # 2. Sidebar.
    with st.sidebar:
        st.markdown("# Apeiron")
        st.caption(f"mode · {cfg.deployment_mode}")
        for p in panels_for_mount(panels, MOUNT_SIDEBAR):
            p.render(ctx)
            st.markdown("---")

    # 3. Main surface.
    for p in panels_for_mount(panels, MOUNT_MAIN):
        p.render(ctx)

    # 4. Bottom-of-page chat.
    st.markdown("---")
    for p in panels_for_mount(panels, MOUNT_BOTTOM):
        p.render(ctx)


main()
