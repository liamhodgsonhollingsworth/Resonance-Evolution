"""
ChatInterface — a screen in the outer world that displays the contents
of a conversation log file. The "side channel" to Claude Code is the
file itself: an external LLM session reads it (to know what was said)
and writes to it (to add new turns); the node just visualizes the
current contents.

Demonstrates the artist-authoring-loop pattern with Claude Code as a
node inside the system being built — closes the self-referential loop
without requiring any Claude API integration in the engine.

Architectural commitment: a node whose state is a file. The graph
references files as plain-text sources. Future Claude Code sessions
read/write the file independently; the engine just re-reads on each
emit. v2 can add a file-watcher to trigger re-renders when the log
changes.

For text rendering, PIL's ImageDraw is used with a sensible fallback
chain: ImageFont.truetype on common system fonts, then load_default.
"""

from pathlib import Path
from typing import List

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="ChatInterface",
        version="1.0",
        renderer_id="raster",
        inputs={
            "log_path": "string",
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            "font_size": "int",
            "text_color": "vec3",
            "background_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "A screen displaying the contents of a chat log file. "
            "External LLM sessions edit the file as side-channel "
            "authoring; the node visualizes the current contents."
        ),
    )


def build(params):
    return {
        "log_path": str(params.get("log_path", "logs/sample_chat.txt")),
        "screen_width": float(params.get("screen_width", 4.0)),
        "screen_height": float(params.get("screen_height", 3.0)),
        "screen_resolution": int(params.get("screen_resolution", 256)),
        "font_size": int(params.get("font_size", 16)),
        "text_color": np.asarray(params.get("text_color", [0.92, 0.92, 0.88]), dtype=np.float32),
        "background_color": np.asarray(params.get("background_color", [0.10, 0.11, 0.16]), dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    # ChatInterface has no children to render — it draws text from a file.
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    out_w, out_h = view.width, view.height
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

    log_text = _read_log(state["log_path"])
    text_image = _render_text_to_array(
        log_text,
        width=screen_w_px,
        height=screen_h_px,
        font_size=state["font_size"],
        text_color=state["text_color"],
        background_color=state["background_color"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=text_image,
    )


def describe(state, ctx: EmitContext) -> str:
    return (f"ChatInterface id={ctx.node.id} "
            f"log={state['log_path']} "
            f"screen={state['screen_width']:.2f}x{state['screen_height']:.2f}")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _read_log(log_path: str) -> str:
    p = Path(log_path)
    if not p.exists():
        return "(log file not found: " + log_path + ")"
    try:
        return p.read_text(encoding="utf-8")
    except OSError as e:
        return f"(failed to read log: {e})"


def _get_font(size: int):
    """Try a few common system fonts; fall back to PIL's default."""
    for name in ("arial.ttf", "Arial.ttf", "DejaVuSans.ttf", "FreeMono.ttf", "Courier.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except (IOError, OSError):
            continue
    return ImageFont.load_default()


def _render_text_to_array(text: str, width: int, height: int, font_size: int,
                          text_color: np.ndarray, background_color: np.ndarray) -> np.ndarray:
    """Render `text` to an RGB numpy array of shape (height, width, 3) in [0,1]."""
    bg = tuple(int(c * 255) for c in background_color)
    fg = tuple(int(c * 255) for c in text_color)
    img = Image.new("RGB", (width, height), color=bg)
    draw = ImageDraw.Draw(img)
    font = _get_font(font_size)

    margin = max(4, font_size // 3)
    line_height = font_size + 4
    max_chars_per_line = max(10, (width - 2 * margin) // (font_size // 2))

    y = margin
    for raw_line in text.splitlines():
        # Soft-wrap long lines
        for piece in _wrap_line(raw_line, max_chars_per_line):
            if y + line_height > height - margin:
                break
            draw.text((margin, y), piece, fill=fg, font=font)
            y += line_height
        if y + line_height > height - margin:
            break

    arr = np.asarray(img, dtype=np.float32) / 255.0
    return arr


def _wrap_line(line: str, max_chars: int):
    if len(line) <= max_chars:
        yield line
        return
    words = line.split(" ")
    cur = ""
    for w in words:
        if not cur:
            cur = w
        elif len(cur) + 1 + len(w) <= max_chars:
            cur = cur + " " + w
        else:
            yield cur
            cur = w
    if cur:
        yield cur


def _paste_onto_screen_rectangle(view: View, screen_w: float, screen_h: float,
                                 internal_color: np.ndarray) -> Channels:
    """Ray-cast outer view against the screen rectangle in the XY plane at
    z=0; UV-sample internal_color onto inside-screen pixels. Same
    primitive as Computer/Portal — factored here when ChatInterface and
    other text-displaying nodes need it. Future: lift into a shared
    helper module."""
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
