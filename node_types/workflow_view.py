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
"""

from typing import List

from engine.node import EmitContext, Manifest, View


PANELS_MODE = "panels"
FULL_RENDER_MODE = "full_render"

PANEL_CONNECTIONS = ("panel_a", "panel_b", "panel_c", "panel_d", "panel_e")
BAR_CONNECTIONS = ("top_bar", "chat_bar")
FULL_RENDER_CONNECTION = "full_render"


def manifest() -> Manifest:
    return Manifest(
        name="WorkflowView",
        version="1.0",
        renderer_id="raster",
        inputs={"mode": "string"},
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Composite for the three-panel workflow surface. Children "
            "via panel_a/panel_b/panel_c (+optional panel_d/e), "
            "top_bar, chat_bar, and full_render. Mode field toggles "
            "between panels and full-render views."
        ),
    )


def build(params):
    return {
        "mode": str(params.get("mode", PANELS_MODE)),
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
