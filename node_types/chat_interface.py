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
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
# Shared text-rendering + screen-paste helpers — extracted from this module
# (and list_renderer.py + computer.py) into engine/screen.py per brief 03
# commit 1 of the Resonance website implementation arc. The names ARE the
# API; importing them under the same names preserves every existing call
# site verbatim. See engine/screen.py docstring + tests/test_engine_screen.py
# for the regression contract.
from engine.screen import (
    _get_font,
    _paste_onto_screen_rectangle,
    _render_text_to_array,
    _wrap_line,
)


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


# `_get_font`, `_render_text_to_array`, `_wrap_line`, `_paste_onto_screen_rectangle`
# now live at engine/screen.py and are imported at the top of this module
# (brief 03 commit 1 extraction; names ARE the API at every call site below).
