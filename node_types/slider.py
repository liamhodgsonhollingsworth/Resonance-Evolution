"""SliderNode — slider primitive (N-F025 / SPEC-090).

Brief 03 commit 3 of the Resonance website implementation arc — the
second of the three control primitives this commit ships. The
functional contract per the per-module plan's N-F025 spec:

  - **Inputs (manifest):** ``min``, ``max``, ``value``, ``step``
    (float; step default 0.01), ``parameter_target`` (string — a
    ``<node_id>.<field>`` reference for the parameter this slider
    drives; wired via LinkNode in commit 5), ``orientation`` (enum
    ``horizontal``/``vertical``, default ``horizontal``), ``layer``
    (int, SPEC-094), ``displayed_by`` (string — visual-variant binding
    per Decision A1).
  - **Outputs:** ``color``, ``depth`` (the visual variant's emit).
  - **Verbs (handle_action):** ``set_value(value)`` — clamps to
    ``[min, max]`` and snaps to nearest ``step`` multiple; ``get_value``
    — read-back; ``step_up`` / ``step_down`` — increment / decrement
    by ``step``.

Functional/visual split per Decision A1: visual variants live as
substrate-style ``kind: renderer`` nodes naming ``presentation-of:
SliderNode``. The shared minimal-variant rendering is the default
``emit()`` here.

The ``parameter_target`` field is a string-shaped contract (per the
per-module plan N-F025 ``Risk + mitigation``): the LinkNode primitive
(commit 5) resolves the target by node-id (content-addressed) so
renames don't break wirings. Phase-1 (this commit) just persists the
field; commit 5 implements the runtime resolution.

Composition contract:

  - ``engine/screen.py`` — paste-onto-screen-rectangle (brief 03
    commit 1).
  - BoxNode geometry conventions (commit 2).
  - ScrollBarNode (commit 3) — shares the track + thumb rendering
    shape; phase-1 sliders use a thinner track to differentiate.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _paste_onto_screen_rectangle


DEFAULT_W_WORLD = 2.0
DEFAULT_H_WORLD = 0.4
DEFAULT_RESOLUTION_PX = 256
DEFAULT_LAYER = 0
DEFAULT_STEP = 0.01

# Orientation enum — horizontal (width > height, the natural slider
# shape) or vertical (height > width). Differentiates from ScrollBarNode
# which defaults to vertical.
ORIENTATIONS = ("horizontal", "vertical")


def manifest() -> Manifest:
    return Manifest(
        name="SliderNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Functional state.
            "min": "float",
            "max": "float",
            "value": "float",
            "step": "float",
            "orientation": "string",
            # Wiring to the driven parameter (commit 5 LinkNode resolves
            # this string `<node_id>.<field>` reference at runtime).
            "parameter_target": "string",
            # Z-order + visual-variant override.
            "layer": "int",
            "displayed_by": "string",
            # Colors (visual variants may override).
            "track_color": "vec3",
            "thumb_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Slider primitive (N-F025). Functional state lives here "
            "(min/max/value/step/parameter_target/orientation); visual "
            "variants live as kind:renderer nodes naming "
            "presentation-of: SliderNode (Decision A1). Drives a "
            "parameter on another node via LinkNode wiring (commit 5)."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    track_color = params.get("track_color")
    if track_color is None:
        track_color = [0.18, 0.20, 0.26]
    thumb_color = params.get("thumb_color")
    if thumb_color is None:
        thumb_color = [0.62, 0.70, 0.82]

    orientation = str(params.get("orientation") or "horizontal")
    if orientation not in ORIENTATIONS:
        orientation = "horizontal"

    min_v = float(params.get("min") if params.get("min") is not None else 0.0)
    max_v = float(params.get("max") if params.get("max") is not None else 1.0)
    if max_v < min_v:
        min_v, max_v = max_v, min_v
    value = float(params.get("value") if params.get("value") is not None else min_v)
    value = max(min_v, min(max_v, value))

    step = float(params.get("step") if params.get("step") is not None else DEFAULT_STEP)
    # Negative or zero step would break step_up/step_down; clamp to a
    # tiny positive epsilon so the verb-set stays well-defined.
    if step <= 0.0:
        step = DEFAULT_STEP

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "min": min_v,
        "max": max_v,
        "value": value,
        "step": step,
        "orientation": orientation,
        "parameter_target": str(params.get("parameter_target") or ""),
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "displayed_by": str(params.get("displayed_by") or ""),
        "track_color": np.asarray(track_color, dtype=np.float32),
        "thumb_color": np.asarray(thumb_color, dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Sliders have no rendered children — the wired-parameter target is
    a sibling node referenced by string id, not a child."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render the slider's track + thumb at its screen-rectangle.

    Default emit = minimal-variant equivalent; visual variants
    registered as ``kind: renderer`` nodes override via the substrate's
    ``_execute_renderer`` dispatch.
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

    internal = _render_slider_to_array(
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
    """One-line summary for the text-API."""
    min_v = state.get("min", 0.0)
    max_v = state.get("max", 1.0)
    value = state.get("value", min_v)
    step = state.get("step", DEFAULT_STEP)
    target = state.get("parameter_target") or "(unwired)"
    orientation = state.get("orientation", "horizontal")
    displayed_by = state.get("displayed_by") or "(default)"
    return (
        f"SliderNode id={ctx.node.id} "
        f"value={value:.3f} range=[{min_v:.2f}, {max_v:.2f}] step={step:.3f} "
        f"orientation={orientation!r} parameter_target={target} "
        f"displayed_by={displayed_by}"
    )


# ---------------------------------------------------------------------------
# Verb dispatch (set_value / get_value / step_up / step_down)
# ---------------------------------------------------------------------------


def _snap_to_step(value: float, min_v: float, step: float) -> float:
    """Snap ``value`` to the nearest multiple of ``step`` relative to
    ``min``. Slider thumbs land on step-aligned positions; the raw
    ``value`` may not be on a step boundary after clamp."""
    if step <= 0.0:
        return value
    n_steps = round((value - min_v) / step)
    return min_v + n_steps * step


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    min_v = float(state.get("min", 0.0))
    max_v = float(state.get("max", 1.0))
    step = float(state.get("step", DEFAULT_STEP))

    if action_name == "set_value":
        try:
            new_value = float(payload.get("value"))
        except (TypeError, ValueError):
            return {"last_set_value": {
                "set": False,
                "reason": "value must be a number",
            }}
        clamped = max(min_v, min(max_v, new_value))
        snapped = _snap_to_step(clamped, min_v, step)
        # Re-clamp after snap (snap can push beyond max for rounding).
        snapped = max(min_v, min(max_v, snapped))
        was_clamped = snapped != new_value
        state["value"] = snapped
        return {
            "value": snapped,
            "last_set_value": {
                "set": True,
                "value": snapped,
                "requested": new_value,
                "clamped_or_snapped": was_clamped,
            },
        }

    if action_name == "get_value":
        return {"value": state.get("value", min_v),
                "last_get_value": {"value": state.get("value", min_v)}}

    if action_name == "step_up":
        current = float(state.get("value", min_v))
        new_value = max(min_v, min(max_v, current + step))
        state["value"] = new_value
        return {"value": new_value,
                "last_step_up": {"value": new_value, "from": current}}

    if action_name == "step_down":
        current = float(state.get("value", min_v))
        new_value = max(min_v, min(max_v, current - step))
        state["value"] = new_value
        return {"value": new_value,
                "last_step_down": {"value": new_value, "from": current}}

    return None


# ---------------------------------------------------------------------------
# Internal: slider raster
# ---------------------------------------------------------------------------


def _render_slider_to_array(
    width: int,
    height: int,
    min_v: float,
    max_v: float,
    value: float,
    orientation: str,
    track_color: np.ndarray,
    thumb_color: np.ndarray,
) -> np.ndarray:
    """Render the track strip + thumb knob at the fractional position.

    Slider track is thinner than ScrollBar's so the two visually
    differentiate without configuration. Thumb is a small filled
    rectangle (the minimal-variant); the knob variant draws a circle
    instead (and ships in the chunky variant rendering).
    """
    # Track is rendered as a thin strip on a dark background so a knob
    # has visible contrast; full-bleed track is the ScrollBar's shape.
    bg_tuple = (12, 14, 20)
    track_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in track_color)
    thumb_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in thumb_color)

    img = Image.new("RGB", (width, height), color=bg_tuple)
    draw = ImageDraw.Draw(img)

    span = max_v - min_v
    if span <= 0.0:
        fraction = 0.5
    else:
        fraction = (value - min_v) / span
        fraction = max(0.0, min(1.0, fraction))

    if orientation == "vertical":
        # Vertical: thin centered track + a small horizontal thumb.
        track_w = max(2, int(round(width * 0.15)))
        track_x = (width - track_w) // 2
        margin = max(4, height // 16)
        draw.rectangle(
            [(track_x, margin), (track_x + track_w - 1, height - margin)],
            fill=track_tuple,
        )
        thumb_w = max(4, int(round(width * 0.7)))
        thumb_h = max(3, int(round(height * 0.08)))
        thumb_x = (width - thumb_w) // 2
        max_thumb_y = max(0, (height - 2 * margin) - thumb_h)
        thumb_y = margin + int(round((1.0 - fraction) * max_thumb_y))
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )
    else:
        # Horizontal: thin centered track + a small vertical thumb.
        track_h = max(2, int(round(height * 0.15)))
        track_y = (height - track_h) // 2
        margin = max(4, width // 16)
        draw.rectangle(
            [(margin, track_y), (width - margin, track_y + track_h - 1)],
            fill=track_tuple,
        )
        thumb_w = max(3, int(round(width * 0.08)))
        thumb_h = max(4, int(round(height * 0.7)))
        thumb_y = (height - thumb_h) // 2
        max_thumb_x = max(0, (width - 2 * margin) - thumb_w)
        thumb_x = margin + int(round(fraction * max_thumb_x))
        draw.rectangle(
            [(thumb_x, thumb_y), (thumb_x + thumb_w - 1, thumb_y + thumb_h - 1)],
            fill=thumb_tuple,
        )

    return np.asarray(img, dtype=np.float32) / 255.0
