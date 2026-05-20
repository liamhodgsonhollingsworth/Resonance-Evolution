"""
BrowserRenderer — a screen-rectangle owner that displays a web page
(URL or HTML string) onto its scene region. SPEC-066.

Composes with the existing screen-rectangle pattern
(ChatInterface, Computer, ListRenderer): the node owns both an
outer-world rectangle and the camera/content that fills it. The
content comes from a ``tkinterweb`` HtmlFrame at the 2D surface (GUI
shell ``web`` view kind) and from a precomputed bitmap at the 3D
surface (Playwright headless raster, optional via the
``apeiron[browser-3d]`` extra).

Two source modes
----------------

* **URL mode** (``url`` param non-empty): tkinterweb / Playwright
  fetch the URL and render the result.
* **HTML override** (``html_string`` param non-empty): render the
  provided HTML directly with no network I/O. Useful for tests +
  for the maintainer's "render a local snippet" use case. If both
  ``url`` and ``html_string`` are provided, ``html_string`` wins —
  the maintainer's explicit override beats the URL.

V1 surface — 2D path
--------------------

The GUI shell's ``web`` view kind packs an ``HtmlFrame`` inside the
panel host at the node's ViewSpec position; ``BrowserRenderer.emit()``
returns transparent channels (the widget paints itself directly via
Tk). This mirrors how the 3D tab's realtime renderer paints into the
central pane without going through the engine's raster path.

V1 surface — 3D path
--------------------

Optional. When Playwright is installed, the ``precompute_hook``
launches a headless Chromium, captures a screenshot, and caches it
under ``engine.cache[node.id]['bitmap']``. ``emit()`` then UV-samples
that bitmap onto the screen rectangle using the same
``_paste_onto_screen_rectangle`` primitive ListRenderer / ChatInterface
use.

Missing Playwright + URL mode in 3D = a single-colour rect with the
status message in describe(). Graceful degrade, never crashes.

Trust gate composition (SPEC-054)
---------------------------------

This file lives at ``node_types/browser_renderer.py`` — inside the
default render-trust patterns ``node_types/*.py``. So a paste of a
``BrowserRenderer`` node will discover + spawn successfully when the
file is present locally. A paste from an UNTRUSTED source (e.g.
external repo not in the trust set) is gated by the engine's
``discover()`` flow before this module is even imported. The trust
gate is composed at the engine level, not bypassed here.

Refresh policy
--------------

``refresh_seconds=0`` (default): precompute on initial load + on the
text-API ``browser-refresh`` verb. Non-zero values are reserved for a
follow-up SPEC that adds a per-node refresh thread; v1 does not
spawn background threads.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="BrowserRenderer",
        version="1.0",
        renderer_id="raster",
        inputs={
            "url": "string",
            "html_string": "string",
            "screen_width": "float",
            "screen_height": "float",
            "screen_resolution": "int",
            "viewport_width": "int",
            "viewport_height": "int",
            "refresh_seconds": "float",
            "background_color": "vec3",
            "backend": "string",
        },
        outputs={"color": "rgb_image", "depth": "depth_image"},
        description=(
            "Embeds a web page (URL or inline HTML) into a screen "
            "rectangle. 2D path uses tkinterweb's HtmlFrame; 3D path "
            "uses an optional Playwright bitmap (apeiron[browser-3d]). "
            "Composes with the SPEC-054 render-trust gate."
        ),
    )


def build(params):
    """Validate + normalize params. ``url`` AND ``html_string`` are
    both accepted; if both are non-empty, ``html_string`` wins (the
    explicit override beats the network fetch).

    ``viewport_width`` / ``viewport_height`` default to 1280x800 — the
    canonical "preview a local dev server" viewport size. Maintainers
    iterating on a mobile layout can override per-node.
    """
    return {
        "url": str(params.get("url", "") or ""),
        "html_string": str(params.get("html_string", "") or ""),
        "screen_width": float(params.get("screen_width", 4.0)),
        "screen_height": float(params.get("screen_height", 3.0)),
        "screen_resolution": int(params.get("screen_resolution", 384)),
        "viewport_width": int(params.get("viewport_width", 1280)),
        "viewport_height": int(params.get("viewport_height", 800)),
        "refresh_seconds": float(params.get("refresh_seconds", 0.0)),
        "background_color": np.asarray(
            params.get("background_color", [0.10, 0.11, 0.16]),
            dtype=np.float32,
        ),
        "backend": str(params.get("backend", "tkinterweb") or "tkinterweb"),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    """BrowserRenderer is a leaf — no children to traverse."""
    return []


def precompute_hook(state, engine, node) -> Dict[str, Any]:
    """Cache the current source + (optionally) a 3D-path bitmap.

    The 2D path (GUI shell ``web`` view kind) reads the cache to know
    which URL / HTML to load into ``HtmlFrame``; this hook does not
    instantiate Tk widgets (the engine runs headless during
    precompute).

    The 3D path is opt-in via the ``apeiron[browser-3d]`` extra. When
    Playwright is importable AND a URL is configured, we screenshot
    the page once at build time and cache the bitmap. Failures degrade
    to no-bitmap + an error string that ``describe()`` surfaces.

    Output cache shape::

        {
            "source_mode": "html" | "url" | "none",
            "url": str,
            "html_string": str,
            "bitmap": np.ndarray | None,  # (H, W, 3) float32 in [0,1]
            "error": Optional[str],
        }
    """
    html_string = state.get("html_string") or ""
    url = state.get("url") or ""

    if html_string:
        source_mode = "html"
    elif url:
        source_mode = "url"
    else:
        source_mode = "none"

    entry: Dict[str, Any] = {
        "source_mode": source_mode,
        "url": url,
        "html_string": html_string,
        "bitmap": None,
        "error": None,
    }

    # 3D path: optional Playwright screenshot. Best-effort — any failure
    # surfaces as entry["error"] and the emit() path falls back to a
    # solid background color.
    if source_mode == "url" and _playwright_available():
        try:
            entry["bitmap"] = _capture_playwright_bitmap(
                url=url,
                viewport_width=int(state.get("viewport_width", 1280)),
                viewport_height=int(state.get("viewport_height", 800)),
                engine=engine,
            )
        except Exception as exc:
            entry["error"] = (
                f"BrowserRenderer playwright capture failed for {url!r}: {exc}"
            )

    return entry


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Paint the cached bitmap (3D path) or a solid background rect.

    The 2D path's actual rendering happens inside Tk — the GUI shell
    constructs an ``HtmlFrame`` directly. ``emit`` only matters for
    the 3D path, where the BrowserRenderer participates in the
    software-raster's screen-rectangle pipeline.

    When no bitmap is cached (Playwright not installed, page hadn't
    loaded yet, or HTML-only mode), the rectangle is filled with
    ``background_color`` so the screen position is still visible in
    the scene. The describe() output names the source mode so the
    debug surface shows what would have rendered.
    """
    cache_entry = ctx.engine.cache.get(ctx.node.id, {})
    bitmap = cache_entry.get("bitmap") if isinstance(cache_entry, dict) else None
    background_color = state["background_color"]

    if bitmap is None:
        # No cached bitmap — render a solid-color screen rect so the
        # node's footprint is still visible in the outer world.
        return _paste_solid_screen_rectangle(
            view,
            screen_w=state["screen_width"],
            screen_h=state["screen_height"],
            fill_color=background_color,
        )

    return _paste_onto_screen_rectangle(
        view,
        screen_w=state["screen_width"],
        screen_h=state["screen_height"],
        internal_color=bitmap,
    )


def describe(state, ctx: EmitContext) -> str:
    """Text-rendering surface — the LLM-facing description of this node.

    Names the source mode + URL/HTML preview + cached-bitmap status so
    text-API verbs (``describe``, ``describe-subtree``) tell the
    maintainer what the node would render in the 3D path even when
    Playwright isn't installed.
    """
    cache_entry = ctx.engine.cache.get(ctx.node.id, {})
    if not isinstance(cache_entry, dict):
        cache_entry = {}
    mode = cache_entry.get("source_mode", "none")
    err = cache_entry.get("error")
    bitmap = cache_entry.get("bitmap")
    bitmap_state = (
        f"bitmap={bitmap.shape}" if bitmap is not None else "bitmap=none"
    )
    if mode == "html":
        head = (state["html_string"] or "")[:80].replace("\n", " ")
        body = f"html='{head}...'" if len(state["html_string"]) > 80 else f"html={head!r}"
    elif mode == "url":
        body = f"url={state['url']!r}"
    else:
        body = "(no source configured)"
    err_tag = f" error={err!r}" if err else ""
    return (
        f"BrowserRenderer id={ctx.node.id} "
        f"screen={state['screen_width']:.2f}x{state['screen_height']:.2f} "
        f"viewport={state['viewport_width']}x{state['viewport_height']} "
        f"backend={state.get('backend', 'tkinterweb')!r} "
        f"{body} {bitmap_state}{err_tag}"
    )


# ---------------------------------------------------------------------------
# 3D path — Playwright bitmap capture.
# ---------------------------------------------------------------------------


def _playwright_available() -> bool:
    """True iff playwright + a usable browser binary is importable.

    Conservative — both the package import AND a sync_playwright
    context-manager probe pass before we declare ``available``. A
    package install without ``playwright install chromium`` does not
    count.
    """
    try:
        from playwright.sync_api import sync_playwright  # noqa: F401
    except Exception:
        return False
    return True


def _capture_playwright_bitmap(
    url: str,
    viewport_width: int,
    viewport_height: int,
    engine: Any,
) -> np.ndarray:
    """Screenshot ``url`` headlessly and return an HxWx3 float32 array.

    Uses a singleton ``Browser`` cached on
    ``engine.cache['__playwright_browser__']`` so subsequent captures
    don't re-launch Chromium. Teardown lives at engine shutdown (a
    future engine.on_shutdown hook will close it; for now the OS
    cleans up at process exit).
    """
    from io import BytesIO

    from PIL import Image
    from playwright.sync_api import sync_playwright

    cache_key = "__playwright_browser__"
    cached = engine.cache.get(cache_key)
    if cached is None:
        p = sync_playwright().start()
        browser = p.chromium.launch(headless=True)
        engine.cache[cache_key] = {"playwright": p, "browser": browser}
        cached = engine.cache[cache_key]

    browser = cached["browser"]
    context = browser.new_context(
        viewport={"width": viewport_width, "height": viewport_height}
    )
    page = context.new_page()
    try:
        page.goto(url, wait_until="domcontentloaded")
        png_bytes = page.screenshot(type="png", full_page=False)
    finally:
        context.close()

    img = Image.open(BytesIO(png_bytes)).convert("RGB")
    arr = np.asarray(img, dtype=np.float32) / 255.0
    return arr


# ---------------------------------------------------------------------------
# Screen-rectangle compositors. Same primitive shape as Computer /
# ChatInterface / ListRenderer; would benefit from being lifted into
# ``engine/screen.py`` (existing TODO).
# ---------------------------------------------------------------------------


def _paste_solid_screen_rectangle(
    view: View, screen_w: float, screen_h: float, fill_color: np.ndarray
) -> Channels:
    """Render a screen rectangle in the XY plane at z=0 filled with
    ``fill_color``. Outside-screen pixels are transparent so the rest
    of the scene composites through naturally.
    """
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
    safe_dz = np.where(
        np.abs(dirs_world[..., 2]) < eps,
        eps * np.sign(dirs_world[..., 2] + eps),
        dirs_world[..., 2],
    )
    t = -origin[2] / safe_dz
    x_hit = origin[0] + t * dirs_world[..., 0]
    y_hit = origin[1] + t * dirs_world[..., 1]
    inside = (
        (t > 0)
        & (np.abs(x_hit) <= screen_w / 2.0)
        & (np.abs(y_hit) <= screen_h / 2.0)
    )

    color_out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    depth_out = np.full((out_h, out_w), np.inf, dtype=np.float32)

    color_out[inside] = fill_color
    depth_out = np.where(inside, t.astype(np.float32), depth_out)
    return {"color": color_out, "depth": depth_out}


def _paste_onto_screen_rectangle(
    view: View,
    screen_w: float,
    screen_h: float,
    internal_color: np.ndarray,
) -> Channels:
    """UV-sample ``internal_color`` onto the screen rectangle. Mirrors
    ChatInterface / Computer / ListRenderer's helper of the same name.
    """
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
    safe_dz = np.where(
        np.abs(dirs_world[..., 2]) < eps,
        eps * np.sign(dirs_world[..., 2] + eps),
        dirs_world[..., 2],
    )
    t = -origin[2] / safe_dz
    x_hit = origin[0] + t * dirs_world[..., 0]
    y_hit = origin[1] + t * dirs_world[..., 1]
    inside = (
        (t > 0)
        & (np.abs(x_hit) <= screen_w / 2.0)
        & (np.abs(y_hit) <= screen_h / 2.0)
    )

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
