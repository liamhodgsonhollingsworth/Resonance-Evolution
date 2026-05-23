"""Workflow continuous-scroll panel — the MOUNT_MAIN surface.

Per brief 02 commit 2 (Decision B1, SPEC-086 + SPEC-082).

This panel renders the maintainer's workflow_view substrate node as a
continuous-scroll surface with a sliding window (50 visible + 20 buffer-
above + 20 buffer-below by default). It replaces the placeholder
MOUNT_MAIN content with the planned workflow timeline.

The panel:
  1. Resolves the workflow_view substrate node via the WorkflowView
     composition node's `engine.cache[node_id]` mirror (the
     `precompute_hook` extension landed in brief 02 commit 1; opt-in via
     `substrate_view_name` + `substrate_nodes_dir` scene params).
  2. Builds the `content_nodes` list (workflow_view first, then any
     pre-fetched content nodes).
  3. Calls `workflow_continuous_scroll_v1.render({...})` to produce the
     HTML fragment.
  4. Wraps the fragment in `st.markdown(html, unsafe_allow_html=True)`.

Per the existing-primitives audit (mistake #009 recurrence-4 guard):
  - The substrate mirror lives in `engine.cache` per the existing
    `precompute_hook` pattern (no new state machinery).
  - The panel discovery + scene-override path uses the existing
    `discover_panels_with_engine_overrides` (no parallel registry).
  - The `StreamlitPanel` scene-declaration node-type wires the panel in
    via `scenes/workflow_view.json` (no new declaration mechanism).

Layout decisions explicitly deferred to later commits (per the per-
module plan):
  - Append-only render-layer enforcement (commit 3 — `freeze_at_append_time`).
  - Paste-dispatch primitive + paste.add CLI verb (commit 4).
  - Notion-as-source pipe (commit 5).
  - Streamlit-to-domain port nodes (commit 6).
  - Literal-domain renderer impl (commit 7).
  - Polished visual treatment via Claude-Design (separate workflow).
"""
from __future__ import annotations

from typing import Any, Dict, List, Optional

import streamlit as st

from tools.workflow_streamlit.panels._common import (
    MOUNT_MAIN,
    PanelContext,
    PanelManifest,
)
from tools.workflow_streamlit.renderers.workflow_continuous_scroll_v1 import (
    render as render_continuous_scroll,
)


PANEL_NAME = "workflow-continuous-scroll"
PANEL_DESCRIPTION = (
    "Continuous-scroll workflow timeline with sliding-window rendering."
)

# Defaults — overridable via the scene's StreamlitPanel params (mount_point,
# order) per the existing override path in `registry.discover_panels_with_
# engine_overrides`. Order 5 puts the continuous-scroll surface BEFORE the
# chat panel (order 10) in MOUNT_MAIN; the chat surface stays as the
# bottom-most main entry per the existing scene.
DEFAULT_ORDER = 5

# The WorkflowView composition node id the precompute_hook caches under.
# The scene's WorkflowView node has id `workflow_view` (per
# scenes/workflow_view.json line 12); the substrate mirror lands in
# `engine.cache["workflow_view"]`. Override at scene-load time by
# parameterising the WorkflowView node's id.
DEFAULT_WORKFLOW_VIEW_CACHE_KEY = "workflow_view"


def manifest() -> PanelManifest:
    return PanelManifest(
        name=PANEL_NAME,
        description=PANEL_DESCRIPTION,
        mount_point=MOUNT_MAIN,
        order=DEFAULT_ORDER,
        requires_auth=True,
        hidden=False,
    )


def render(ctx: PanelContext) -> None:
    """Render the continuous-scroll workflow surface.

    Best-effort: if the substrate-mirror is not configured (no
    `substrate_view_name` on the WorkflowView node), shows a friendly
    diagnostic explaining how to wire it. If the mirror is configured but
    surfaces an error (missing nodes_dir, malformed body), surfaces the
    error inline so the maintainer can fix the scene.

    The fragment refresh cadence is determined by the driver's
    `@st.fragment(run_every=...)` wrapper — the panel itself is
    side-effect-free aside from the markdown emission.
    """
    st.markdown("## Workflow timeline")

    cache_entry = _resolve_workflow_view_cache(ctx)
    if cache_entry is None:
        _render_unconfigured_hint()
        return

    error = cache_entry.get("error")
    if error:
        st.warning(f"Workflow surface not available: {error}")
        st.caption(
            "Configure substrate_view_name + substrate_nodes_dir on the "
            "WorkflowView scene node to enable the continuous-scroll surface."
        )
        return

    substrate_id = cache_entry.get("substrate_id")
    positions = cache_entry.get("positions") or []
    default_paste_location = cache_entry.get("default_paste_location", "end")
    metadata = cache_entry.get("metadata") or {}

    # Build a synthetic workflow_view node dict matching the shape
    # `_extract_workflow_view` expects. We don't re-load the substrate
    # file here — the cache holds everything render() needs.
    workflow_view_node: Dict[str, Any] = {
        "id": substrate_id or "",
        "name": cache_entry.get("substrate_view_name", "workflow_view_main"),
        "kind": "workflow_view",
        "body-format": "workflow-view",
        "body": {
            "positions": positions,
            "default_paste_location": default_paste_location,
            "metadata": metadata,
        },
    }

    content_nodes: List[dict] = [workflow_view_node]
    nodes_lookup = _prefetch_content_nodes(ctx, positions)

    # Streamlit doesn't expose viewport height directly; pick a sensible
    # default for the fragment's sliding-window computation. Caller can
    # override via URL `?window=...` (the renderer accepts the override
    # via context['window']).
    viewport_height = 800

    fragment_html = render_continuous_scroll(
        {
            "content_nodes": content_nodes,
            "context": {
                "viewport_height": viewport_height,
                "nodes_lookup": nodes_lookup,
            },
        }
    )

    st.markdown(fragment_html, unsafe_allow_html=True)

    # Compact status line for the maintainer.
    rendered_count = (
        sum(
            1
            for entry in positions
            if isinstance(entry, dict) and isinstance(entry.get("node_id"), str)
        )
    )
    st.caption(
        f"Workflow surface · {rendered_count} entries · "
        f"window {metadata.get('window', '50,20,20')} · "
        f"default-paste-location: {default_paste_location}"
    )


# ---------------------------------------------------------------------------
# Substrate-cache resolution
# ---------------------------------------------------------------------------


def _resolve_workflow_view_cache(ctx: PanelContext) -> Optional[Dict[str, Any]]:
    """Find the WorkflowView composition node's cache entry.

    Walks `ctx.engine.nodes` for a WorkflowView instance and returns
    `ctx.engine.cache[node_id]` (the precompute_hook's output). Returns
    None if no WorkflowView node is in the scene — the panel should
    short-circuit with a diagnostic.

    Multiple WorkflowView nodes are tolerated; the first one found in
    iteration order wins. The scene's canonical declaration uses id
    `workflow_view` per scenes/workflow_view.json.
    """
    engine = getattr(ctx, "engine", None)
    if engine is None:
        return None
    cache = getattr(engine, "cache", None) or {}
    nodes = getattr(engine, "nodes", None) or {}

    # Prefer the canonical cache key when present.
    if DEFAULT_WORKFLOW_VIEW_CACHE_KEY in cache:
        candidate = cache[DEFAULT_WORKFLOW_VIEW_CACHE_KEY]
        if isinstance(candidate, dict) and "positions" in candidate:
            return candidate

    for node_id, instance in nodes.items():
        if getattr(instance, "type_name", None) != "WorkflowView":
            continue
        candidate = cache.get(node_id)
        if isinstance(candidate, dict) and "positions" in candidate:
            return candidate
    return None


def _render_unconfigured_hint() -> None:
    st.info(
        "No WorkflowView substrate mirror found. The continuous-scroll "
        "surface needs a WorkflowView scene node with `substrate_view_name` "
        "set (typically `workflow_view_main`) and `substrate_nodes_dir` "
        "pointing at the Alethea-cc substrate's nodes/ directory."
    )
    st.caption(
        "Scene template: `{\"id\": \"workflow_view\", \"type\": \"WorkflowView\", "
        '"params": {"mode": "panels", "substrate_view_name": "workflow_view_main", '
        '"substrate_nodes_dir": "<abs-path>"}}`'
    )


# ---------------------------------------------------------------------------
# Content-node pre-fetching
# ---------------------------------------------------------------------------


def _prefetch_content_nodes(
    ctx: PanelContext, positions: List[dict]
) -> Dict[str, dict]:
    """Best-effort content-node pre-fetch.

    Brief 02 commit 2 ships the SHELL: returns an empty lookup so the
    renderer renders placeholder boxes for every entry (the JS layer in
    commit 4+ wires up the lazy-load fetch). The hook is in place so
    later commits can populate the lookup without changing the panel
    contract.

    A future commit may pre-fetch bodies via the substrate `find({by:
    id, ...})` path (composes against the existing primitive); for
    commit 2 we keep the panel side-effect-light and lean on the
    placeholder rendering.
    """
    # Validate the positions shape (defensive — the precompute_hook
    # already validates, but a defensive check here keeps the panel
    # robust against future cache-shape drift).
    if not isinstance(positions, list):
        return {}
    return {}
