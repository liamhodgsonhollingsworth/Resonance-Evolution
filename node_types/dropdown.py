"""DropdownNode — dropdown primitive (N-F027 / SPEC-090).

Brief 03 commit 3 of the Resonance website implementation arc — the
third of the three control primitives. The functional contract per the
per-module plan's N-F027 spec:

  - **Inputs (manifest):** ``options`` (list of dicts
    ``{id: str, label: str}``), ``selected`` (string — the selected
    option's id), ``on_change_action`` (string — the action dispatched
    when the selection changes; reuses the SPEC-077 action vocabulary),
    ``layer`` (int, SPEC-094), ``displayed_by`` (string — visual-
    variant binding per Decision A1).
  - **Outputs:** ``color``, ``depth`` (visual variant emit).
  - **Verbs (handle_action):**
      * ``select(option_id)`` — set ``selected`` if the id is in
        ``options``; surfaces ``last_select`` with the on_change_action
        + payload so the dispatch layer routes the event.
      * ``add_option({id, label})`` — append (used by the N-F022
        display-mode-switcher interaction-rule + the brief 04 builder).
      * ``remove_option(id)`` — drop by id.
      * ``get_selected_label`` — read-back convenience.

Functional/visual split per Decision A1: visual variants are
``kind: renderer`` substrate nodes naming ``presentation-of:
DropdownNode``. The default emit is the minimal-variant equivalent —
the selected option's label drawn on a small rectangle with a
downward chevron, plus the option list below (collapsed display in
phase-1 — open/closed state is a visual concern owned by the variant).

Per the per-module plan's N-F027 ``Risk + mitigation``: the minimal
variant uses the native ``<select>`` for HTML (handles N>20 options
well); the chunky variant truncates with "+M more"; the radial variant
is a circular menu. This Apeiron-side raster shows all options up to
the visible band — variants drive the richer behaviors.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _get_font, _paste_onto_screen_rectangle, _truncate


DEFAULT_W_WORLD = 2.5
DEFAULT_H_WORLD = 0.5
DEFAULT_RESOLUTION_PX = 256
DEFAULT_LAYER = 0


def manifest() -> Manifest:
    return Manifest(
        name="DropdownNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Functional state.
            "options": "list",
            "selected": "string",
            "on_change_action": "string",
            "on_change_target": "string",
            # Z-order + visual-variant override.
            "layer": "int",
            "displayed_by": "string",
            # Colors (variant override).
            "background_color": "vec3",
            "text_color": "vec3",
            "chevron_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Dropdown primitive (N-F027). Functional state lives here "
            "(options/selected/on_change_action); visual variants live "
            "as kind:renderer nodes naming presentation-of: "
            "DropdownNode (Decision A1). Dispatches the configured "
            "on_change_action when select() changes the selection."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    bg = params.get("background_color")
    if bg is None:
        bg = [0.16, 0.18, 0.24]
    text_color = params.get("text_color")
    if text_color is None:
        text_color = [0.92, 0.93, 0.88]
    chevron_color = params.get("chevron_color")
    if chevron_color is None:
        chevron_color = [0.62, 0.70, 0.82]

    # Normalize options — each entry must be a dict with non-empty id
    # and label. Malformed entries are skipped (defensive default).
    raw_options = params.get("options") or []
    if not isinstance(raw_options, list):
        raw_options = []
    options: list[dict] = []
    seen_ids: set[str] = set()
    for entry in raw_options:
        if not isinstance(entry, dict):
            continue
        opt_id = str(entry.get("id") or "")
        if not opt_id or opt_id in seen_ids:
            continue
        label = str(entry.get("label") or opt_id)
        options.append({"id": opt_id, "label": label})
        seen_ids.add(opt_id)

    selected = str(params.get("selected") or "")
    # If a selected id was supplied but isn't in options, fall back to
    # empty (or the first option's id when options is non-empty). Keeps
    # the dropdown in a renderable state for any spawn.
    if selected and not any(o["id"] == selected for o in options):
        selected = options[0]["id"] if options else ""
    elif not selected and options:
        selected = options[0]["id"]

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "options": options,
        "selected": selected,
        "on_change_action": str(params.get("on_change_action") or ""),
        "on_change_target": str(params.get("on_change_target") or ""),
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "displayed_by": str(params.get("displayed_by") or ""),
        "background_color": np.asarray(bg, dtype=np.float32),
        "text_color": np.asarray(text_color, dtype=np.float32),
        "chevron_color": np.asarray(chevron_color, dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Dropdowns have no rendered children — options are inline data.

    The N-F022 display-mode-switcher pattern (commit 5) wires three
    display-mode nodes as OPTIONS (string ids), not children — the
    interaction-rule expresses the binding rather than the tree.
    """
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render the selected label + a downward chevron on a rectangle.

    Minimal-variant equivalent — the closed-form representation. Visual
    variants registered as ``kind: renderer`` nodes override (e.g. the
    chunky variant draws an expanded option list; the radial variant
    draws a circular menu).
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

    internal = _render_dropdown_to_array(
        width=screen_w_px,
        height=screen_h_px,
        selected_label=_selected_label(state),
        bg=state["background_color"],
        text_color=state["text_color"],
        chevron_color=state["chevron_color"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API."""
    options = state.get("options", []) or []
    selected = state.get("selected") or "(none)"
    action = state.get("on_change_action") or "(no action)"
    n_opts = len(options)
    displayed_by = state.get("displayed_by") or "(default)"
    return (
        f"DropdownNode id={ctx.node.id} "
        f"options={n_opts} selected={selected!r} "
        f"on_change_action={action!r} displayed_by={displayed_by}"
    )


def _selected_label(state: Dict[str, Any]) -> str:
    """Helper: look up the currently-selected option's label."""
    selected = state.get("selected") or ""
    for option in state.get("options", []) or []:
        if option.get("id") == selected:
            return str(option.get("label") or selected)
    return "(no selection)"


# ---------------------------------------------------------------------------
# Verb dispatch (select / add_option / remove_option / get_selected_label)
# ---------------------------------------------------------------------------


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    options: list[dict] = list(state.get("options") or [])

    if action_name == "select":
        option_id = str(payload.get("option_id") or "").strip()
        if not option_id:
            return {"last_select": {"selected": False,
                                     "reason": "empty option_id"}}
        if not any(o.get("id") == option_id for o in options):
            return {"last_select": {
                "selected": False, "option_id": option_id,
                "reason": "option_id not in options",
            }}
        previous = state.get("selected")
        state["selected"] = option_id
        return {
            "selected": option_id,
            "last_select": {
                "selected": True,
                "option_id": option_id,
                "previous": previous,
                "on_change_action": state.get("on_change_action") or "",
                "on_change_target": state.get("on_change_target") or "",
            },
        }

    if action_name == "add_option":
        opt_id = str(payload.get("id") or "").strip()
        label = str(payload.get("label") or opt_id)
        if not opt_id:
            return {"last_add_option": {"added": False,
                                         "reason": "empty option id"}}
        if any(o.get("id") == opt_id for o in options):
            return {"last_add_option": {
                "added": False, "id": opt_id,
                "reason": "option id already present",
            }}
        options.append({"id": opt_id, "label": label})
        state["options"] = options
        # Selected unchanged unless the dropdown was empty + just got
        # its first option.
        if not state.get("selected"):
            state["selected"] = opt_id
        return {"options": options,
                "last_add_option": {"added": True, "id": opt_id,
                                     "label": label,
                                     "index": len(options) - 1}}

    if action_name == "remove_option":
        opt_id = str(payload.get("id") or "").strip()
        if not opt_id:
            return {"last_remove_option": {"removed": False,
                                            "reason": "empty option id"}}
        for i, entry in enumerate(options):
            if entry.get("id") == opt_id:
                options.pop(i)
                state["options"] = options
                # If we removed the selected option, fall back to first
                # remaining or empty.
                if state.get("selected") == opt_id:
                    state["selected"] = options[0]["id"] if options else ""
                return {"options": options,
                        "last_remove_option": {"removed": True,
                                                "id": opt_id, "index": i}}
        return {"last_remove_option": {"removed": False, "id": opt_id,
                                        "reason": "id not in options"}}

    if action_name == "get_selected_label":
        return {"last_get_selected_label": {"label": _selected_label(state),
                                              "id": state.get("selected", "")}}

    return None


# ---------------------------------------------------------------------------
# Internal: dropdown raster (closed form — selected label + chevron)
# ---------------------------------------------------------------------------


def _render_dropdown_to_array(
    width: int,
    height: int,
    selected_label: str,
    bg: np.ndarray,
    text_color: np.ndarray,
    chevron_color: np.ndarray,
) -> np.ndarray:
    """Render the dropdown closed-form: rectangle background + selected
    label + downward chevron at the right.
    """
    bg_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in bg)
    text_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in text_color)
    chevron_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in chevron_color)

    img = Image.new("RGB", (width, height), color=bg_tuple)
    draw = ImageDraw.Draw(img)

    font_size = max(12, height // 3)
    font = _get_font(font_size)
    margin = max(4, font_size // 3)

    # Reserve space on the right for the chevron.
    chevron_w = max(8, height // 2)
    label_max_w = max(8, width - 3 * margin - chevron_w)
    label = _truncate(selected_label, label_max_w, font) if selected_label else ""
    if label:
        # Vertical-center the label.
        text_y = max(0, (height - font_size) // 2)
        draw.text((margin, text_y), label, fill=text_tuple, font=font)

    # Downward chevron at the right edge.
    chev_cx = width - margin - chevron_w // 2
    chev_cy = height // 2
    chev_half_w = chevron_w // 2
    chev_half_h = max(3, chevron_w // 3)
    draw.polygon(
        [
            (chev_cx - chev_half_w, chev_cy - chev_half_h),
            (chev_cx + chev_half_w, chev_cy - chev_half_h),
            (chev_cx, chev_cy + chev_half_h),
        ],
        fill=chevron_tuple,
    )

    return np.asarray(img, dtype=np.float32) / 255.0
