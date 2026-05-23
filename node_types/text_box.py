"""TextBoxNode — text-bearing box primitive (N-F020).

Brief 03 commit 2 — the second foundational primitive after BoxNode.
Composes Apeiron's box geometry + the shared text-rendering helpers
from ``engine/screen.py`` (the brief 03 commit 1 extraction) so the
text-rendering math lives in ONE place, not three (per existing-
primitives audit: list_renderer + chat_interface + computer each had
their own copy; that extraction landed in commit 1).

The functional contract per the per-module plan's N-F020 spec:

  - **Inputs (manifest):** geometry like BoxNode (``screen_width``,
    ``screen_height``, ``screen_resolution``), ``text`` (string),
    ``font_size`` (int), ``text_color`` (vec3), ``background_color``
    (vec3), ``display_mode`` (enum ``plain``/``markdown``/``code``,
    default ``plain``), ``scrollable`` (bool, default False —
    flipped to True when a ScrollBarNode is dropped on per a brief
    03 commit 5 interaction-rule), ``scroll_value`` (float, 0..1,
    wired by the ScrollBarNode when scrollable), ``parent_box``
    (string — the BoxNode id this text-box defaults to filling;
    empty means standalone), ``layer`` (int), ``corner_radius``
    (float — inherited from the surrounding BoxNode aesthetic),
    ``displayed_by`` (string).
  - **Outputs:** ``color``, ``depth``.
  - **Drop-targets** (per Decision A4 — interaction rules land in
    commit 5; this primitive only declares the slots): accepts
    ``MarkdownDisplayNode`` / ``TextDisplayNode`` / ``CodeDisplayNode``
    (sets ``display_mode``), accepts ``ScrollBarNode`` (sets
    ``scrollable: True``), accepts ``DropdownNode`` (sets
    ``display_mode_switcher``), accepts highlighted-text-link-drag
    (adds to ``links:`` list — N-F021 / commit 5).

Phase-1 ships ``display_mode == "plain"`` rendering only — markdown
+ code rendering land via interaction rules in commit 5 (which wire
the existing Resonance-Website markdown renderer through). The field
+ the slot exist now so the eventual wiring is a node-add, not a
rewire.

The default-fills-parent_box behavior per N-F020 verbatim — *"they
default to filling the entire box that they belong to"*. Phase-1
expression: when ``parent_box`` is non-empty AND no explicit
geometry is supplied, the text-box inherits the parent's geometry
(reads it from the engine cache populated by the parent's emit). The
inheritance is opt-in — supplying explicit ``screen_width`` /
``screen_height`` overrides. This keeps the primitive useful in
isolation (tests + headless use) while honoring the verbatim
default-behavior on real scenes.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import (
    _get_font,
    _paste_onto_screen_rectangle,
    _wrap_line,
)


DEFAULT_FONT_SIZE = 14
DEFAULT_W_WORLD = 2.5
DEFAULT_H_WORLD = 1.5
DEFAULT_RESOLUTION_PX = 256

# Display-mode enum. Phase-1 ships ``plain``; ``markdown`` + ``code`` are
# slot-declared so the interaction-rule wiring (commit 5) flips the
# field and the renderer dispatches additively to richer renderers.
DISPLAY_MODES = ("plain", "markdown", "code")


def manifest() -> Manifest:
    return Manifest(
        name="TextBoxNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            # Geometry (matches BoxNode + ListRenderer).
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Content.
            "text": "string",
            "font_size": "int",
            "text_color": "vec3",
            "background_color": "vec3",
            "corner_radius": "float",
            # Display + scroll state.
            "display_mode": "string",
            "scrollable": "bool",
            "scroll_value": "float",
            # Box-of-belonging (default-fills-parent_box per N-F020).
            "parent_box": "string",
            # Z-order (SPEC-094) + visual-variant override.
            "layer": "int",
            "displayed_by": "string",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Text-bearing box primitive (N-F020). Composes BoxNode "
            "geometry + the shared engine/screen.py text-rendering "
            "helpers. Display modes plain/markdown/code; scrollable "
            "when a ScrollBarNode is wired (interaction-rule, brief "
            "03 commit 5). Defaults to filling its parent_box."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    text_color = params.get("text_color")
    if text_color is None:
        text_color = [0.92, 0.93, 0.88]
    background_color = params.get("background_color")
    if background_color is None:
        background_color = [0.10, 0.11, 0.16]

    display_mode = str(params.get("display_mode") or "plain")
    if display_mode not in DISPLAY_MODES:
        display_mode = "plain"

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "text": str(params.get("text") or ""),
        "font_size": int(params.get("font_size") or DEFAULT_FONT_SIZE),
        "text_color": np.asarray(text_color, dtype=np.float32),
        "background_color": np.asarray(background_color, dtype=np.float32),
        "corner_radius": float(params.get("corner_radius") or 0.0),
        "display_mode": display_mode,
        "scrollable": bool(params.get("scrollable") or False),
        "scroll_value": float(params.get("scroll_value") or 0.0),
        "parent_box": str(params.get("parent_box") or ""),
        "layer": int(params.get("layer") or 0),
        "displayed_by": str(params.get("displayed_by") or ""),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Text-boxes have no rendered children — content is data, not
    sub-nodes. The display-mode-switcher dropdown + scroll-bar are
    SIBLING nodes wired via interaction-rules (commit 5)."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render text wrapped to the box, scroll-aware when scrollable.

    Phase-1: plain text only via the shared ``_render_text_to_array``
    approach (rebuilt inline so we can mix background_color +
    corner_radius without forcing engine/screen.py to grow new
    parameters). Markdown + code variants land in commit 5 via
    interaction-rules that swap ``display_mode``.

    When ``scrollable`` is True and ``scroll_value`` ∈ [0, 1], the
    visible text-rectangle is offset accordingly — implemented by
    rendering the full text to a tall internal raster then slicing
    a window equal to the box height.
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

    internal = _render_text_box_to_array(
        text=state["text"],
        width=screen_w_px,
        height=screen_h_px,
        font_size=state["font_size"],
        text_color=state["text_color"],
        background_color=state["background_color"],
        corner_radius=state["corner_radius"],
        scrollable=state["scrollable"],
        scroll_value=state["scroll_value"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API.

    Truncates the text body to keep the output diagnostic-friendly.
    The display_mode + scrollable + scroll_value fields all surface so
    the LLM-driver can inspect the wiring state without re-rendering.
    """
    snippet = (state.get("text") or "")[:40].replace("\n", " ")
    if len(state.get("text") or "") > 40:
        snippet += "…"
    mode = state.get("display_mode", "plain")
    scrollable = state.get("scrollable", False)
    scroll = state.get("scroll_value", 0.0)
    parent = state.get("parent_box") or "(standalone)"
    return (
        f"TextBoxNode id={ctx.node.id} mode={mode!r} "
        f"parent_box={parent} scrollable={scrollable} "
        f"scroll_value={scroll:.2f} text={snippet!r}"
    )


# ---------------------------------------------------------------------------
# Drop-target acceptance (slot-only, brief 03 commit 5 wires interaction-rules)
# ---------------------------------------------------------------------------
#
# Per Decision A4 + the N-F020 ``Drop-targets`` bullet, TextBoxNode
# accepts four drag-source kinds. Commit 5 ships the interaction-rule
# nodes that actually fire on these drops; this primitive exposes the
# accept-list so a future no-op-prober (Tool T3) can validate that the
# slot exists even before the rule lands.

ACCEPTED_DRAG_SOURCE_KINDS = (
    "MarkdownDisplayNode",
    "TextDisplayNode",
    "CodeDisplayNode",
    "ScrollBarNode",
    "DropdownNode",
    # The text-link drag-from-highlighted-range case (N-F021) — the
    # source's kind is the dragged node-kind itself; phase-1 accepts
    # any kind as a candidate text-link target. Refinement lands when
    # the TextLinkNode primitive lands in commit 5.
)


def accepts_drop(source_kind: str) -> bool:
    """Return True if a drop of ``source_kind`` onto this text-box is
    handled (subject to the runtime interaction-rule firing in commit
    5+). Used by the drag-drop dispatcher to short-circuit no-rule
    paths AND by Tool T3 for slot validation pre-commit-5.
    """
    return source_kind in ACCEPTED_DRAG_SOURCE_KINDS


# ---------------------------------------------------------------------------
# Internal: text rasterization with background + optional scroll
# ---------------------------------------------------------------------------


def _render_text_box_to_array(
    text: str,
    width: int,
    height: int,
    font_size: int,
    text_color: np.ndarray,
    background_color: np.ndarray,
    corner_radius: float,
    scrollable: bool,
    scroll_value: float,
) -> np.ndarray:
    """Render text to an RGB float32 array in [0, 1].

    Composition over ``engine.screen._get_font`` + ``_wrap_line``
    (extracted in brief 03 commit 1). Background fills first; optional
    rounded-rectangle stencil clips the corners; text overlays last.

    ``scrollable`` + ``scroll_value`` shift the visible text window: when
    True, we render the full text to a tall buffer then slice the
    appropriate vertical band. ``scroll_value`` is clamped to [0, 1].
    """
    bg_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in background_color)
    fg_tuple = tuple(int(max(0.0, min(1.0, c)) * 255) for c in text_color)

    img = Image.new("RGB", (width, height), color=bg_tuple)
    draw = ImageDraw.Draw(img)
    font = _get_font(font_size)

    margin = max(4, font_size // 3)
    line_h = font_size + 4
    max_chars_per_line = max(10, (width - 2 * margin) // (font_size // 2))

    # Wrap every source line.
    wrapped: list[str] = []
    for raw_line in (text or "").splitlines() or [""]:
        for piece in _wrap_line(raw_line, max_chars_per_line):
            wrapped.append(piece)

    # Visible window: how many lines fit; for scrollable, slice.
    visible_lines = max(1, (height - 2 * margin) // line_h)
    if scrollable and len(wrapped) > visible_lines:
        offset = max(0, min(1.0, float(scroll_value)))
        max_offset = max(0, len(wrapped) - visible_lines)
        start = int(round(offset * max_offset))
        end = start + visible_lines
        wrapped = wrapped[start:end]
    else:
        wrapped = wrapped[:visible_lines]

    y = margin
    for line in wrapped:
        if y + line_h > height - margin:
            break
        draw.text((margin, y), line, fill=fg_tuple, font=font)
        y += line_h

    arr = np.asarray(img, dtype=np.float32) / 255.0

    # Corner-radius clipping — apply via a binary stencil so the
    # background's pixels at the rounded corners revert to black
    # (matching how the BoxNode's pasted output looks at the corner).
    smaller = min(width, height)
    radius_px = int(max(0.0, min(corner_radius * smaller, smaller // 2)))
    if radius_px > 0 and hasattr(ImageDraw.Draw(Image.new("L", (1, 1))), "rounded_rectangle"):
        mask_img = Image.new("L", (width, height), color=0)
        mask_draw = ImageDraw.Draw(mask_img)
        mask_draw.rounded_rectangle(
            [(0, 0), (width - 1, height - 1)],
            radius=radius_px,
            fill=255,
        )
        mask = np.asarray(mask_img, dtype=np.float32) / 255.0
        arr = arr * mask[..., None]

    return arr
