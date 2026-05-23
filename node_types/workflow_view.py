"""
WorkflowView — the maintainer's daily-workflow surface, composed of
panels and (optionally) a chat bar and top bar.

This is a composition node-type: no own emit(), the engine's default
compositor stacks the children via the Z-buffer. select_children
returns the visible children based on the current `mode`:

  - "panels"      — show the panel children (and chat bar, top bar)
  - "full_render" — show the full-render-mode child only (wishlist #010,
                    deferred — depends on the realtime renderer that
                    hasn't been built yet)

Children are named by connection key. Standard connections:

    panel_a, panel_b, panel_c — the three vertical panels
    chat_bar                  — bottom chat surface (any node-type)
    top_bar                   — top status surface (any node-type)
    full_render               — the dream-mode 3D scene root (deferred)

Per-connection translation transforms (in the scene JSON) position the
children side-by-side in the layout. The mode field is mutable runtime
state — toggling it from emit-time text commands switches the visible
children without re-spawning the scene.

The text-API surface: `describe()` walks the visible children and reports
which panels and bars are mounted. Future text commands `wv-mode panels`
and `wv-mode full_render` mutate the mode field.

Substrate mirror (brief 02 commit 1, 2026-05-22)
------------------------------------------------

Optionally mirrors a substrate-published workflow_view node (per the
Alethea-cc `kind: workflow_view` substrate primitive). When the node is
spawned with `substrate_view_name` (e.g., `workflow_view_main`) AND
`substrate_nodes_dir` (absolute path to the substrate's nodes store), the
`precompute_hook` resolves the latest substrate version via
`find({by: name, ...})` + `_walk_supersedes_chain` (forward-leaf), then
caches the parsed positions list at `engine.cache[node_id]`. Downstream
consumers (the brief 02 commit 2 continuous-scroll renderer-node + future
text-API readers) read the cached positions to render the append-only
timeline.

Substrate-mirror behavior is opt-in (no `substrate_view_name` ⇒ no
substrate access, cache stays empty, every pre-existing scene + test
unaffected) per the additive-extension convention. The pull is best-
effort: substrate-import errors leave `cache[node_id]["error"]` set and
positions empty rather than crashing precompute; the rest of the scene
renders regardless. This mirrors the FileSource graceful-degrade pattern.
"""

from pathlib import Path
from typing import Any, List, Optional

from engine.node import EmitContext, Manifest, View


PANELS_MODE = "panels"
FULL_RENDER_MODE = "full_render"

PANEL_CONNECTIONS = ("panel_a", "panel_b", "panel_c", "panel_d", "panel_e")
BAR_CONNECTIONS = ("top_bar", "chat_bar")
FULL_RENDER_CONNECTION = "full_render"


def manifest() -> Manifest:
    return Manifest(
        name="WorkflowView",
        version="1.1",
        renderer_id="raster",
        inputs={
            "mode": "string",
            "substrate_view_name": "string",
            "substrate_nodes_dir": "string",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Composite for the three-panel workflow surface. Children "
            "via panel_a/panel_b/panel_c (+optional panel_d/e), "
            "top_bar, chat_bar, and full_render. Mode field toggles "
            "between panels and full-render views. Optionally mirrors "
            "a substrate-published workflow_view node when "
            "substrate_view_name + substrate_nodes_dir are set."
        ),
    )


def build(params):
    return {
        "mode": str(params.get("mode", PANELS_MODE)),
        "substrate_view_name": str(params.get("substrate_view_name", "")),
        "substrate_nodes_dir": str(params.get("substrate_nodes_dir", "")),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    mode = state.get("mode", PANELS_MODE)
    available = set(node.connections.keys())
    if mode == FULL_RENDER_MODE:
        return [c for c in (FULL_RENDER_CONNECTION,) if c in available]
    # Default: panels mode — show every panel + bar connection that exists.
    visible = []
    for conn_name in PANEL_CONNECTIONS + BAR_CONNECTIONS:
        if conn_name in available:
            visible.append(conn_name)
    return visible


def describe(state, ctx: EmitContext) -> str:
    mode = state.get("mode", PANELS_MODE)
    node = ctx.node
    panels = [c for c in PANEL_CONNECTIONS if c in node.connections]
    bars = [c for c in BAR_CONNECTIONS if c in node.connections]
    full_render = FULL_RENDER_CONNECTION in node.connections
    parts = [f"WorkflowView(mode={mode!r})"]
    parts.append(f"  panels: {', '.join(panels) if panels else '(none)'}")
    parts.append(f"  bars:   {', '.join(bars) if bars else '(none)'}")
    parts.append(f"  full_render attached: {full_render}")
    return "\n".join(parts)


def set_mode(node, new_mode: str) -> None:
    """Mutate the mode field. Exposed for text-API command dispatch."""
    if new_mode not in (PANELS_MODE, FULL_RENDER_MODE):
        raise ValueError(
            f"WorkflowView.set_mode: unknown mode {new_mode!r}; "
            f"expected {PANELS_MODE!r} or {FULL_RENDER_MODE!r}"
        )
    node.state["mode"] = new_mode


# ---------------------------------------------------------------------------
# Substrate mirror (brief 02 commit 1)
# ---------------------------------------------------------------------------


def _empty_substrate_cache() -> dict:
    """The shape every precompute_hook return value conforms to.

    Even when substrate mirror is disabled (no substrate_view_name) the
    hook returns this shape, so downstream consumers can dispatch on
    cache presence without branching on substrate-mode."""
    return {
        "positions": [],
        "default_paste_location": "end",
        "metadata": {},
        "substrate_id": None,
        "substrate_view_name": "",
        "error": None,
    }


def _resolve_substrate_view(
    view_name: str, nodes_dir: Path
) -> tuple[Optional[dict], Optional[str]]:
    """Find the latest substrate workflow_view node by name.

    Returns (node_dict, error_message). Either the node + None or
    (None, error_string). Walks the supersession chain forward to the
    leaf so subsequent appends auto-follow the latest version (rather
    than caching a stale parent).
    """
    # Substrate primitives live in Alethea-cc/substrate/; importing them
    # lazily keeps Apeiron's start-time clean of substrate side-effects.
    # The path is configured via the substrate_nodes_dir param + the
    # substrate's own env-var pattern (SUBSTRATE_PROJECT_ROOT).
    try:
        from primitives import find, _walk_forward_supersedes  # type: ignore
    except ImportError:
        return None, (
            "WorkflowView.precompute_hook: Alethea-cc substrate primitives "
            "not importable. Add Alethea-cc/substrate to PYTHONPATH OR set "
            "substrate_nodes_dir to an importable location."
        )

    try:
        matches = find({"by": "name", "name": view_name}, nodes_dir=nodes_dir)
    except Exception as exc:
        return None, f"WorkflowView.precompute_hook: find failed: {exc}"

    if not matches:
        return None, (
            f"WorkflowView.precompute_hook: no substrate workflow_view "
            f"found with name {view_name!r} in {nodes_dir}"
        )

    # Pick the leaf of the supersession chain rooted at any match.
    # Bootstrap-grade: assume one root; the leaf walk surfaces branching
    # via a ValueError that we relay as the precompute_hook's error.
    leaf_candidate = matches[0]
    try:
        leaf_id = _walk_forward_supersedes(leaf_candidate["id"], nodes_dir)
    except ValueError as exc:
        return None, f"WorkflowView.precompute_hook: branched chain: {exc}"

    if leaf_id == leaf_candidate["id"]:
        return leaf_candidate, None

    # Re-resolve to the leaf node so the cache carries the latest body.
    try:
        leaf_matches = find({"by": "id", "id": leaf_id}, nodes_dir=nodes_dir)
    except Exception as exc:
        return None, f"WorkflowView.precompute_hook: leaf find failed: {exc}"
    if not leaf_matches:
        return None, (
            f"WorkflowView.precompute_hook: leaf id {leaf_id!r} not "
            f"reachable in {nodes_dir}"
        )
    return leaf_matches[0], None


def precompute_hook(state, engine, node) -> dict:
    """Mirror the substrate workflow_view into engine.cache[node_id].

    Opt-in: when state['substrate_view_name'] is empty (the default),
    returns the empty-cache shape immediately. Downstream consumers see
    `cache[node_id] == {"positions": [], ...}` and behave as if the
    substrate is empty — preserving backward compatibility with every
    pre-existing scene + test.

    When substrate_view_name is set:
      - Resolves the latest substrate node via find + forward-walk.
      - Validates the body shape (must carry a positions list, a
        default_paste_location, optional metadata).
      - Returns {positions, default_paste_location, metadata,
        substrate_id, substrate_view_name, error} for the engine to cache.

    Error-tolerant: substrate import failures, missing node, branched
    chains, malformed body — all return the cache shape with
    error=<reason> + positions=[]. The scene renders regardless; the
    error surfaces in the cache for downstream consumers to display.
    """
    out = _empty_substrate_cache()
    view_name = state.get("substrate_view_name") or ""
    if not view_name:
        return out

    out["substrate_view_name"] = view_name
    nodes_dir_str = state.get("substrate_nodes_dir") or ""
    if not nodes_dir_str:
        out["error"] = (
            "WorkflowView.precompute_hook: substrate_view_name is set but "
            "substrate_nodes_dir is empty; both are required."
        )
        return out

    nodes_dir = Path(nodes_dir_str)
    if not nodes_dir.exists():
        out["error"] = (
            f"WorkflowView.precompute_hook: substrate_nodes_dir does not "
            f"exist at {nodes_dir}"
        )
        return out

    leaf, error = _resolve_substrate_view(view_name, nodes_dir)
    if error is not None or leaf is None:
        out["error"] = error or "unknown substrate-resolution failure"
        return out

    body = leaf.get("body")
    if not isinstance(body, dict):
        out["error"] = (
            f"WorkflowView.precompute_hook: leaf body is not a dict "
            f"(got {type(body).__name__}); substrate node may be malformed."
        )
        return out

    positions = body.get("positions")
    if not isinstance(positions, list):
        out["error"] = (
            f"WorkflowView.precompute_hook: leaf body.positions is not a "
            f"list (got {type(positions).__name__})."
        )
        return out

    out["positions"] = list(positions)
    out["default_paste_location"] = body.get("default_paste_location", "end")
    out["metadata"] = dict(body.get("metadata") or {})
    out["substrate_id"] = leaf.get("id")
    return out
