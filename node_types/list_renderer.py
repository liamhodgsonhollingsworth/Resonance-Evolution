"""
ListRenderer — owns a screen rectangle in the outer world; consumes an
`items` channel from a connected DataSource; draws a vertical list with
status glyphs and titles.

Half of the Tier A primitive pair (DataSource + Renderer). Together they
generalize all of Tier A and most of Tier C — a new panel is one source
plus one renderer plus a connection, no new node-types needed.

Item shape consumed (per node_types/parsers/__init__.py):

    {
        "id": str, "title": str, "body": str,
        "status": str | None, "meta": dict, "actions": list[str],
    }

Status-to-glyph map and status-to-color map are exposed as params so
each panel instance can override (Tasks use [ ]/[x]/[~]; Wishes use
status words like pending/granted; Ideas use queue/resolved).

Item actions ride through ``engine.actions.dispatch_action`` →
``handle_action`` here. The v1 actions are ``expand`` (item-scoped:
sets per-renderer view-state's ``expanded_item`` to the named item-id)
and ``collapse`` (renderer-scoped: clears ``expanded_item``). When an
item is currently expanded, ``emit`` renders a single-item detail view
filling the panel rectangle instead of the list. Defensive emit drops
stale ``expanded_item`` references (a source-file edit that removes
the item or changes its id falls through to the list view rather than
showing the wrong item).

The screen-rectangle paste shares its primitive shape with
ChatInterface and Computer — same ray-cast + UV-sample pattern. Future
extraction of `_paste_onto_screen_rectangle` into a shared
`engine/screen.py` helper would unify the three (the feasibility
subagent flagged this as recommended-but-not-required).
"""

from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.actions import VIEW_STATE_CACHE_KEY
from engine.node import Channels, EmitContext, Manifest, View
# Shared text-rendering + screen-paste helpers — extracted from this module
# (and chat_interface.py + computer.py) into engine/screen.py per brief 03
# commit 1 of the Resonance website implementation arc. The names ARE the
# API; importing them under the same names preserves every existing call
# site verbatim. See engine/screen.py docstring + tests/test_engine_screen.py
# for the regression contract.
from engine.screen import (
    _get_font,
    _measure,
    _paste_onto_screen_rectangle,
    _truncate,
    _wrap,
)


DEFAULT_STATUS_GLYPHS = {
    "pending": "[ ]",
    "done": "[x]",
    "in_progress": "[~]",
    "cancelled": "[-]",
    "granted": "[g]",
    "planning": "[p]",
    "granting": "[*]",
    "superseded": "[s]",
    "resolved": "[r]",
    "alert": "[!]",
    "warn": "[?]",
    "ok": "[.]",
    None: "•",
}


DEFAULT_STATUS_COLORS = {
    "pending": [0.85, 0.85, 0.55],
    "done": [0.55, 0.85, 0.55],
    "in_progress": [0.55, 0.75, 0.95],
    "cancelled": [0.55, 0.55, 0.55],
    "granted": [0.45, 0.95, 0.65],
    "planning": [0.95, 0.85, 0.45],
    "granting": [0.95, 0.65, 0.45],
    "superseded": [0.55, 0.55, 0.55],
    "resolved": [0.45, 0.85, 0.95],
    "alert": [0.95, 0.45, 0.45],
    "warn": [0.95, 0.85, 0.45],
    "ok": [0.65, 0.85, 0.65],
    None: [0.85, 0.85, 0.85],
}


def manifest() -> Manifest:
    return Manifest(
        name="ListRenderer",
        version="1.0",
        renderer_id="raster",
        inputs={
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            "font_size": "int",
            "title_text": "string",
            "background_color": "vec3",
            "title_color": "vec3",
            "status_glyphs": "dict",
            "status_colors": "dict",
            "max_items": "int",
            "scroll_offset": "int",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "A screen-rectangle that renders a vertical list of items "
            "(id/title/status) read from a connected DataSource via the "
            "items channel. Each panel of WorkflowView is one of these."
        ),
    )


def build(params):
    return {
        "screen_width": float(params.get("screen_width", 3.0)),
        "screen_height": float(params.get("screen_height", 4.0)),
        "screen_resolution": int(params.get("screen_resolution", 384)),
        "font_size": int(params.get("font_size", 14)),
        "title_text": str(params.get("title_text", "")),
        "background_color": np.asarray(
            params.get("background_color", [0.10, 0.11, 0.16]), dtype=np.float32
        ),
        "title_color": np.asarray(
            params.get("title_color", [0.95, 0.95, 0.85]), dtype=np.float32
        ),
        "status_glyphs": dict(params.get("status_glyphs", {}) or DEFAULT_STATUS_GLYPHS),
        "status_colors": {
            k: np.asarray(v, dtype=np.float32)
            for k, v in dict(params.get("status_colors", {}) or DEFAULT_STATUS_COLORS).items()
        },
        "max_items": int(params.get("max_items", 100)),
        "scroll_offset": int(params.get("scroll_offset", 0)),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """The connected DataSource was already emitted (precompute did the
    actual work); we don't need to recurse into it at emit-time. Reading
    items from engine.cache by source-node-id is enough."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    items = _read_items_from_source(ctx)
    source_error = _read_source_error(ctx)
    expanded_item = _read_expanded_item(ctx, items)

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

    if expanded_item is not None:
        panel_image = _render_expanded_to_array(
            item=expanded_item,
            title=state["title_text"],
            width=screen_w_px,
            height=screen_h_px,
            font_size=state["font_size"],
            bg=state["background_color"],
            title_color=state["title_color"],
            status_glyphs=state["status_glyphs"],
            status_colors=state["status_colors"],
        )
    else:
        panel_image = _render_panel_to_array(
            items=items,
            title=state["title_text"],
            error=source_error,
            width=screen_w_px,
            height=screen_h_px,
            font_size=state["font_size"],
            bg=state["background_color"],
            title_color=state["title_color"],
            status_glyphs=state["status_glyphs"],
            status_colors=state["status_colors"],
            max_items=state["max_items"],
            scroll_offset=state["scroll_offset"],
        )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=panel_image,
    )


def describe(state, ctx: EmitContext) -> str:
    items = _read_items_from_source(ctx)
    error = _read_source_error(ctx)
    title = state["title_text"] or "(untitled list)"
    if error:
        return f"ListRenderer({title}): SOURCE ERROR — {error}"
    expanded_item = _read_expanded_item(ctx, items)
    if expanded_item is not None:
        glyph = state["status_glyphs"].get(
            expanded_item.get("status"),
            state["status_glyphs"].get(None, "•"),
        )
        return (
            f"ListRenderer({title}): EXPANDED {glyph} {expanded_item.get('title', '')} "
            f"[id={expanded_item.get('id', '?')}]"
        )
    lines = [f"ListRenderer({title}): {len(items)} items"]
    for item in items[:20]:
        glyph = state["status_glyphs"].get(item.get("status"), state["status_glyphs"].get(None, "•"))
        lines.append(f"  {glyph} {item.get('title', '')}  [id={item.get('id', '?')}]")
    if len(items) > 20:
        lines.append(f"  ... and {len(items) - 20} more")
    return "\n".join(lines)


def handle_action(
    state,
    action_name: str,
    payload: Dict[str, Any],
    engine,
    node,
) -> Optional[Dict[str, Any]]:
    """
    Handle an action dispatched via ``engine.actions.dispatch_action``.

    Returns a state-delta dict merged into the per-renderer view-state
    at ``engine.cache["__view_state__"][node.id]``. Returning ``None``
    or ``{}`` is a no-op (action ran but did not change view-state).

    Renderer-owned actions:

    - ``expand`` (item-scoped) — record the item-id under
      ``expanded_item``. Subsequent ``emit`` calls render the expanded
      detail view in the panel rectangle.
    - ``collapse`` (renderer-scoped) — clear ``expanded_item``. The
      panel returns to its list rendering.

    Source-owned actions: any verb other than ``expand`` / ``collapse``
    is delegated to the source's action-handlers if the connected
    DataSource provided any. A source registers handlers by including a
    ``_action_handlers`` dict in its ``engine.cache[node_id]`` entry,
    mapping verb-name to a callable ``(payload, engine, node) -> dict |
    None``. This keeps the renderer generic — the trust UI (quarantine
    promote / delete / revoke) ships its own handlers via this hook
    without the renderer depending on the trust module.
    """
    if action_name == "expand":
        item_id = payload.get("item_id")
        if not item_id:
            return None
        return {"expanded_item": item_id}
    if action_name == "collapse":
        return {"expanded_item": None}
    handlers = _read_source_action_handlers(engine, node)
    handler = handlers.get(action_name)
    if handler is None:
        return None
    try:
        return handler(payload, engine, node)
    except Exception as e:
        engine.errors.append(
            f"ListRenderer({node.id}) source-action {action_name!r}: {e}"
        )
        return None


def _read_source_action_handlers(engine, node) -> Dict[str, Any]:
    """Read the connected DataSource's registered action handlers, or
    return an empty dict if none are registered.
    """
    if node is None or not hasattr(node, "connections"):
        return {}
    conn = node.connections.get("source")
    if conn is None:
        return {}
    source_id = _resolve_target_id(conn)
    cache_entry = engine.cache.get(source_id, {})
    if not isinstance(cache_entry, dict):
        return {}
    handlers = cache_entry.get("_action_handlers")
    return handlers if isinstance(handlers, dict) else {}


# ---------------------------------------------------------------------------
# items-channel reading + view-state
# ---------------------------------------------------------------------------

def _read_items_from_source(ctx: EmitContext) -> List[Dict]:
    """The DataSource's precompute_hook stored items under its node-id
    in engine.cache; we look up via the 'source' connection."""
    conn = ctx.node.connections.get("source")
    if conn is None:
        return []
    source_id = _resolve_target_id(conn)
    cache_entry = ctx.engine.cache.get(source_id, {})
    if isinstance(cache_entry, dict):
        return cache_entry.get("items", []) or []
    return []


def _read_source_error(ctx: EmitContext):
    conn = ctx.node.connections.get("source")
    if conn is None:
        return None
    source_id = _resolve_target_id(conn)
    cache_entry = ctx.engine.cache.get(source_id, {})
    if isinstance(cache_entry, dict):
        return cache_entry.get("error")
    return None


def _read_expanded_item(ctx: EmitContext, items: List[Dict]) -> Optional[Dict]:
    """
    Read this renderer's expanded-item state from
    ``engine.cache["__view_state__"][node.id]``. Returns the item dict
    if expansion is active AND the id still resolves against the
    current items list (defensive: a source-file edit that shifts ids
    falls through to the list view instead of expanding the wrong
    item).
    """
    by_renderer = ctx.engine.cache.get(VIEW_STATE_CACHE_KEY, {})
    state = by_renderer.get(ctx.node.id, {})
    expanded_id = state.get("expanded_item")
    if not expanded_id:
        return None
    for item in items:
        if item.get("id") == expanded_id:
            return item
    return None


def _resolve_target_id(conn) -> str:
    """A connection may be a plain string (node-id) or a dict with
    'target' + 'transform' keys (per engine.core._resolve_connection)."""
    if isinstance(conn, str):
        return conn
    if isinstance(conn, dict):
        return conn.get("target", "")
    return ""


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
#
# `_get_font` + the wrap / measure / truncate helpers + `_paste_onto_screen_rectangle`
# now live at engine/screen.py and are imported at the top of this module
# (the names ARE the API at every call site below — no rewrites needed).


def _render_panel_to_array(
    items,
    title,
    error,
    width,
    height,
    font_size,
    bg,
    title_color,
    status_glyphs,
    status_colors,
    max_items,
    scroll_offset,
):
    bg_tuple = tuple(int(c * 255) for c in bg)
    title_tuple = tuple(int(c * 255) for c in title_color)

    img = Image.new("RGB", (width, height), color=bg_tuple)
    draw = ImageDraw.Draw(img)
    font = _get_font(font_size)
    title_font = _get_font(int(font_size * 1.15))

    margin = max(4, font_size // 3)
    line_h = font_size + 4
    y = margin

    if title:
        draw.text((margin, y), title, fill=title_tuple, font=title_font)
        y += int(font_size * 1.6)
        draw.line([(margin, y - 4), (width - margin, y - 4)], fill=title_tuple, width=1)

    if error:
        err_color = (240, 120, 120)
        for piece in _wrap(f"SOURCE ERROR: {error}", width, font_size, margin):
            if y + line_h > height - margin:
                break
            draw.text((margin, y), piece, fill=err_color, font=font)
            y += line_h
        return np.asarray(img, dtype=np.float32) / 255.0

    visible = items[scroll_offset : scroll_offset + max_items]
    for item in visible:
        if y + line_h > height - margin:
            break
        glyph = status_glyphs.get(item.get("status"), status_glyphs.get(None, "•"))
        item_color = status_colors.get(item.get("status"), status_colors.get(None, np.array([0.85, 0.85, 0.85], dtype=np.float32)))
        item_color_tuple = tuple(int(c * 255) for c in item_color)
        glyph_w = _measure(glyph + " ", font)
        draw.text((margin, y), glyph, fill=item_color_tuple, font=font)
        title_text = item.get("title", "")
        max_title_w = width - margin - int(glyph_w) - margin
        if _measure(title_text, font) > max_title_w:
            title_text = _truncate(title_text, max_title_w, font)
        draw.text((margin + int(glyph_w), y), title_text, fill=title_tuple, font=font)
        y += line_h

    return np.asarray(img, dtype=np.float32) / 255.0


def _render_expanded_to_array(
    item,
    title,
    width,
    height,
    font_size,
    bg,
    title_color,
    status_glyphs,
    status_colors,
):
    """
    Single-item detail view: title at top, status glyph + status label,
    full body word-wrapped, meta dict rendered as key:value lines, and
    a closing hint pointing at the collapse verb. Fills the same
    screen-rectangle as the list view.
    """
    bg_tuple = tuple(int(c * 255) for c in bg)
    title_tuple = tuple(int(c * 255) for c in title_color)
    hint_tuple = tuple(int(c * 200) for c in title_color)

    img = Image.new("RGB", (width, height), color=bg_tuple)
    draw = ImageDraw.Draw(img)
    font = _get_font(font_size)
    title_font = _get_font(int(font_size * 1.15))
    item_title_font = _get_font(int(font_size * 1.3))

    margin = max(4, font_size // 3)
    line_h = font_size + 4
    y = margin

    panel_title = title or "(untitled list)"
    draw.text((margin, y), panel_title, fill=title_tuple, font=title_font)
    y += int(font_size * 1.6)
    draw.line([(margin, y - 4), (width - margin, y - 4)], fill=title_tuple, width=1)
    y += margin // 2

    status = item.get("status")
    glyph = status_glyphs.get(status, status_glyphs.get(None, "•"))
    item_color = status_colors.get(
        status,
        status_colors.get(None, np.array([0.85, 0.85, 0.85], dtype=np.float32)),
    )
    item_color_tuple = tuple(int(c * 255) for c in item_color)

    item_title = item.get("title", "")
    glyph_w = _measure(glyph + " ", item_title_font)
    draw.text((margin, y), glyph, fill=item_color_tuple, font=item_title_font)
    title_max_w = width - margin - int(glyph_w) - margin
    rendered_title = item_title
    if _measure(rendered_title, item_title_font) > title_max_w:
        rendered_title = _truncate(rendered_title, title_max_w, item_title_font)
    draw.text(
        (margin + int(glyph_w), y),
        rendered_title,
        fill=title_tuple,
        font=item_title_font,
    )
    y += int(font_size * 1.6)

    if status:
        draw.text((margin, y), f"status: {status}", fill=item_color_tuple, font=font)
        y += line_h

    body = item.get("body", "")
    if body:
        y += margin // 2
        for piece in _wrap(body, width, font_size, margin):
            if y + line_h > height - margin * 2:
                break
            draw.text((margin, y), piece, fill=title_tuple, font=font)
            y += line_h

    meta = item.get("meta", {}) or {}
    if meta and y + line_h <= height - margin * 2:
        y += margin // 2
        for key, value in meta.items():
            line = f"{key}: {value}"
            if y + line_h > height - margin * 2:
                break
            if _measure(line, font) > width - 2 * margin:
                line = _truncate(line, width - 2 * margin, font)
            draw.text((margin, y), line, fill=item_color_tuple, font=font)
            y += line_h

    hint = "press 'collapse' to return"
    hint_w = _measure(hint, font)
    draw.text(
        (max(margin, width - margin - int(hint_w)), height - margin - line_h),
        hint,
        fill=hint_tuple,
        font=font,
    )

    return np.asarray(img, dtype=np.float32) / 255.0


# `_wrap`, `_measure`, `_truncate`, `_paste_onto_screen_rectangle` are imported
# from engine/screen.py at the top of this module (brief 03 commit 1 extraction).
