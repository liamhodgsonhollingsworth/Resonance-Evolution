"""ScrollBarNode — scroll-bar primitive (N-F023 / SPEC-090).

Brief 03 commit 3 of the Resonance website implementation arc — the
first of the three control primitives this commit ships (alongside
SliderNode + DropdownNode). The functional contract per the per-module
plan's N-F023 spec:

  - **Inputs (manifest):** ``min``, ``max``, ``value`` (float),
    ``orientation`` (enum ``vertical``/``horizontal``, default
    ``vertical``), ``connected_to`` (string — the text-box id whose
    scrolling this controls; commit 5 wires the interaction-rule),
    ``layer`` (int, SPEC-094), ``displayed_by`` (string — visual-variant
    binding per Decision A1).
  - **Outputs:** ``color``, ``depth`` (the visual variant's emit).
  - **Verbs (handle_action):** ``set_value(value)`` — clamps to
    ``[min, max]`` and persists; ``get_value`` — read-back.

Functional/visual split per Decision A1 + SPEC-090: scroll-bar is the
FUNCTIONAL node carrying state. Visual variants live as substrate-style
``kind: renderer`` nodes at:

  - ``Apeiron/renderers/presentations/scroll_bar_{minimal,chunky,thin}_v1.{md,py}``
    — raster variants.
  - ``Resonance-Website/renderers/presentations/scroll_bar_{minimal,chunky,thin}_v1.{md,py}``
    — HTML variants.

Each variant validates against this primitive's manifest schema (the
primitive_state input). The default raster ``emit()`` here is the
minimal-variant equivalent — adequate for headless tests + the
function/visual proof; richer rendering arrives via the variant
dispatch in subsequent commits.

Composition contract (per existing-primitives audit + mistake #009):

  - ``engine/screen.py`` — paste-onto-screen-rectangle (shared helper
    from brief 03 commit 1).
  - BoxNode geometry conventions (commit 2) — same world-space
    geometry + screen_width/height fields so all primitives compose
    against the same paste pipeline.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _paste_onto_screen_rectangle


DEFAULT_W_WORLD = 0.4
DEFAULT_H_WORLD = 2.0
DEFAULT_RESOLUTION_PX = 256
DEFAULT_LAYER = 0

# Orientation enum — vertical (height > width) or horizontal (width >
# height). The default raster auto-adapts the thumb track to the long
# axis.
ORIENTATIONS = ("vertical", "horizontal")


def manifest() -> Manifest:
    return Manifest(
        name="ScrollBarNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            # World-space geometry (shared convention with BoxNode).
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Functional state (the "function" half of A1).
            "min": "float",
            "max": "float",
            "value": "float",
            "orientation": "string",
            # Wiring to a target text-box (commit 5 interaction-rule).
            "connected_to": "string",
            # Z-order + visual-variant override.
            "layer": "int",
            "displayed_by": "string",
            # Colors (small defaults; visual variants can override via
            # primitive_state passthrough).
            "track_color": "vec3",
            "thumb_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Scroll-bar primitive (N-F023). Functional state lives here "
            "(min/max/value/orientation/connected_to); visual variants "
            "live as kind:renderer nodes naming presentation-of: "
            "ScrollBarNode (Decision A1)."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    track_color = params.get("track_color")
    if track_color is None:
        track_color = [0.20, 0.22, 0.28]
    thumb_color = params.get("thumb_color")
    if thumb_color is None:
        thumb_color = [0.55, 0.60, 0.70]

    orientation = str(params.get("orientation") or "vertical")
    if orientation not in ORIENTATIONS:
        orientation = "vertical"

    # Clamp value into [min, max] at build time so a misconfigured
    # spawn doesn't render outside the track.
    min_v = float(params.get("min") if params.get("min") is not None else 0.0)
    max_v = float(params.get("max") if params.get("max") is not None else 1.0)
    if max_v < min_v:
        # Defensive — swap rather than crash. Surfaces in describe()
        # so the LLM-driver notices the swap.
        min_v, max_v = max_v, min_v
    value = float(params.get("value") if params.get("value") is not None else min_v)
    value = max(min_v, min(max_v, value))

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "min": min_v,
        "max": max_v,
        "value": value,
        "orientation": orientation,
        "connected_to": str(params.get("connected_to") or ""),
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "displayed_by": str(params.get("displayed_by") or ""),
        "track_color": np.asarray(track_color, dtype=np.float32),
        "thumb_color": np.asarray(thumb_color, dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Scroll-bars have no rendered children — they're a primitive
    control surface. Any wired-to text-box is a SIBLING node, not a
    child."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render the track + thumb at the primitive's screen-rectangle.

    The default ``emit()`` is the minimal-variant equivalent — adequate
    when no ``displayed_by`` variant is set. Visual variants override
    by registering as ``kind: renderer`` substrate nodes the surface
    dispatches via the substrate's ``_execute_renderer`` handler.
    """
    screen_w_world = state["screen_width"]
    screen_h_world = state["screen_height"]
    res_max = state["screen_resolution"]

    aspect = screen_w_world / screen_h_world
    if aspect >= 1.0:
        screen_w_px = res_max
        screen_h_px = max(1, int(round(res_max / aspect)))
    else:
        screen_h_px = res_max
        screen_w_px = max(1, int(round(res_max * aspect)))

    internal = _render_scroll_bar_to_array(
        width=screen_w_px,
        height=screen_h_px,
        min_v=state["min"],
        max_v=state["max"],
        value=state["value"],
        orientation=state["orientation"],
        track_color=state["track_color"],
        thumb_color=state["thumb_color"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API (SPEC-061 enumeration contract,
    per per-module plan Cross-cut X6 + Scenario 10)."""
    min_v = state.get("min", 0.0)
    max_v = state.get("max", 1.0)
    value = state.get("value", min_v)
    orientation = state.get("orientation", "vertical")
    connected = state.get("connected_to") or "(unwired)"
    layer = state.get("layer", 0)
    displayed_by = state.get("displayed_by") or "(default)"
    return (
        f"ScrollBarNode id={ctx.node.id} "
        f"value={value:.3f} range=[{min_v:.2f}, {max_v:.2f}] "
        f"orientation={orientation!r} connected_to={connected} "
        f"layer={layer} displayed_by={displayed_by}"
    )


# ---------------------------------------------------------------------------
# Verb dispatch (set_value / get_value)
# ---------------------------------------------------------------------------
#
# Both verbs follow the engine.actions.dispatch_action shape: payload
# dict in, state-delta dict out. The delta includes a `last_<verb>`
# trace entry per the idea_queue convention so the text-API driver can
# enumerate recent verb invocations.


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "set_value":
        try:
            new_value = float(payload.get("value"))
        except (TypeError, ValueError):
            return {"last_set_value": {
                "set": False,
                "reason": "value must be a number",
            }}
        min_v = float(state.get("min", 0.0))
        max_v = float(state.get("max", 1.0))
        clamped = max(min_v, min(max_v, new_value))
        was_clamped = clamped != new_value
        state["value"] = clamped
        return {
            "value": clamped,
            "last_set_value": {
                "set": True,
                "value": clamped,
                "requested": new_value,
                "clamped": was_clamped,
            },
        }

    if action_name == "get_value":
        return {"value": state.get("value", 0.0),
                "last_get_value": {"value": state.get("value", 0.0)}}

    return None


# ---------------------------------------------------------------------------
# Internal: scroll-bar raster
# ---------------------------------------------------------------------------


def _render_scroll_bar_to_array(
    width: int,
    height: int,
    min_v: float,
    max_v: float,
    value: float,
    orientation: str,
    track_color: np.ndarray,
    thumb_color: np.ndarray,
) -> np.ndarray:
    """Render the track + thumb at the configured fractional position.

    The thumb sits at the fraction ``(value - min) / (max - min)`` along
    the long axis of the orientation. Empty range (min == max) draws a
    centered thumb so the primitive renders even in the degenerate case.
    """
    track_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in track_color)
    thumb_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in thumb_color)

    img = Image.new("RGB", (width, height), color=track_tuple)
    draw = ImageDraw.Draw(img)

    # Fractional position of the thumb along the long axis.
    span = max_v - min_v
    if span <= 0.0:
        fraction = 0.5
    else:
        fraction = (value - min_v) / span
        fraction = max(0.0, min(1.0, fraction))

    # Thumb is ~15% of the long-axis length.
    if orientation == "horizontal":
        thumb_w = max(2, int(round(width * 0.15)))
        thumb_h = max(2, int(round(height * 0.8)))
        max_thumb_x = max(0, width - thumb_w)
        thumb_x = int(round(fraction * max_thumb_x))
        thumb_y = (height - thumb_h) // 2
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )
    else:
        thumb_w = max(2, int(round(width * 0.8)))
        thumb_h = max(2, int(round(height * 0.15)))
        max_thumb_y = max(0, height - thumb_h)
        thumb_y = int(round(fraction * max_thumb_y))
        thumb_x = (width - thumb_w) // 2
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )

    return np.asarray(img, dtype=np.float32) / 255.0
