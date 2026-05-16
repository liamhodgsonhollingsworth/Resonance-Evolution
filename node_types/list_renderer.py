"""
ListRenderer — owns a screen rectangle in the outer world; consumes an
`items` channel from a connected DataSource; draws a vertical list with
status glyphs and titles.

Half of the Tier A primitive pair (DataSource + Renderer). Together they
generalize all of Tier A and most of Tier C — a new panel is one source
plus one renderer plus a connection, no new node-types needed.

Item shape consumed (per node_types/parsers/__init__.py):

    {"id": str, "title": str, "body": str, "status": str | None, "meta": dict}

Status-to-glyph map and status-to-color map are exposed as params so
each panel instance can override (Tasks use [ ]/[x]/[~]; Wishes use
status words like pending/granted; Ideas use queue/resolved).

The screen-rectangle paste shares its primitive shape with
ChatInterface and Computer — same ray-cast + UV-sample pattern. Future
extraction of `_paste_onto_screen_rectangle` into a shared
`engine/screen.py` helper would unify the three (the feasibility
subagent flagged this as recommended-but-not-required).
"""

from typing import Dict, List

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from engine.node import Channels, EmitContext, Manifest, View


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
    lines = [f"ListRenderer({title}): {len(items)} items"]
    for item in items[:20]:
        glyph = state["status_glyphs"].get(item.get("status"), state["status_glyphs"].get(None, "•"))
        lines.append(f"  {glyph} {item.get('title', '')}  [id={item.get('id', '?')}]")
    if len(items) > 20:
        lines.append(f"  ... and {len(items) - 20} more")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# items-channel reading
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

def _get_font(size: int):
    for name in ("arial.ttf", "Arial.ttf", "DejaVuSans.ttf", "FreeMono.ttf", "Courier.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except (IOError, OSError):
            continue
    return ImageFont.load_default()


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


def _wrap(text, width, font_size, margin):
    max_chars = max(10, (width - 2 * margin) // (font_size // 2))
    line = ""
    for word in text.split(" "):
        if not line:
            line = word
        elif len(line) + 1 + len(word) <= max_chars:
            line += " " + word
        else:
            yield line
            line = word
    if line:
        yield line


def _measure(text, font) -> int:
    if hasattr(font, "getlength"):
        return int(font.getlength(text))
    if hasattr(font, "getsize"):
        return int(font.getsize(text)[0])
    return len(text) * 7  # crude fallback


def _truncate(text, max_w, font) -> str:
    for i in range(len(text), 0, -1):
        candidate = text[:i] + "…"
        if _measure(candidate, font) <= max_w:
            return candidate
    return ""


# ---------------------------------------------------------------------------
# screen-rectangle paste (shared shape with chat_interface.py + computer.py)
# ---------------------------------------------------------------------------

def _paste_onto_screen_rectangle(view: View, screen_w: float, screen_h: float,
                                 internal_color: np.ndarray) -> Channels:
    out_w, out_h = view.width, view.height
    half_h = np.tan(view.fov_y_radians / 2)
    half_w_view = half_h * view.aspect()
    xs = np.linspace(-1.0, 1.0, out_w) * half_w_view
    ys = np.linspace(1.0, -1.0, out_h) * half_h
    gx, gy = np.meshgrid(xs, ys)
    dirs_cam = np.stack([gx, gy, -np.ones_like(gx)], axis=-1)
    dirs_cam = dirs_cam / np.linalg.norm(dirs_cam, axis=-1, keepdims=True)
    dirs_world = dirs_cam @ view.orientation.T

    origin = view.position
    eps = 1e-9
    safe_dz = np.where(np.abs(dirs_world[..., 2]) < eps,
                       eps * np.sign(dirs_world[..., 2] + eps),
                       dirs_world[..., 2])
    t = -origin[2] / safe_dz
    x_hit = origin[0] + t * dirs_world[..., 0]
    y_hit = origin[1] + t * dirs_world[..., 1]
    inside = (t > 0) & (np.abs(x_hit) <= screen_w / 2.0) & (np.abs(y_hit) <= screen_h / 2.0)

    color_out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    depth_out = np.full((out_h, out_w), np.inf, dtype=np.float32)

    int_h, int_w = internal_color.shape[:2]
    u = (x_hit + screen_w / 2.0) / screen_w
    v = 1.0 - (y_hit + screen_h / 2.0) / screen_h
    sample_x = np.clip((u * int_w).astype(int), 0, int_w - 1)
    sample_y = np.clip((v * int_h).astype(int), 0, int_h - 1)
    sampled = internal_color[sample_y, sample_x]
    color_out = np.where(inside[..., None], sampled, color_out)
    depth_out = np.where(inside, t.astype(np.float32), depth_out)

    return {"color": color_out, "depth": depth_out}
