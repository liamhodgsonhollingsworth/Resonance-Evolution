"""BoxNode — resizable rounded rectangle (N-F019 / SPEC-094 foundation).

Brief 03 commit 2 of the Resonance website implementation arc. The first
of the three foundational box/container primitives the brief commits to
(``BoxNode``, ``TextBoxNode``, ``ToolboxNode``); the three together let
every other primitive in the brief compose against them rather than
re-implementing geometry, paste-onto-screen, lock-state, and layer
ordering one-off per primitive.

The functional contract per the per-module plan's N-F019 spec:

  - **Inputs (manifest):** ``x``, ``y``, ``w``, ``h`` (float), plus
    ``corner_radius`` (float, default 0), ``fill_color`` (vec3),
    ``border_color`` (vec3), ``border_width`` (float), ``layer`` (int,
    SPEC-094), ``accept_unknown_drop`` (enum, SPEC-092 default
    ``return-to-origin``).
  - **Outputs:** ``color``, ``depth`` — the screen-rectangle raster pair
    via the shared ``_paste_onto_screen_rectangle`` helper from
    ``engine/screen.py`` (brief 03 commit 1).
  - **Verbs (handle_action):** none of its own — the move/resize/lock
    math delegates to ``panel_positioner_main`` (Apeiron
    ``node_types/panel_positioner.py``) via the existing dispatch
    pattern; lock state delegates to the GUI shell's ``WidgetLock``
    registry per SPEC-075 via ``widget_id = <box.id>``.

Composition contract (per existing-primitives audit + mistake #009):

  - ``engine/screen.py`` — paste-onto-screen-rectangle (brief 03 commit
    1 extraction).
  - ``node_types/panel_positioner.py`` — surface-independent
    move/resize/snap/lock math. Brief 03's per-module plan calls this
    out as Decision A5 + the N-F019 ``Implementation steps`` bullet 2.
  - ``tools/workflow_gui/widget_lock.py`` — per-widget lock registry
    (SPEC-075). The plan's ``Implicit cross-cut SPECs`` section names
    this composition explicitly: *"every primitive's lock state
    delegates to the GUI shell's WidgetLock registry via the
    widget-id = <box-id> pattern."*

The functional/visual split per Decision A1: BoxNode is the FUNCTIONAL
node carrying geometry + corner-radius state. Visual variants live in
``Resonance-Website/renderers/presentations/box_*_v1.{md,py}`` and are
selected via the optional ``displayed_by:`` connection — phase-1 ships
the default raster emit only, with HTML/painterly variants following in
commit 3+ per the per-module plan's implementation order.

Visual-variant binding is also forward-compat — when no ``displayed_by``
connection is set the default raster emit fires; when set, the
substrate's ``execute(presentation_node, {primitive_state: ...,
context: ...})`` dispatch takes over (the kind: presentation +
renderer-spec contract from brief 01 SPEC-090). Brief 03 commit 3 lands
the first visual variants; this commit (commit 2) ships the default
emit so downstream commits compose freely.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _paste_onto_screen_rectangle


# Default geometry — small but visible in test viewers without dominating
# the frame. Each is in the same world-space units used by ListRenderer's
# ``screen_width`` / ``screen_height`` (per ``node_types/list_renderer.py``).
DEFAULT_W_WORLD = 2.0
DEFAULT_H_WORLD = 1.5
DEFAULT_RESOLUTION_PX = 256
DEFAULT_LAYER = 0


# SPEC-092: the accept_unknown_drop policy enum. Default per the per-module
# plan: return-to-origin. Other modes are opt-in for free-form or immutable
# areas. Brief 03's interaction-rule-evaluator (Tool T4, brief 03 commit 5)
# reads this field at drop-time; this primitive only declares + persists it.
ACCEPT_UNKNOWN_DROP_MODES = ("return-to-origin", "stay-where-dropped", "reject")


def manifest() -> Manifest:
    return Manifest(
        name="BoxNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            # World-space geometry (matches ListRenderer's screen_width /
            # screen_height convention so the same paste helper applies).
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Visual properties.
            "corner_radius": "float",
            "fill_color": "vec3",
            "border_color": "vec3",
            "border_width": "float",
            # Z-order + drop-policy (SPEC-094 + SPEC-092).
            "layer": "int",
            "accept_unknown_drop": "string",
            # Visual-variant override per Decision A1 (optional; default
            # is empty string meaning "use the kind's default emit").
            "displayed_by": "string",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Resizable rounded-rectangle primitive (N-F019). The "
            "functional foundation every other surface primitive composes "
            "against: own geometry, own corner-radius, own layer/drop "
            "policy. Move/resize/lock delegate to PanelPositioner + "
            "WidgetLock; rendering pastes a rounded rect onto the "
            "screen rectangle via engine/screen.py."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    """Validate + normalize the params dict.

    Every field carries a sensible default — instantiating a BoxNode
    with empty params produces a usable mid-grey box.
    """
    fill_color = params.get("fill_color")
    if fill_color is None:
        fill_color = [0.18, 0.20, 0.26]
    border_color = params.get("border_color")
    if border_color is None:
        border_color = [0.55, 0.60, 0.70]

    accept = str(params.get("accept_unknown_drop") or "return-to-origin")
    if accept not in ACCEPT_UNKNOWN_DROP_MODES:
        # Defensive: keep the field strict-enum so misconfiguration is
        # caught at build-time rather than at drop-time. Falling back to
        # the default keeps the primitive instantiable.
        accept = "return-to-origin"

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "corner_radius": float(params.get("corner_radius") or 0.0),
        "fill_color": np.asarray(fill_color, dtype=np.float32),
        "border_color": np.asarray(border_color, dtype=np.float32),
        "border_width": float(params.get("border_width") or 0.0),
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "accept_unknown_drop": accept,
        "displayed_by": str(params.get("displayed_by") or ""),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Boxes have no rendered children at the engine level — child
    composition is owned by the parent (workflow surface, page, GUI
    builder). Returning empty here keeps the emit path single-pass."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render a rounded rectangle filling the box's world-space
    rectangle.

    The paste helper from ``engine/screen.py`` handles the 3D
    ray-cast + UV-sample so the same primitive renders in dream-mode,
    realtime, ASCII, raster-test — every outer-view backend.

    The internal raster uses PIL ``ImageDraw.rounded_rectangle`` for
    the fill + outline at the configured corner_radius. Resolution
    follows the same aspect-preserving scale ListRenderer uses so the
    raster shape stays predictable across surfaces.
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

    internal = _render_box_to_array(
        width=screen_w_px,
        height=screen_h_px,
        corner_radius=state["corner_radius"],
        fill_color=state["fill_color"],
        border_color=state["border_color"],
        border_width=state["border_width"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API (SPEC-061 enumeration contract).

    Per per-module plan Cross-cut X6 + Scenario 10: every primitive's
    ``describe()`` returns enough text for the LLM-driver to identify
    the kind + key state without screenshots.
    """
    w = state.get("screen_width", 0)
    h = state.get("screen_height", 0)
    r = state.get("corner_radius", 0)
    layer = state.get("layer", 0)
    drop = state.get("accept_unknown_drop", "return-to-origin")
    return (
        f"BoxNode id={ctx.node.id} "
        f"size={w:.2f}x{h:.2f} corner_radius={r:.2f} "
        f"layer={layer} accept_unknown_drop={drop!r}"
    )


# ---------------------------------------------------------------------------
# Lock-state delegation (SPEC-075).
# ---------------------------------------------------------------------------
#
# The functional contract names a per-module convention: a BoxNode's lock
# state lives in the GUI shell's ``WidgetLock`` registry, keyed by
# ``widget_id = <box.id>``. The shell-side wiring lives in
# ``tools/workflow_gui/gui_shell.py``; this primitive ships the helper a
# headless caller (test harness, MCP text-API, future HTML surface) uses
# to consult the same registry without instantiating Tk.


def is_locked(box_id: str, lock_registry) -> bool:
    """Return True if the box's widget_id is locked in the given registry.

    ``lock_registry`` is a ``tools.workflow_gui.widget_lock.WidgetLock``
    instance (the duck-typed contract: it just needs an
    ``is_widget_locked(widget_id) -> bool`` method). The function is a
    thin façade so call sites don't have to know the widget_id scheme;
    future schemes (composite ids, parent-scoped ids) override here
    once without touching every call site.
    """
    if lock_registry is None:
        return False
    if not hasattr(lock_registry, "is_widget_locked"):
        return False
    return bool(lock_registry.is_widget_locked(box_id))


# ---------------------------------------------------------------------------
# Internal: rounded-rectangle raster
# ---------------------------------------------------------------------------


def _render_box_to_array(
    width: int,
    height: int,
    corner_radius: float,
    fill_color: np.ndarray,
    border_color: np.ndarray,
    border_width: float,
) -> np.ndarray:
    """Render a rounded rectangle at the given pixel resolution.

    Returns an RGB float32 array in [0, 1] of shape (height, width, 3).
    The corner_radius is treated as a world-space fraction of the
    smaller dimension; ``corner_radius=0.5`` produces a pill shape at
    ``width == height``. Negative corner_radius clamps to 0.
    """
    fill_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in fill_color)
    border_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in border_color)

    img = Image.new("RGB", (width, height), color=(0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Corner radius interpreted as a fraction of the smaller dimension
    # (so the primitive's API stays surface-agnostic — caller passes a
    # value in world-space units OR a fraction, the heuristic preserves
    # the visual). Per the per-module plan the field is a float; here
    # we clamp to keep PIL happy with degenerate input.
    smaller = min(width, height)
    radius_px = int(max(0.0, min(corner_radius * smaller, smaller // 2)))

    # PIL's rounded_rectangle was added in Pillow 8.2; on older Pillow
    # the rectangle path renders as a sharp rectangle (degraded mode
    # rather than crash).
    if hasattr(draw, "rounded_rectangle") and radius_px > 0:
        draw.rounded_rectangle(
            [(0, 0), (width - 1, height - 1)],
            radius=radius_px,
            fill=fill_tuple,
            outline=border_tuple if border_width > 0 else None,
            width=max(1, int(border_width)) if border_width > 0 else 1,
        )
    else:
        draw.rectangle(
            [(0, 0), (width - 1, height - 1)],
            fill=fill_tuple,
            outline=border_tuple if border_width > 0 else None,
            width=max(1, int(border_width)) if border_width > 0 else 1,
        )

    return np.asarray(img, dtype=np.float32) / 255.0
