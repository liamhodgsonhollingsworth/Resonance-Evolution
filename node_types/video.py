"""VideoNode — video content primitive (N-F026 / SPEC-090).

Brief 03 commit 4 of the Resonance website implementation arc — the
second of the two content primitives this commit ships (alongside
``ImageNode``). The functional contract per the per-module plan's
N-F026 spec:

  - **Inputs (manifest):** ``src`` (string — file path or URL),
    ``alt_text`` (string), ``width``, ``height`` (int — pixel sizes
    requested for layout), ``autoplay`` (bool, default False),
    ``loop`` (bool, default False), ``controls`` (bool, default True),
    ``screen_width``, ``screen_height``, ``screen_resolution`` (the
    world-space geometry shared with the other primitives), ``layer``
    (int, SPEC-094), ``displayed_by`` (string), ``placeholder_color``
    (vec3).
  - **Outputs:** ``color``, ``depth`` (raster pair via
    ``_paste_onto_screen_rectangle``).
  - **Verbs (handle_action):** ``play``, ``pause``, ``set_loop``,
    ``set_controls`` — playback-state writes for the HTML variant the
    Resonance-Website surface will eventually expose. Raster emit is
    static (the first-frame preview); the playback verbs persist
    state that the HTML variant consumes verbatim.

Functional/visual split per Decision A1: VideoNode is the FUNCTIONAL
node carrying source + playback state. The raster ``emit()`` here
is the first-frame preview (per the per-module plan N-F026 interface
note: *"raster emit produces the first frame"*). The HTML variant
``video_default_v1`` produces a real ``<video>`` element consuming
the same playback state. Both compose through the same
``displayed_by`` slot.

First-frame caching: per the per-module plan N-F026 risk-mitigation
note (*"cache the first frame per src at Apeiron/state/video_first_
frames/"*), this primitive caches the extracted first frame so
repeated emits don't re-decode the video. Cache key is the source
path's POSIX form. Cache directory is created on first use.

Composition contract (per existing-primitives audit + mistake #009):

  - ``engine/screen.py`` — paste-onto-screen-rectangle (brief 03
    commit 1 extraction).
  - PIL for first-frame extraction (Pillow does NOT decode video; the
    primitive uses imageio when available, falls back to a poster
    placeholder when missing). The OPTIONAL dependency keeps the
    raster emit honest about its capabilities without hard-failing
    the test suite (CI runs without imageio installed).
  - BoxNode geometry conventions (commit 2).

Missing-codec behavior: when imageio is unavailable or fails to
decode the source, VideoNode renders the placeholder color +
``alt_text`` overlay (the HTML variant handles the real playback
through ``<video src="...">``). The describe() output names the
codec resolution state so the text-API driver surfaces the failure
clearly.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image, ImageDraw

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _get_font, _paste_onto_screen_rectangle


logger = logging.getLogger(__name__)


DEFAULT_W_WORLD = 2.4
DEFAULT_H_WORLD = 1.35  # 16:9-ish
DEFAULT_RESOLUTION_PX = 256
DEFAULT_LAYER = 0

# First-frame cache directory (created lazily on first write). Path is
# relative to the Apeiron root resolved via the engine's working dir.
FIRST_FRAME_CACHE_DIRNAME = "state/video_first_frames"


def manifest() -> Manifest:
    return Manifest(
        name="VideoNode",
        version="1.0",
        renderer_id="raster",
        inputs={
            # World-space geometry (shared with BoxNode + control
            # primitives so the paste pipeline composes uniformly).
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            # Functional state (the "function" half of Decision A1).
            "src": "string",
            "alt_text": "string",
            "width": "int",
            "height": "int",
            "autoplay": "bool",
            "loop": "bool",
            "controls": "bool",
            # Z-order + visual-variant override.
            "layer": "int",
            "displayed_by": "string",
            # Placeholder rendered when src is missing / undecodable.
            "placeholder_color": "vec3",
            "text_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Video content primitive (N-F026). Functional state lives "
            "here (src/autoplay/loop/controls); visual variants live "
            "as kind:renderer nodes naming presentation-of: VideoNode "
            "(Decision A1). Raster emit is the first-frame preview; "
            "HTML variant produces a <video> element consuming the "
            "same playback state."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    placeholder = params.get("placeholder_color")
    if placeholder is None:
        placeholder = [0.10, 0.10, 0.13]
    text_color = params.get("text_color")
    if text_color is None:
        text_color = [0.78, 0.80, 0.82]

    autoplay = bool(params.get("autoplay") or False)
    loop = bool(params.get("loop") or False)
    controls_raw = params.get("controls")
    controls = True if controls_raw is None else bool(controls_raw)

    return {
        "screen_width": float(params.get("screen_width") or DEFAULT_W_WORLD),
        "screen_height": float(params.get("screen_height") or DEFAULT_H_WORLD),
        "screen_resolution": int(
            params.get("screen_resolution") or DEFAULT_RESOLUTION_PX
        ),
        "src": str(params.get("src") or ""),
        "alt_text": str(params.get("alt_text") or ""),
        "width": int(params.get("width") or 0),
        "height": int(params.get("height") or 0),
        "autoplay": autoplay,
        "loop": loop,
        "controls": controls,
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "displayed_by": str(params.get("displayed_by") or ""),
        "placeholder_color": np.asarray(placeholder, dtype=np.float32),
        "text_color": np.asarray(text_color, dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Video has no rendered children — content primitive leaf."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render the first-frame preview (or placeholder) onto the screen
    rectangle.

    The default ``emit()`` is the equivalent of the ``video_default_v1``
    visual variant for the raster surface. The HTML variant produces a
    ``<video>`` element consuming the same playback state.
    """
    screen_w_world = state["screen_width"]
    screen_h_world = state["screen_height"]
    res_max = state["screen_resolution"]

    aspect = screen_w_world / max(1e-9, screen_h_world)
    if aspect >= 1.0:
        screen_w_px = res_max
        screen_h_px = max(1, int(round(res_max / aspect)))
    else:
        screen_h_px = res_max
        screen_w_px = max(1, int(round(res_max * aspect)))

    internal = _resolve_video_first_frame(
        src=state.get("src") or "",
        alt_text=state.get("alt_text") or "",
        width=screen_w_px,
        height=screen_h_px,
        placeholder_color=state["placeholder_color"],
        text_color=state["text_color"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API."""
    src = state.get("src") or "(empty)"
    alt = state.get("alt_text") or "(no alt)"
    autoplay = state.get("autoplay", False)
    loop = state.get("loop", False)
    controls = state.get("controls", True)
    layer = state.get("layer", 0)
    displayed_by = state.get("displayed_by") or "(default)"
    src_state = _src_state(state.get("src") or "")
    return (
        f"VideoNode id={ctx.node.id} "
        f"src={src!r} src_state={src_state} alt={alt!r} "
        f"autoplay={autoplay} loop={loop} controls={controls} "
        f"layer={layer} displayed_by={displayed_by}"
    )


# ---------------------------------------------------------------------------
# Verb dispatch (play / pause / set_loop / set_controls)
# ---------------------------------------------------------------------------


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "play":
        previous = state.get("autoplay", False)
        state["autoplay"] = True
        return {"autoplay": True,
                "last_play": {"set": True, "previous": previous}}

    if action_name == "pause":
        previous = state.get("autoplay", False)
        state["autoplay"] = False
        return {"autoplay": False,
                "last_pause": {"set": True, "previous": previous}}

    if action_name == "set_loop":
        try:
            loop = bool(payload.get("value"))
        except (TypeError, ValueError):
            return {"last_set_loop": {"set": False,
                                       "reason": "value must be bool"}}
        previous = state.get("loop", False)
        state["loop"] = loop
        return {"loop": loop,
                "last_set_loop": {"set": True, "value": loop,
                                   "previous": previous}}

    if action_name == "set_controls":
        try:
            controls = bool(payload.get("value"))
        except (TypeError, ValueError):
            return {"last_set_controls": {"set": False,
                                           "reason": "value must be bool"}}
        previous = state.get("controls", True)
        state["controls"] = controls
        return {"controls": controls,
                "last_set_controls": {"set": True, "value": controls,
                                       "previous": previous}}

    return None


# ---------------------------------------------------------------------------
# Internal: video resolution + first-frame extraction
# ---------------------------------------------------------------------------


def _src_state(src: str) -> str:
    """Classify ``src`` into one of the resolution states."""
    if not src:
        return "empty"
    if src.startswith(("http://", "https://")):
        return "url-deferred"
    try:
        path = Path(src)
    except (TypeError, ValueError):
        return "invalid"
    if not path.exists():
        return "missing"
    return "file"


def _resolve_video_first_frame(
    src: str,
    alt_text: str,
    width: int,
    height: int,
    placeholder_color: np.ndarray,
    text_color: np.ndarray,
) -> np.ndarray:
    """Resolve ``src`` to a first-frame RGB float32 array.

    Resolution strategy mirrors ImageNode:
      - Empty src → placeholder + alt-text overlay.
      - URL → placeholder + alt-text overlay + deferred-fetch log.
      - File path → try imageio; fall back to placeholder on missing
        dependency or decode failure.
      - Result cached at ``state/video_first_frames/<safe_name>.png``.
    """
    if width <= 0:
        width = 1
    if height <= 0:
        height = 1

    if not src:
        return _placeholder_with_alt(width, height, alt_text, placeholder_color, text_color)

    if src.startswith(("http://", "https://")):
        logger.warning(
            "VideoNode URL first-frame fetch deferred: %s", src,
        )
        return _placeholder_with_alt(width, height, alt_text, placeholder_color, text_color)

    try:
        path = Path(src)
    except (TypeError, ValueError):
        logger.warning("VideoNode src is not a valid path: %r", src)
        return _placeholder_with_alt(width, height, alt_text, placeholder_color, text_color)

    if not path.exists():
        logger.warning("VideoNode src missing on disk: %s", src)
        return _placeholder_with_alt(width, height, alt_text, placeholder_color, text_color)

    # Try the cache before invoking the decoder.
    cached = _read_cached_first_frame(path, width, height)
    if cached is not None:
        return cached

    try:
        # imageio is optional; the import lives inside the function so
        # the module imports cleanly when imageio is missing (test CI).
        import imageio.v3 as iio  # type: ignore
        first_frame = iio.imread(path, index=0)  # type: ignore[arg-type]
        if first_frame is None:
            raise ValueError("imageio returned None for first frame")
        # imageio returns uint8 HWC; convert to RGB float32 normalized.
        if first_frame.ndim == 2:
            first_frame = np.stack([first_frame] * 3, axis=-1)
        if first_frame.shape[-1] == 4:
            first_frame = first_frame[..., :3]
        # Resize to requested dimensions via PIL.
        pil = Image.fromarray(first_frame.astype(np.uint8))
        pil = pil.resize((width, height), Image.LANCZOS)
        arr = np.asarray(pil, dtype=np.float32) / 255.0
        _write_cached_first_frame(path, arr)
        return arr
    except ImportError:
        logger.warning(
            "VideoNode first-frame decode skipped (imageio not installed); "
            "using placeholder for %s", src,
        )
        return _placeholder_with_alt(width, height, alt_text, placeholder_color, text_color)
    except Exception as exc:  # noqa: BLE001
        logger.warning("VideoNode failed to decode %s: %s", src, exc)
        return _placeholder_with_alt(width, height, alt_text, placeholder_color, text_color)


def _placeholder_with_alt(
    width: int,
    height: int,
    alt_text: str,
    placeholder_color: np.ndarray,
    text_color: np.ndarray,
) -> np.ndarray:
    """Placeholder rectangle + optional alt-text overlay. The overlay is
    centered so HTML/raster placeholders stay readable when the video
    source isn't yet available.
    """
    bg_tuple = tuple(
        int(max(0.0, min(1.0, float(c))) * 255) for c in placeholder_color
    )
    text_tuple = tuple(
        int(max(0.0, min(1.0, float(c))) * 255) for c in text_color
    )
    img = Image.new("RGB", (width, height), color=bg_tuple)
    if alt_text:
        draw = ImageDraw.Draw(img)
        # Small font; the overlay is for orientation, not reading-text.
        font_size = max(10, min(24, height // 8))
        font = _get_font(font_size)
        # Crude centering by width-estimate; precise centering is
        # variant-owned and not necessary in the placeholder fallback.
        margin = max(4, font_size // 2)
        text_y = max(0, (height - font_size) // 2)
        # Limit overlay to one line; alt-text wrapping is variant
        # territory.
        truncated = alt_text if len(alt_text) <= 32 else alt_text[:31] + "…"
        draw.text((margin, text_y), truncated, fill=text_tuple, font=font)
    return np.asarray(img, dtype=np.float32) / 255.0


def _cache_key(path: Path, width: int, height: int) -> str:
    """Deterministic cache key for the first-frame PNG. Width/height in
    the key so resizes don't reuse stale cached arrays."""
    safe = (
        path.as_posix()
        .replace(":", "_")
        .replace("/", "_")
        .replace("\\", "_")
        .replace(" ", "_")
    )
    return f"{safe}__{width}x{height}.png"


def _cache_dir() -> Path:
    """Resolve the cache directory relative to the Apeiron root. The
    root is discovered by walking upward from this file until we find
    ``node_types`` (which is this file's parent), then choosing the
    sibling ``state/video_first_frames``.
    """
    here = Path(__file__).resolve().parent  # node_types/
    root = here.parent  # Apeiron/
    return root / FIRST_FRAME_CACHE_DIRNAME


def _read_cached_first_frame(
    path: Path, width: int, height: int,
) -> Optional[np.ndarray]:
    cache_dir = _cache_dir()
    cache_path = cache_dir / _cache_key(path, width, height)
    if not cache_path.exists():
        return None
    try:
        with Image.open(cache_path) as pil:
            pil = pil.convert("RGB")
            return np.asarray(pil, dtype=np.float32) / 255.0
    except Exception as exc:  # noqa: BLE001
        logger.warning("VideoNode cache read failed (%s): %s",
                       cache_path, exc)
        return None


def _write_cached_first_frame(path: Path, arr: np.ndarray) -> None:
    cache_dir = _cache_dir()
    try:
        cache_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        logger.warning("VideoNode cache dir mkdir failed (%s): %s",
                       cache_dir, exc)
        return
    height, width = arr.shape[:2]
    cache_path = cache_dir / _cache_key(path, width, height)
    try:
        # Convert back to uint8 for PNG persistence.
        as_u8 = np.clip(arr * 255.0, 0, 255).astype(np.uint8)
        Image.fromarray(as_u8).save(cache_path)
    except Exception as exc:  # noqa: BLE001
        logger.warning("VideoNode cache write failed (%s): %s",
                       cache_path, exc)
