"""ImageNode — raster image primitive (N-F026 / SPEC-090).

Brief 03 commit 4 of the Resonance website implementation arc — the
first of the two content primitives this commit ships (alongside
``VideoNode``). The functional contract per the per-module plan's
N-F026 spec:

  - **Inputs (manifest):** ``src`` (string — file path or URL),
    ``alt_text`` (string), ``width``, ``height`` (int — pixel sizes
    requested for layout; 0 means "use the source's native size"),
    ``preserve_aspect`` (bool, default True), ``screen_width``,
    ``screen_height``, ``screen_resolution`` (the world-space geometry
    shared with BoxNode + ScrollBarNode + SliderNode + DropdownNode so
    the paste-onto-screen-rectangle pipeline composes uniformly),
    ``layer`` (int, SPEC-094), ``displayed_by`` (string — visual-
    variant binding per Decision A1), ``placeholder_color`` (vec3 —
    rendered when ``src`` is missing or unreadable).
  - **Outputs:** ``color``, ``depth`` (raster pair via
    ``_paste_onto_screen_rectangle`` — same paste pipeline as the
    other primitives).
  - **Verbs (handle_action):** none; ImageNode is a content carrier.
    The icon-attach interaction (N-F039) writes to a TARGET node's
    ``icon:`` frontmatter, not to the ImageNode itself.

Functional/visual split per Decision A1 + SPEC-090: ImageNode is the
FUNCTIONAL node carrying source + intrinsic geometry. Visual variants
live as substrate-style ``kind: renderer`` nodes naming
``presentation-of: ImageNode``. The default ``image_default_v1`` ships
in this commit; richer aesthetic variants (painterly framing,
parallax-decorated) arrive via brief 14 + later commits per the
per-module plan's Cross-cut X4.

The icon-attachment contract per Decision A4 + N-F039 + Q5:

  - Dropping an ImageNode onto any node fires the seed
    ``interaction-rule:image-onto-any → attach-as-icon`` rule
    (commit 4 ships the rule alongside the primitive).
  - The matched rule's effect-node ``attach_image_as_icon`` mutates
    the target by setting its ``icon:`` frontmatter field to a
    reference of the form ``image:<image_node_id>`` (the prefix mirrors
    the existing ``connections`` reference vocabulary).
  - The mutation is per-edit-new-node (SPEC-084) — the target's
    pre-attach version stays reachable on disk; the post-attach
    version supersedes via the substrate's ``publish()`` chain.
  - The ImageNode itself is unchanged by attachment; many targets can
    reference the same image-id without duplicating the binary.

Composition contract (per existing-primitives audit + mistake #009):

  - ``engine/screen.py`` — paste-onto-screen-rectangle (brief 03
    commit 1 extraction). ImageNode pastes the resolved image array
    onto the screen rectangle.
  - PIL ``Image.open`` for ``src`` resolution. Network URLs are NOT
    fetched at emit-time (Phase-1 expression — file paths only); the
    URL case is reserved for a future commit that wires through the
    existing transcript / vault HTTP fetch primitive once the asset
    fetch policy is decided. URLs fall back to the placeholder color
    + a structured log entry rather than blocking emit.
  - BoxNode geometry conventions (commit 2) — same world-space
    geometry + ``screen_*`` fields so the paste pipeline composes
    uniformly across primitives.

Missing-source behavior: when ``src`` is empty, the file doesn't
exist, or PIL raises on load, ImageNode renders the
``placeholder_color`` (default a soft slate) at the configured
geometry. The describe() output names the failure mode so the text-
API driver surfaces the resolution failure clearly.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

import numpy as np
from PIL import Image

from engine.node import Channels, EmitContext, Manifest, View
from engine.screen import _paste_onto_screen_rectangle


logger = logging.getLogger(__name__)


DEFAULT_W_WORLD = 2.0
DEFAULT_H_WORLD = 2.0
DEFAULT_RESOLUTION_PX = 256
DEFAULT_LAYER = 0


def manifest() -> Manifest:
    return Manifest(
        name="ImageNode",
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
            "preserve_aspect": "bool",
            # Z-order + visual-variant override.
            "layer": "int",
            "displayed_by": "string",
            # Placeholder rendered when src is missing / unreadable.
            "placeholder_color": "vec3",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Image content primitive (N-F026). Functional state lives "
            "here (src/alt_text/width/height/preserve_aspect); visual "
            "variants live as kind:renderer nodes naming presentation-"
            "of: ImageNode (Decision A1). Drops onto any target fire "
            "the seed interaction-rule:image-onto-any rule which "
            "attaches the image as the target's icon (N-F039 / Q5)."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    placeholder = params.get("placeholder_color")
    if placeholder is None:
        # Soft slate so the placeholder reads as "intentional empty"
        # rather than "broken". Variants may override via the
        # primitive_state passthrough.
        placeholder = [0.18, 0.20, 0.26]

    preserve_aspect_raw = params.get("preserve_aspect")
    if preserve_aspect_raw is None:
        preserve_aspect = True
    else:
        preserve_aspect = bool(preserve_aspect_raw)

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
        "preserve_aspect": preserve_aspect,
        "layer": int(params.get("layer") or DEFAULT_LAYER),
        "displayed_by": str(params.get("displayed_by") or ""),
        "placeholder_color": np.asarray(placeholder, dtype=np.float32),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """Images have no rendered children — they're a leaf content
    primitive. Drop targets are SIBLING nodes wired via interaction-
    rules (per the icon-attach contract)."""
    return []


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Render the image (or placeholder) onto the screen rectangle.

    The default ``emit()`` is the equivalent of the
    ``image_default_v1`` visual variant — adequate when no
    ``displayed_by`` variant is set. Visual variants override by
    registering as ``kind: renderer`` substrate nodes the surface
    dispatches via the substrate's ``_execute_renderer`` handler.
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

    internal = _resolve_image_to_array(
        src=state.get("src") or "",
        width=screen_w_px,
        height=screen_h_px,
        preserve_aspect=bool(state.get("preserve_aspect", True)),
        placeholder_color=state["placeholder_color"],
    )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=screen_w_world,
        screen_h=screen_h_world,
        internal_color=internal,
    )


def describe(state, ctx: EmitContext) -> str:
    """One-line summary for the text-API (Scenario 10 enumeration)."""
    src = state.get("src") or "(empty)"
    alt = state.get("alt_text") or "(no alt)"
    width = state.get("width") or 0
    height = state.get("height") or 0
    preserve = state.get("preserve_aspect", True)
    layer = state.get("layer", 0)
    displayed_by = state.get("displayed_by") or "(default)"
    # Resolved? Surface the resolved/unresolved state so the LLM-driver
    # notices missing sources without rendering.
    src_state = _src_state(state.get("src") or "")
    return (
        f"ImageNode id={ctx.node.id} "
        f"src={src!r} src_state={src_state} alt={alt!r} "
        f"requested_size=({width}x{height}) "
        f"preserve_aspect={preserve} layer={layer} "
        f"displayed_by={displayed_by}"
    )


# ---------------------------------------------------------------------------
# Internal: image resolution + raster
# ---------------------------------------------------------------------------


def _src_state(src: str) -> str:
    """Classify ``src`` into one of the four resolution states the
    text-API uses for diagnostics. Pure — no side effects, no I/O.
    """
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


def _resolve_image_to_array(
    src: str,
    width: int,
    height: int,
    preserve_aspect: bool,
    placeholder_color: np.ndarray,
) -> np.ndarray:
    """Resolve ``src`` to an RGB float32 array of shape (height, width, 3)
    in [0, 1].

    Resolution strategy:
      - Empty src → placeholder color filling the rectangle.
      - http(s):// URL → placeholder + structured log warning. URL fetch
        is reserved for a follow-up commit per the per-module plan's
        N-F026 risk-mitigation note (network fetch policy + cache).
      - File path → PIL load; resize honoring ``preserve_aspect``;
        center on the placeholder background to preserve aspect when
        the image's intrinsic ratio differs from the requested size.
      - Load failure → placeholder + log warning.

    The placeholder + log pattern matches the plug-and-play default
    (SPEC-092 — never block on missing input; always produce a
    visible result + a debuggable log entry).
    """
    if width <= 0:
        width = 1
    if height <= 0:
        height = 1

    placeholder_rgb = _placeholder_array(width, height, placeholder_color)

    if not src:
        return placeholder_rgb

    if src.startswith(("http://", "https://")):
        logger.warning(
            "ImageNode URL fetch deferred (no network primitive wired): %s",
            src,
        )
        return placeholder_rgb

    try:
        path = Path(src)
    except (TypeError, ValueError):
        logger.warning("ImageNode src is not a valid path: %r", src)
        return placeholder_rgb

    if not path.exists():
        logger.warning("ImageNode src missing on disk: %s", src)
        return placeholder_rgb

    try:
        with Image.open(path) as pil_img:
            pil_img = pil_img.convert("RGB")
            if preserve_aspect:
                # Compute the largest inscribed box that preserves the
                # image's intrinsic aspect within (width, height).
                src_w, src_h = pil_img.size
                src_aspect = src_w / max(1, src_h)
                req_aspect = width / max(1, height)
                if src_aspect >= req_aspect:
                    # Source is wider than target — fit width.
                    fit_w = width
                    fit_h = max(1, int(round(width / src_aspect)))
                else:
                    fit_h = height
                    fit_w = max(1, int(round(height * src_aspect)))
                resized = pil_img.resize((fit_w, fit_h), Image.LANCZOS)
                # Center on the placeholder background so the
                # non-image region renders the placeholder color
                # rather than black/transparent.
                composite = Image.new(
                    "RGB",
                    (width, height),
                    color=tuple(
                        int(max(0.0, min(1.0, float(c))) * 255)
                        for c in placeholder_color
                    ),
                )
                paste_x = (width - fit_w) // 2
                paste_y = (height - fit_h) // 2
                composite.paste(resized, (paste_x, paste_y))
                arr = np.asarray(composite, dtype=np.float32) / 255.0
            else:
                resized = pil_img.resize((width, height), Image.LANCZOS)
                arr = np.asarray(resized, dtype=np.float32) / 255.0
            return arr
    except Exception as exc:  # noqa: BLE001 — PIL raises many types
        logger.warning("ImageNode failed to load %s: %s", src, exc)
        return placeholder_rgb


def _placeholder_array(width: int, height: int, color: np.ndarray) -> np.ndarray:
    """Render a flat-color rectangle as the placeholder. Used for
    empty / missing / unreadable sources.

    The placeholder is a visible-but-quiet rectangle the maintainer
    can use to compose layouts before binding real assets.
    """
    rgb = np.asarray(color, dtype=np.float32)
    rgb = np.clip(rgb, 0.0, 1.0)
    out = np.empty((height, width, 3), dtype=np.float32)
    out[..., 0] = rgb[0]
    out[..., 1] = rgb[1]
    out[..., 2] = rgb[2]
    return out
