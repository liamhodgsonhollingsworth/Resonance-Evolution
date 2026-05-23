"""BarNode — BoxNode subkind specialized to top/bottom/side bars
(N-F014, SPEC-112).

Brief 04 commit 2 of the Resonance website implementation arc. BarNode
is the functional primitive for the maintainer's verbatim:

    "creating a top bar or bottom bar with rounded corners that I can
     stick onto any given rectangle, and that bar will have some text
     as well as be a place where I can add little buttons, sliders, or
     anything related to the main node."  (N-F014)

A BarNode IS a BoxNode in composition: identical geometry contract,
identical lock-state delegation, identical visual-variant slot. The
specialization is purely default-shape: corner_radius default `0.15`
(yielding rounded corners suitable for sticking onto a parent
rectangle), plus a per-variant orientation default that determines
which dimension the bar fills.

Per the per-module plan's Decision A5 + SPEC-108 cross-cut: BarNode
ships with FOUR variants:

  - TopBarNode + BottomBarNode — horizontal bars (width follows
    parent.width via the layer-3 surface composition; height defaults
    to a fraction of parent.height).
  - LeftSidebarNode + RightSidebarNode — vertical bars (height follows
    parent.height; width defaults to a fraction of parent.width).

Each variant is a tiny manifest declaring an ``anchor_default`` field
the substrate's `interaction-rule:bar-onto-rectangle` rule reads to
populate the attachment's anchor. The actual stick-together attachment
node is published by `create_attachment_action.md` in the Alethea
substrate; the primitives ship only the renderable kind.

Composition contract (per mistake #009 + existing-primitives audit):

  - ``node_types/box.py`` — geometry + paste-onto-screen +
    layer/drop-policy. BarNode IS a BoxNode in the engine; the
    Engine discovers BarNode separately so the kind is identifiable
    to interaction-rules + visual variants, but the emit + build
    delegate to box.py.
  - ``node_types/toolbox.py`` — child-container for the bar's text +
    sub-controls. A bar's ``contents`` slot (held in a paired toolbox
    instance the substrate's attachment-aware renderer reads) is what
    holds the *"little buttons, sliders, or anything related to the
    main node"* the maintainer named in N-F014.
  - ``engine/screen.py`` — `_paste_onto_screen_rectangle` (shared).

Visual-variant slot per Decision A1: BarNode is the functional kind;
the visual variants `bar_minimal_v1`, `bar_chunky_v1`,
`bar_painterly_v1` live at
``Resonance-Website/renderers/presentations/bar_*_v1.{md,py}`` and are
selected via the ``displayed_by:`` field (forward-compat — phase-1
ships only the BoxNode default raster).

Per SPEC-112: the four variants (Top/Bottom/Left/Right) are distinct
kinds (not parameter-only variations) so the interaction-rule
infrastructure can match on `source_kind: TopBarNode` etc., and the
attachment's anchor field defaults sensibly from the kind alone.
"""

from __future__ import annotations

from typing import Any, Dict, List

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View

# Compose against BoxNode for all geometry + raster + lock delegation.
# Re-exporting BoxNode's emit/build/select_children/describe through
# this module gives every BarNode variant the same surface without
# duplicating geometry logic — mistake #009 honor.
from node_types import box as _box_module


# ---------------------------------------------------------------------------
# Default geometry — biased for bar-shaped rectangles
# ---------------------------------------------------------------------------
#
# Horizontal bars: wide + short. Vertical bars: tall + narrow. Defaults
# expressed in the same world-space units BoxNode uses (matching
# ListRenderer's screen_width / screen_height convention). The shapes
# are chosen so a bar instantiated with empty params is visibly bar-
# shaped without further configuration.

# Corner radius as a fraction of the smaller dimension (matches BoxNode's
# convention — see _render_box_to_array). 0.15 gives gently rounded
# corners suitable for sticking onto a parent rectangle without
# competing visually.
BAR_CORNER_RADIUS = 0.15

# Horizontal bars: 2x default-box-width by 0.3x default-box-height.
HORIZONTAL_W_WORLD = _box_module.DEFAULT_W_WORLD * 2.0
HORIZONTAL_H_WORLD = _box_module.DEFAULT_H_WORLD * 0.3

# Vertical bars: swap the proportions.
VERTICAL_W_WORLD = _box_module.DEFAULT_W_WORLD * 0.3
VERTICAL_H_WORLD = _box_module.DEFAULT_H_WORLD * 2.0


# ---------------------------------------------------------------------------
# Variant registry — orientation + anchor-default per kind
# ---------------------------------------------------------------------------

VARIANT_REGISTRY: dict[str, dict[str, Any]] = {
    "BarNode": {
        # Base kind — defaults to horizontal (matches the maintainer's
        # verbatim "top bar or bottom bar" framing as the canonical
        # example). Callers wanting a different orientation use a
        # specific variant.
        "orientation": "horizontal",
        "anchor_default": "top",
        "default_w_world": HORIZONTAL_W_WORLD,
        "default_h_world": HORIZONTAL_H_WORLD,
    },
    "TopBarNode": {
        "orientation": "horizontal",
        "anchor_default": "top",
        "default_w_world": HORIZONTAL_W_WORLD,
        "default_h_world": HORIZONTAL_H_WORLD,
    },
    "BottomBarNode": {
        "orientation": "horizontal",
        "anchor_default": "bottom",
        "default_w_world": HORIZONTAL_W_WORLD,
        "default_h_world": HORIZONTAL_H_WORLD,
    },
    "LeftSidebarNode": {
        "orientation": "vertical",
        "anchor_default": "left",
        "default_w_world": VERTICAL_W_WORLD,
        "default_h_world": VERTICAL_H_WORLD,
    },
    "RightSidebarNode": {
        "orientation": "vertical",
        "anchor_default": "right",
        "default_w_world": VERTICAL_W_WORLD,
        "default_h_world": VERTICAL_H_WORLD,
    },
}


# ---------------------------------------------------------------------------
# Manifest — exposes BoxNode's inputs + adds bar-specific fields
# ---------------------------------------------------------------------------


def _make_manifest(kind_name: str) -> Manifest:
    """Build a manifest for a bar variant.

    Inherits every BoxNode input, then adds the two bar-specific fields:

      - ``orientation`` — string enum (``horizontal`` | ``vertical``).
        Phase-1 informs the default geometry; phase-2 visual variants
        may read it for orientation-aware rendering.
      - ``anchor_default`` — string enum (one of the attachment-spec
        anchor values). The interaction-rule
        `bar-onto-rectangle → create-attachment` reads this field to
        populate the new attachment's anchor when the bar is dragged
        onto a parent rectangle.
    """
    box_inputs = dict(_box_module.manifest().inputs)
    box_inputs["orientation"] = "string"
    box_inputs["anchor_default"] = "string"
    variant = VARIANT_REGISTRY[kind_name]
    return Manifest(
        name=kind_name,
        version="1.0",
        renderer_id="raster",
        inputs=box_inputs,
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            f"{kind_name} — BoxNode subkind specialized to a "
            f"{variant['orientation']} bar with rounded corners (N-F014). "
            f"Drag onto a BoxNode to create a stick-together attachment "
            f"(SPEC-108); the attachment's anchor defaults to "
            f"{variant['anchor_default']!r}. Holds an optional ToolboxNode "
            f"of text + sub-controls per N-F014."
        ),
    )


def manifest() -> Manifest:
    """Module-level entry point — Engine.discover() uses this for the
    base BarNode kind.

    Each variant module re-imports `manifest` from this module under its
    own name; see top_bar.py / bottom_bar.py / left_sidebar.py /
    right_sidebar.py.
    """
    return _make_manifest("BarNode")


# ---------------------------------------------------------------------------
# build — composes BoxNode's build + adds the two bar-specific fields
# ---------------------------------------------------------------------------


def _build_with_kind(kind_name: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """Build a bar variant's state.

    Defaults to the variant's documented geometry + orientation +
    anchor; explicit params override. The base BoxNode fields all carry
    forward via composition — corner_radius defaults to BAR_CORNER_RADIUS
    instead of 0 (the bar visual identity) but everything else mirrors
    BoxNode exactly.
    """
    variant = VARIANT_REGISTRY[kind_name]
    # Apply bar-specific defaults before delegating to BoxNode.build.
    # The maintainer's bar instances should look bar-shaped without
    # having to specify geometry manually.
    enriched = dict(params)
    enriched.setdefault("screen_width", variant["default_w_world"])
    enriched.setdefault("screen_height", variant["default_h_world"])
    enriched.setdefault("corner_radius", BAR_CORNER_RADIUS)
    # BoxNode validates + canonicalizes everything else (fill_color,
    # border_color, layer, accept_unknown_drop, displayed_by, etc.).
    state = _box_module.build(enriched)
    # Layer on the two bar-specific fields.
    state["orientation"] = str(params.get("orientation") or variant["orientation"])
    state["anchor_default"] = str(
        params.get("anchor_default") or variant["anchor_default"]
    )
    return state


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    """Base BarNode build — delegates with the base-kind defaults."""
    return _build_with_kind("BarNode", params)


# ---------------------------------------------------------------------------
# select_children + emit + describe — delegate to BoxNode
# ---------------------------------------------------------------------------


def select_children(state, view: View, engine, node) -> List[str]:
    """Bars compose against ToolboxNode for their contents via
    attachment — engine-level children stay empty (matches BoxNode +
    ToolboxNode phase-1 conventions)."""
    return _box_module.select_children(state, view, engine, node)


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Phase-1 emit — render as a rounded BoxNode.

    Per Decision A1, when ``state['displayed_by']`` is non-empty the
    substrate's presentation-spec dispatch takes over (bar_minimal_v1 /
    bar_chunky_v1 / bar_painterly_v1 in commit 3+). The default emit
    here uses BoxNode's rendering directly so a bar instance is
    visible in isolation without a visual variant being authored.
    """
    return _box_module.emit(state, view, ctx)


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API (SPEC-061 enumeration
    contract).

    Mirrors BoxNode.describe but with the kind name + orientation +
    anchor_default surfaced so the LLM-driver can identify the bar
    variant + know which anchor the next bar-onto-rectangle drag would
    default to without inspecting the manifest.
    """
    kind_name = (
        getattr(ctx.node, "type_name", None)
        or getattr(ctx.node, "kind", None)
        or "BarNode"
    )
    w = state.get("screen_width", 0)
    h = state.get("screen_height", 0)
    r = state.get("corner_radius", 0)
    anchor = state.get("anchor_default", "top")
    orientation = state.get("orientation", "horizontal")
    return (
        f"{kind_name} id={ctx.node.id} size={w:.2f}x{h:.2f} "
        f"corner_radius={r:.2f} orientation={orientation!r} "
        f"anchor_default={anchor!r}"
    )


# Re-export BoxNode's lock-state helper so callers can use the same
# `is_locked(bar_id, lock_registry)` API across BoxNode / BarNode.
is_locked = _box_module.is_locked
