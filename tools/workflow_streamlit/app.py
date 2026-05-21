"""Streamlit driver — discovers panels, drains CLI queue, renders the page.

Two layout changes vs the v1 driver:

1. **Targeted refresh, no full-page autorefresh.** The full-page
   ``st_autorefresh`` caused the screen to grey out every two seconds
   while the entire Python script re-executed. v2 wraps each refresh-
   sensitive panel in ``@st.fragment(run_every=...)``. Only that
   fragment re-runs on the timer; the rest of the page stays calm.

2. **CLI bridge drain.** Each refresh of the terminal panel drains
   ``state/workflow/cli_command_queue.txt`` so commands written by
   other processes (the ``cli`` entry point, future scheduled jobs)
   execute as if typed by the maintainer.

The driver is thin: it discovers panels, ensures a shared
``CommandContext`` is built, then renders gate → sidebar → main →
bottom in order. Panels do the real work.
"""

from __future__ import annotations

import sys
from pathlib import Path

# Allow `streamlit run tools/workflow_streamlit/app.py` from the Apeiron repo
# root without needing the project to be pip-installed first.
_REPO_ROOT = Path(__file__).resolve().parents[2]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

import streamlit as st

from tools.workflow_streamlit import style
from tools.workflow_streamlit.cli_bridge import drain
from tools.workflow_streamlit.command_registry import CommandContext
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

    ctx = _build_context(runtime, cfg)

    # Drain any queued CLI commands BEFORE rendering anything else so
    # state changes the queue produced are visible to all panels in
    # this rerun (e.g. an idea-queue.add typed from the CLI shows up
    # in the sidebar right away).
    _drain_cli_queue(ctx, runtime, cfg)

    panels = discover_panels()

    # 1. Gate (auth) — can short-circuit.
    for p in panels_for_mount(panels, MOUNT_GATE):
        p.render(ctx)
    if ctx.scratch.get("gate") == "block":
        return

    # 2. Sidebar — refresh slowly (every 10s) so reordering / typing
    #    feels stable, the page doesn't grey out, and inbox-driven
    #    side effects still surface within a few seconds.
    with st.sidebar:
        st.markdown("# Apeiron")
        st.caption(f"mode · {cfg.deployment_mode}")
        _render_sidebar_fragment(ctx, panels)

    # 3. Main — same refresh cadence as sidebar.
    _render_main_fragment(ctx, panels)

    # 4. Bottom — chat refreshes faster (2s) for liveness; the terminal
    #    log fragment also lives here and refreshes alongside.
    st.markdown("---")
    _render_bottom_fragment(ctx, panels)


def _build_context(runtime, cfg) -> PanelContext:
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
    # Make the registry available to every panel via the same scratch
    # the terminal reads. Storing it on scratch keeps PanelContext's
    # type stable.
    ctx.scratch["command_registry"] = runtime.command_registry
    return ctx


def _drain_cli_queue(ctx: PanelContext, runtime, cfg) -> None:
    """Pull any pending commands from the external CLI bridge."""
    if runtime.command_registry is None:
        return
    cctx = CommandContext(
        engine=ctx.engine,
        session_manager=ctx.session_manager,
        inbox=ctx.inbox,
        file_watcher=ctx.file_watcher,
        config=ctx.config,
        apeiron_root=ctx.apeiron_root,
        active_session_id=ctx.active_session_id,
        user=ctx.user,
        scratch=ctx.scratch,
    )
    drain(cfg.state_dir, runtime.command_registry, cctx)


@st.fragment(run_every="10s")
def _render_sidebar_fragment(ctx: PanelContext, panels):
    # Precompute fresh items so FileSource-backed sidebar panels reflect
    # disk edits within the fragment cadence.
    try:
        ctx.engine.precompute()
    except Exception:
        pass
    for p in panels_for_mount(panels, MOUNT_SIDEBAR):
        p.render(ctx)
        st.markdown("---")


@st.fragment(run_every="10s")
def _render_main_fragment(ctx: PanelContext, panels):
    try:
        ctx.engine.precompute()
    except Exception:
        pass
    for p in panels_for_mount(panels, MOUNT_MAIN):
        p.render(ctx)


@st.fragment(run_every="2s")
def _render_bottom_fragment(ctx: PanelContext, panels):
    # Drain queued CLI commands again at the fast cadence so an
    # injected command surfaces in the terminal within ~2 seconds.
    runtime_registry = ctx.scratch.get("command_registry")
    if runtime_registry is not None:
        cctx = CommandContext(
            engine=ctx.engine,
            session_manager=ctx.session_manager,
            inbox=ctx.inbox,
            file_watcher=ctx.file_watcher,
            config=ctx.config,
            apeiron_root=ctx.apeiron_root,
            active_session_id=ctx.active_session_id,
            user=ctx.user,
            scratch=ctx.scratch,
        )
        drain(ctx.config.state_dir, runtime_registry, cctx)
    for p in panels_for_mount(panels, MOUNT_BOTTOM):
        p.render(ctx)


main()
