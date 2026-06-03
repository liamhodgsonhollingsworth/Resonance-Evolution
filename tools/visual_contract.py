"""
SPEC-069 — Apeiron visual design contract (phase 1: foundation).

Single source of truth for color, typography, and iconography across
every visual surface in the project. Phase 1 ships the contract;
phases 2-7 of the migration replace the hex literals scattered
through ``gui_shell.py``, ``list_renderer.py``, and per-view scene
JSON with calls into this module.

Three public surfaces:

1. **Color palette** — semantic tokens (``surface-0``..``status-*``)
   resolved to hex strings. Per-view central-pane tints exposed via
   ``view_accent(name)``. Light-mode companions reserved for v2.

2. **Typography** — font stacks (``font_sans`` Segoe UI → Helvetica
   → Arial; ``font_mono`` Cascadia Mono → Consolas → Courier New)
   and size tokens (``text-display``..``text-meta``). ``get_font()``
   probes the OS for the best available family and caches.

3. **Iconography** — Lucide SVG strings (MIT-licensed, bundled
   inline so no network or pip dep) rendered to
   ``PIL.ImageTk.PhotoImage`` for Tk via a layered renderer:

     a. ``cairosvg`` if importable AND libcairo is on the system,
     b. else pure-PIL fallback (parses the Lucide ``<path d="…">``
        + simple shape vocabulary onto an ImageDraw surface).

   In-memory LRU cache keyed by ``(name, size, color)``. Caller
   must hold the returned PhotoImage reference (Tk GCs unreferenced
   PhotoImages — a known footgun).

Public API::

    get_color(token: str) -> str
    get_font(family_alias: str = "sans", size: int = 11,
             bold: bool = False) -> tuple
    get_icon(name: str, size: int = 16,
             color: str | None = None) -> PIL.ImageTk.PhotoImage

    list_color_tokens() -> list[str]
    list_font_families() -> list[str]
    list_icon_names() -> list[str]

Aliases for terseness::

    color = get_color
    font_sans = lambda size=11, bold=False: get_font("sans", size, bold)
    font_mono = lambda size=11: get_font("mono", size)
    icon = get_icon

The text-API in ``tools/text_test.py`` adds verbs
``visual-contract-list-colors``, ``visual-contract-list-icons``,
``visual-contract-list-fonts``, and
``visual-contract-resolve-icon <name> <size>`` for headless
verification (SPEC-081).

The ``visual_contract`` ready-check probe (SPEC-064) verifies:

- every documented semantic token resolves,
- every font alias resolves to a tuple with the family stack,
- the icon cache populates and round-trips a 16x16 icon.

Migration phases 2-7 (replacing hex literals in existing GUI
surfaces) land in separate PRs. Phase 1 just adds the module —
readers consume it on their own time.
"""

from __future__ import annotations

import functools
import io
import re
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

# ---------------------------------------------------------------------------
# 1. Color palette
# ---------------------------------------------------------------------------

# Dark-mode tokens (v1). Light-mode companions reserved; ``mode`` flag
# stays "dark" until v2.

_COLORS_DARK: Dict[str, str] = {
    # Surfaces (deepest -> central content)
    "surface-0": "#15171c",
    "surface-1": "#1c1f26",
    "surface-1b": "#22252b",
    "surface-2": "#2a2d34",
    "surface-divider": "#2a2d34",
    # Interactive accents
    "accent": "#3b4254",
    "accent-hover": "#4d566d",
    # Foreground text
    "fg-primary": "#e8e8ec",
    "fg-emphasis": "#ffffff",
    "fg-secondary": "#c8ccd6",
    "fg-muted": "#8d92a3",
    # Status tokens
    "status-ok": "#a6d39b",
    "status-pending": "#d9d98c",
    "status-in-progress": "#8cbff3",
    "status-alert": "#f37373",
    "status-warn": "#f3d973",
    "status-granted": "#73f3a6",
    "status-cancelled": "#8c8c8c",
    # Extended status tokens — surfaced for list_renderer's 13-entry
    # legacy status map (SPEC-069 phase 2 migration). Added when phase
    # 2 unified 2D + 3D status palettes; the original 7 tokens above
    # cover the gui_shell case, but list_renderer's per-status
    # rendering needed two more shades to avoid collapsing distinct
    # in-flight states (granting vs warn, resolved vs in-progress).
    "status-active": "#f3a673",      # warm orange — granting (in-flight)
    "status-resolved": "#73d9f3",    # cyan — resolved (terminal-positive)
}

# Per-view central-pane tints (override ``surface-2`` only). Values
# port from the JSON's RGB-floats in ``scenes/workflow_view.json``
# (multiply by 255). Unmapped views fall back to ``surface-1``.

_VIEW_ACCENTS: Dict[str, str] = {
    "Tasks": "#1a1f2e",
    "Ideas": "#1a2e29",
    "Wishlist": "#291a2e",
    "Quarantine": "#331a1a",
    "Trusted Senders": "#1a291a",
    "Logs": "#2e2a1a",
}


def get_color(token: str) -> str:
    """Resolve a semantic color token to a ``#RRGGBB`` hex string.

    Raises ``KeyError`` with a clear message when the token is
    unknown — silent fallbacks mask typos.
    """
    if token not in _COLORS_DARK:
        raise KeyError(
            f"unknown color token {token!r}; "
            f"available: {', '.join(sorted(_COLORS_DARK))}"
        )
    return _COLORS_DARK[token]


def view_accent(view_name: str, default: str = "surface-1") -> str:
    """Return the per-view central-pane tint hex.

    Falls back to ``default`` (resolved through ``get_color``) when
    the view is not in the registry. Sidebar views like Inbox /
    Chat / 3D / Sessions stay on ``surface-1`` per the design doc.
    """
    if view_name in _VIEW_ACCENTS:
        return _VIEW_ACCENTS[view_name]
    return get_color(default)


def list_color_tokens() -> List[str]:
    """Return the sorted list of documented color tokens."""
    return sorted(_COLORS_DARK)


def list_view_accents() -> List[str]:
    """Return the sorted list of views with a central-pane tint."""
    return sorted(_VIEW_ACCENTS)


# Status-key (item-domain) → semantic color token mapping. The keys
# come from the list_renderer + workflow source-files vocabulary
# (``pending``/``done``/``in_progress``/etc.); the values are tokens
# from ``_COLORS_DARK``. ``None`` is the sentinel for "no status";
# it maps to the muted foreground so unstatused items don't shout.
_STATUS_KEY_TO_TOKEN: Dict[Optional[str], str] = {
    "pending": "status-pending",
    "done": "status-ok",
    "in_progress": "status-in-progress",
    "cancelled": "status-cancelled",
    "granted": "status-granted",
    "planning": "status-warn",
    "granting": "status-active",
    "superseded": "status-cancelled",
    "resolved": "status-resolved",
    "alert": "status-alert",
    "warn": "status-warn",
    "ok": "status-ok",
    None: "fg-secondary",
}


def status_token(status: Optional[str]) -> str:
    """Map a status-key (``pending``/``done``/etc.) to a semantic
    color token. Unknown keys fall through to ``fg-secondary`` — the
    same as the ``None`` sentinel — so consumers don't need to
    special-case "unmapped".
    """
    return _STATUS_KEY_TO_TOKEN.get(status, "fg-secondary")


def status_color(status: Optional[str], fmt: str = "hex") -> Any:
    """Resolve a status-key to a color in the requested format.

    ``fmt`` is one of:

    - ``"hex"`` — ``#RRGGBB`` string (Tk-friendly).
    - ``"rgb01"`` — ``(r, g, b)`` float tuple in [0, 1] (PIL /
      numpy / list_renderer-friendly).
    - ``"rgb255"`` — ``(r, g, b)`` int tuple in [0, 255]
      (PIL.ImageDraw-friendly).

    Unknown statuses fall through to the ``fg-secondary`` token —
    matching the ``None`` sentinel — so callers don't need to
    special-case unmapped values.
    """
    hex_value = get_color(status_token(status))
    if fmt == "hex":
        return hex_value
    if fmt == "rgb01":
        return _hex_to_rgb01(hex_value)
    if fmt == "rgb255":
        return _hex_to_rgb255(hex_value)
    raise ValueError(
        f"unknown fmt {fmt!r}; available: 'hex', 'rgb01', 'rgb255'"
    )


def list_status_keys() -> List[str]:
    """Return the sorted list of status-keys with a color mapping.

    ``None`` (the no-status sentinel) is omitted — it has no string
    form to list.
    """
    return sorted(k for k in _STATUS_KEY_TO_TOKEN if k is not None)


def _hex_to_rgb01(hex_value: str) -> Tuple[float, float, float]:
    """Convert ``#RRGGBB`` to a 0..1 float triple."""
    h = hex_value.lstrip("#")
    r = int(h[0:2], 16) / 255.0
    g = int(h[2:4], 16) / 255.0
    b = int(h[4:6], 16) / 255.0
    return (r, g, b)


def _hex_to_rgb255(hex_value: str) -> Tuple[int, int, int]:
    """Convert ``#RRGGBB`` to a 0..255 int triple."""
    h = hex_value.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


# ---------------------------------------------------------------------------
# 2. Typography
# ---------------------------------------------------------------------------

_FONT_STACKS: Dict[str, Tuple[str, ...]] = {
    "sans": ("Segoe UI", "Helvetica", "Arial"),
    "mono": ("Cascadia Mono", "Consolas", "Courier New"),
}

_FONT_SIZES: Dict[str, int] = {
    "text-display": 14,
    "text-body-strong": 11,
    "text-body": 11,
    "text-body-sm": 10,
    "text-meta": 9,
}


# Cache the OS-available family per (alias) — looked up once per
# process. ``None`` is a sentinel for "not yet resolved".
_RESOLVED_FAMILY: Dict[str, Optional[str]] = {"sans": None, "mono": None}
_FAMILY_LOCK = threading.Lock()


def _available_families() -> set:
    """Return the set of family names known to Tk.

    Returns an empty set when Tk is not initializable (headless CI
    or no display). Callers handle the empty case by treating every
    family as "not present" and using the first stack entry as a
    declared preference.
    """
    try:
        import tkinter as tk
        from tkinter import font as tkfont
    except Exception:
        return set()
    try:
        root = tk._default_root  # type: ignore[attr-defined]
        owns_root = False
        if root is None:
            root = tk.Tk()
            root.withdraw()
            owns_root = True
        families = set(tkfont.families(root=root))
        if owns_root:
            root.destroy()
        return families
    except Exception:
        return set()


def _resolve_family(alias: str) -> str:
    """Resolve a family alias ("sans" / "mono") to the first
    available family in its stack. Falls back to the first entry
    (the declared preference) when Tk reports nothing — that way
    the contract is still well-defined in headless tests.
    """
    if alias not in _FONT_STACKS:
        raise KeyError(
            f"unknown font alias {alias!r}; "
            f"available: {', '.join(_FONT_STACKS)}"
        )
    with _FAMILY_LOCK:
        cached = _RESOLVED_FAMILY.get(alias)
        if cached is not None:
            return cached
        families = _available_families()
        stack = _FONT_STACKS[alias]
        chosen = next((f for f in stack if f in families), stack[0])
        _RESOLVED_FAMILY[alias] = chosen
        return chosen


def get_font(
    family_alias: str = "sans",
    size: int = 11,
    bold: bool = False,
) -> tuple:
    """Return a Tk-compatible font tuple ``(family, size[, "bold"])``.

    ``family_alias`` is "sans" or "mono"; the stack is probed once
    against ``tkfont.families()``. ``size`` is an integer pt size;
    callers can use the documented ``text-*`` size tokens via
    ``get_font_size(token)``.
    """
    family = _resolve_family(family_alias)
    if bold:
        return (family, int(size), "bold")
    return (family, int(size))


def get_font_size(token: str) -> int:
    """Resolve a text-size token (``text-display`` / ``text-body`` /
    ``text-body-strong`` / ``text-body-sm`` / ``text-meta``) to its
    integer point size.
    """
    if token not in _FONT_SIZES:
        raise KeyError(
            f"unknown font size token {token!r}; "
            f"available: {', '.join(sorted(_FONT_SIZES))}"
        )
    return _FONT_SIZES[token]


def list_font_families() -> List[str]:
    """Return the available font-stack aliases (e.g. ``["sans", "mono"]``)."""
    return sorted(_FONT_STACKS)


def list_font_sizes() -> List[str]:
    """Return the documented text-size tokens."""
    return sorted(_FONT_SIZES)


def font_stack(alias: str) -> Tuple[str, ...]:
    """Return the full ordered family stack for an alias.

    Useful for diagnostics — ``get_font`` only returns the chosen
    family, not the fallback list.
    """
    if alias not in _FONT_STACKS:
        raise KeyError(
            f"unknown font alias {alias!r}; "
            f"available: {', '.join(_FONT_STACKS)}"
        )
    return _FONT_STACKS[alias]


# Reset hook used by tests to invalidate the per-alias family cache.
def _reset_font_cache() -> None:
    with _FAMILY_LOCK:
        for k in _RESOLVED_FAMILY:
            _RESOLVED_FAMILY[k] = None


# ---------------------------------------------------------------------------
# 3. Iconography — Lucide SVG strings + layered renderer
# ---------------------------------------------------------------------------

# Lucide icons, MIT license (https://lucide.dev/license).
# Each entry is the inner-body SVG markup for a 24x24 viewBox at
# stroke-width 2, no fill. We assemble the full ``<svg>`` wrapper
# at render time so we can substitute the stroke color.

_LUCIDE_PATHS: Dict[str, str] = {
    # Per-tab icons (design doc §4)
    "check-square": (
        '<polyline points="9 11 12 14 22 4"/>'
        '<path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"/>'
    ),
    "lightbulb": (
        '<path d="M9 18h6"/>'
        '<path d="M10 22h4"/>'
        '<path d="M15.09 14c.18-.98.65-1.74 1.41-2.5A4.65 4.65 0 0 0 18 8a6 6 0 0 0-12 0c0 1 .23 2.23 1.5 3.5A4.61 4.61 0 0 1 8.91 14"/>'
    ),
    "star": (
        '<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/>'
    ),
    "inbox": (
        '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/>'
        '<path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>'
    ),
    "message-circle": (
        '<path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/>'
    ),
    "shield-alert": (
        '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>'
        '<line x1="12" y1="8" x2="12" y2="12"/>'
        '<line x1="12" y1="16" x2="12.01" y2="16"/>'
    ),
    "shield-check": (
        '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>'
        '<polyline points="9 12 11 14 15 10"/>'
    ),
    "box": (
        '<path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>'
        '<polyline points="3.27 6.96 12 12.01 20.73 6.96"/>'
        '<line x1="12" y1="22.08" x2="12" y2="12"/>'
    ),
    "file-text": (
        '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/>'
        '<polyline points="14 2 14 8 20 8"/>'
        '<line x1="16" y1="13" x2="8" y2="13"/>'
        '<line x1="16" y1="17" x2="8" y2="17"/>'
        '<polyline points="10 9 9 9 8 9"/>'
    ),
    "users": (
        '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/>'
        '<circle cx="9" cy="7" r="4"/>'
        '<path d="M23 21v-2a4 4 0 0 0-3-3.87"/>'
        '<path d="M16 3.13a4 4 0 0 1 0 7.75"/>'
    ),
    # Shared action vocabulary
    "archive": (
        '<polyline points="21 8 21 21 3 21 3 8"/>'
        '<rect x="1" y="3" width="22" height="5"/>'
        '<line x1="10" y1="12" x2="14" y2="12"/>'
    ),
    "lock": (
        '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>'
        '<path d="M7 11V7a5 5 0 0 1 10 0v4"/>'
    ),
    "unlock": (
        '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>'
        '<path d="M7 11V7a5 5 0 0 1 9.9-1"/>'
    ),
    "chevron-down": (
        '<polyline points="6 9 12 15 18 9"/>'
    ),
    "chevron-right": (
        '<polyline points="9 18 15 12 9 6"/>'
    ),
    "x": (
        '<line x1="18" y1="6" x2="6" y2="18"/>'
        '<line x1="6" y1="6" x2="18" y2="18"/>'
    ),
    "more-vertical": (
        '<circle cx="12" cy="12" r="1"/>'
        '<circle cx="12" cy="5" r="1"/>'
        '<circle cx="12" cy="19" r="1"/>'
    ),
    "copy": (
        '<rect x="9" y="9" width="13" height="13" rx="2" ry="2"/>'
        '<path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>'
    ),
    "clipboard": (
        '<path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/>'
        '<rect x="8" y="2" width="8" height="4" rx="1" ry="1"/>'
    ),
    "grip-vertical": (
        '<circle cx="9" cy="12" r="1"/>'
        '<circle cx="9" cy="5" r="1"/>'
        '<circle cx="9" cy="19" r="1"/>'
        '<circle cx="15" cy="12" r="1"/>'
        '<circle cx="15" cy="5" r="1"/>'
        '<circle cx="15" cy="19" r="1"/>'
    ),
}


def list_icon_names() -> List[str]:
    """Return the sorted list of icons known to the contract."""
    return sorted(_LUCIDE_PATHS)


def get_icon_svg(name: str, color: str = "#e8e8ec") -> str:
    """Return the full ``<svg>`` markup string for an icon.

    Public for downstream consumers (e.g. a future HTML renderer)
    that want the SVG itself rather than a rasterized PhotoImage.
    """
    if name not in _LUCIDE_PATHS:
        raise KeyError(
            f"unknown icon {name!r}; "
            f"available: {', '.join(sorted(_LUCIDE_PATHS))}"
        )
    body = _LUCIDE_PATHS[name]
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="0 0 24 24" width="24" height="24" '
        f'fill="none" stroke="{color}" '
        f'stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">{body}</svg>'
    )


# --- 3a. Renderer detection ------------------------------------------------

_RENDERER_PROBED = False
_HAVE_CAIROSVG = False
_RENDERER_LOCK = threading.Lock()


def _probe_renderer() -> str:
    """Return the active renderer label: ``"cairosvg"`` or ``"pil"``.

    Detection runs once. cairosvg-the-python-package is a no-op
    without libcairo on the system, so we don't just check for
    importability — we attempt a 1x1 rasterization. The pure-PIL
    fallback handles the Lucide stroke vocabulary directly.
    """
    global _RENDERER_PROBED, _HAVE_CAIROSVG
    with _RENDERER_LOCK:
        if _RENDERER_PROBED:
            return "cairosvg" if _HAVE_CAIROSVG else "pil"
        try:
            import cairosvg  # type: ignore[import-not-found]
            # libcairo is loaded lazily by cairocffi — exercise it.
            cairosvg.svg2png(
                bytestring=(
                    b'<svg xmlns="http://www.w3.org/2000/svg" '
                    b'viewBox="0 0 1 1" width="1" height="1"/>'
                ),
                output_width=1,
                output_height=1,
            )
            _HAVE_CAIROSVG = True
        except Exception:
            _HAVE_CAIROSVG = False
        _RENDERER_PROBED = True
        return "cairosvg" if _HAVE_CAIROSVG else "pil"


def active_renderer() -> str:
    """Public probe — returns ``"cairosvg"`` or ``"pil"``.

    Sessions surface this in the ready-check report so the
    maintainer can see at a glance which path is wired (pure-PIL is
    documented as a fallback on Windows where libcairo isn't
    standard)."""
    return _probe_renderer()


# --- 3b. cairosvg path -----------------------------------------------------

def _render_cairosvg(name: str, size: int, color: str):
    import cairosvg  # type: ignore[import-not-found]
    from PIL import Image
    svg = get_icon_svg(name, color=color)
    png_bytes = cairosvg.svg2png(
        bytestring=svg.encode("utf-8"),
        output_width=size,
        output_height=size,
    )
    return Image.open(io.BytesIO(png_bytes)).convert("RGBA")


# --- 3c. pure-PIL fallback path -------------------------------------------

# The Lucide icons we ship use a small SVG vocabulary: <path d="…">
# with M/L/A/Z + occasionally curves, plus <line>, <polyline>,
# <polygon>, <circle>, <rect>. The renderer below covers each shape
# at fidelity good enough for 16-24 px chrome icons. It is NOT a
# general SVG renderer — it's just enough to render the bundled
# Lucide subset.

_PATH_TOKEN_RE = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|-?\d+(?:\.\d+)?")


def _tokenize_path(d: str) -> List[str]:
    return _PATH_TOKEN_RE.findall(d)


def _parse_points(text: str) -> List[Tuple[float, float]]:
    nums = [float(t) for t in re.split(r"[,\s]+", text.strip()) if t]
    return [(nums[i], nums[i + 1]) for i in range(0, len(nums) - 1, 2)]


def _draw_svg_to_pil(
    svg: str,
    *,
    size: int,
    color: str,
):
    """Pure-PIL SVG renderer for the Lucide subset.

    Parses each top-level element (``<line>``, ``<polyline>``,
    ``<polygon>``, ``<rect>``, ``<circle>``, ``<path>``) and
    rasterizes onto a ``size × size`` RGBA image scaled from the
    24x24 viewBox. Stroke width scales with size so 16-px icons
    don't visually disappear.
    """
    from PIL import Image, ImageDraw
    scale = size / 24.0
    stroke_w = max(1, round(2 * scale))
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    def _sx(x: float) -> float:
        return x * scale

    def _sy(y: float) -> float:
        return y * scale

    # Strip the outer <svg> tag — we re-grab the inner body. Easier
    # to operate on the inner body that ``get_icon_svg`` assembled.
    inner_match = re.search(r"<svg[^>]*>(.*)</svg>", svg, re.DOTALL)
    body = inner_match.group(1) if inner_match else svg

    # Iterate each element in source order.
    for elem in re.finditer(
        r"<(line|polyline|polygon|rect|circle|path)\b([^/>]*)/?>",
        body,
    ):
        tag, attrs_text = elem.group(1), elem.group(2)
        attrs = dict(
            (m.group(1), m.group(2))
            for m in re.finditer(r'(\w[\w-]*)="([^"]*)"', attrs_text)
        )
        if tag == "line":
            x1 = float(attrs.get("x1", 0))
            y1 = float(attrs.get("y1", 0))
            x2 = float(attrs.get("x2", 0))
            y2 = float(attrs.get("y2", 0))
            draw.line(
                [(_sx(x1), _sy(y1)), (_sx(x2), _sy(y2))],
                fill=color, width=stroke_w,
            )
        elif tag == "polyline":
            pts = _parse_points(attrs.get("points", ""))
            scaled = [(_sx(x), _sy(y)) for x, y in pts]
            if len(scaled) >= 2:
                draw.line(scaled, fill=color, width=stroke_w, joint="curve")
        elif tag == "polygon":
            pts = _parse_points(attrs.get("points", ""))
            scaled = [(_sx(x), _sy(y)) for x, y in pts]
            if len(scaled) >= 3:
                # Close the polygon by drawing a line back to start.
                draw.line(
                    scaled + [scaled[0]],
                    fill=color, width=stroke_w, joint="curve",
                )
        elif tag == "rect":
            x = float(attrs.get("x", 0))
            y = float(attrs.get("y", 0))
            w = float(attrs.get("width", 0))
            h = float(attrs.get("height", 0))
            # Lucide ``rx``/``ry`` rounded corners — approximate with
            # a plain rectangle; the curvature is too small at 16-24
            # px for the rounding to matter for usability.
            x1, y1 = _sx(x), _sy(y)
            x2, y2 = _sx(x + w), _sy(y + h)
            # Draw four lines so we get stroke-only.
            draw.line(
                [(x1, y1), (x2, y1), (x2, y2), (x1, y2), (x1, y1)],
                fill=color, width=stroke_w, joint="curve",
            )
        elif tag == "circle":
            cx = float(attrs.get("cx", 0))
            cy = float(attrs.get("cy", 0))
            r = float(attrs.get("r", 0))
            bbox = (_sx(cx - r), _sy(cy - r), _sx(cx + r), _sy(cy + r))
            draw.ellipse(bbox, outline=color, width=stroke_w)
        elif tag == "path":
            _draw_path(draw, attrs.get("d", ""), scale, color, stroke_w)

    return img


def _draw_path(
    draw, d: str, scale: float, color: str, stroke_w: int,
) -> None:
    """Render an SVG path with the Lucide-subset command set.

    Handles M/m/L/l/H/h/V/v/A/a/Z/z. Curves (C/Q/S/T) are
    approximated as line-to-endpoint — Lucide rarely uses bezier
    curves in the icons we ship, and visual fidelity at 16-24 px
    against the alternative (no icon at all) is acceptable.
    """
    tokens = _tokenize_path(d)
    i = 0
    cx, cy = 0.0, 0.0       # current point
    sx, sy = 0.0, 0.0       # subpath start
    cmd = None
    current_segment: List[Tuple[float, float]] = []

    def flush_segment() -> None:
        if len(current_segment) >= 2:
            scaled = [
                (x * scale, y * scale) for x, y in current_segment
            ]
            draw.line(scaled, fill=color, width=stroke_w, joint="curve")
        current_segment.clear()

    def consume_xy(rel: bool) -> Tuple[float, float]:
        nonlocal i
        x = float(tokens[i]); y = float(tokens[i + 1])
        i += 2
        if rel:
            return cx + x, cy + y
        return x, y

    while i < len(tokens):
        tok = tokens[i]
        if tok.isalpha():
            cmd = tok
            i += 1
            if cmd in ("M", "m"):
                flush_segment()
                nx, ny = consume_xy(cmd == "m")
                cx, cy = nx, ny
                sx, sy = cx, cy
                current_segment.append((cx, cy))
                # Subsequent coord pairs after M become implicit L
                cmd = "L" if cmd == "M" else "l"
            elif cmd in ("Z", "z"):
                # Close path — line back to subpath start.
                current_segment.append((sx, sy))
                cx, cy = sx, sy
                flush_segment()
                cmd = None
            continue

        if cmd in ("L", "l"):
            nx, ny = consume_xy(cmd == "l")
            cx, cy = nx, ny
            current_segment.append((cx, cy))
        elif cmd in ("H", "h"):
            x = float(tokens[i]); i += 1
            cx = cx + x if cmd == "h" else x
            current_segment.append((cx, cy))
        elif cmd in ("V", "v"):
            y = float(tokens[i]); i += 1
            cy = cy + y if cmd == "v" else y
            current_segment.append((cx, cy))
        elif cmd in ("A", "a"):
            # Arc: skip the 5 flag/radius args, consume endpoint.
            i += 5
            nx, ny = consume_xy(cmd == "a")
            cx, cy = nx, ny
            current_segment.append((cx, cy))
        elif cmd in ("C", "c", "S", "s", "Q", "q", "T", "t"):
            # Curve approximation: skip control points, jump to
            # endpoint. The Lucide subset rarely uses these in our
            # bundled icons.
            advance = {"C": 4, "c": 4, "S": 2, "s": 2,
                       "Q": 2, "q": 2, "T": 0, "t": 0}[cmd]
            i += advance * 2  # control pairs
            nx, ny = consume_xy(cmd.islower())
            cx, cy = nx, ny
            current_segment.append((cx, cy))
        else:
            # Unrecognized — bail to avoid an infinite loop.
            i += 1

    flush_segment()


def _render_pil(name: str, size: int, color: str):
    return _draw_svg_to_pil(get_icon_svg(name, color=color), size=size, color=color)


# --- 3d. Icon cache + public ``get_icon`` ---------------------------------

_ICON_CACHE_LIMIT = 64
# OrderedDict-like behavior via list of (key, value) for LRU. Tk
# PhotoImage objects must be referenced or Tk GCs them, so the
# cache values keep them alive. Callers calling ``get_icon`` while
# the same key is hot get the same PhotoImage back.
_ICON_CACHE: "list[tuple[tuple, object]]" = []
_ICON_LOCK = threading.Lock()


def _cache_get(key: tuple):
    for idx, (k, v) in enumerate(_ICON_CACHE):
        if k == key:
            # Move-to-end LRU.
            _ICON_CACHE.pop(idx)
            _ICON_CACHE.append((k, v))
            return v
    return None


def _cache_put(key: tuple, value) -> None:
    _ICON_CACHE.append((key, value))
    while len(_ICON_CACHE) > _ICON_CACHE_LIMIT:
        _ICON_CACHE.pop(0)


def clear_icon_cache() -> None:
    """Purge the icon cache. Mostly for tests."""
    with _ICON_LOCK:
        _ICON_CACHE.clear()


def render_icon_image(
    name: str,
    size: int = 16,
    color: Optional[str] = None,
):
    """Render an icon to a ``PIL.Image.Image`` (no Tk dependency).

    Pure-PIL surface useful in headless tests and the text-API
    verification verbs. Bypasses the PhotoImage cache (no Tk needed).
    """
    if name not in _LUCIDE_PATHS:
        raise KeyError(
            f"unknown icon {name!r}; "
            f"available: {', '.join(sorted(_LUCIDE_PATHS))}"
        )
    if size <= 0:
        raise ValueError(f"size must be positive (got {size})")
    if color is None:
        color = get_color("fg-primary")
    if _probe_renderer() == "cairosvg":
        try:
            return _render_cairosvg(name, size, color)
        except Exception:
            # Cache the failure so we don't keep trying — flip
            # the flag and proceed via PIL.
            global _HAVE_CAIROSVG
            with _RENDERER_LOCK:
                _HAVE_CAIROSVG = False
    return _render_pil(name, size, color)


def get_icon(
    name: str,
    size: int = 16,
    color: Optional[str] = None,
):
    """Render an icon to a ``PIL.ImageTk.PhotoImage`` (Tk widget).

    Cached LRU(64) by ``(name, size, color)``. Caller MUST hold the
    returned reference — Tk GCs unreferenced PhotoImages.

    Raises ``KeyError`` for unknown icon names. Raises
    ``RuntimeError`` if Tk has no root (PhotoImage construction
    requires one). Use ``render_icon_image`` for headless tests.
    """
    if color is None:
        color = get_color("fg-primary")
    key = (name, int(size), color)
    with _ICON_LOCK:
        hit = _cache_get(key)
        if hit is not None:
            return hit
    pil_img = render_icon_image(name, size=size, color=color)
    try:
        from PIL import ImageTk
        photo = ImageTk.PhotoImage(pil_img)
    except RuntimeError as exc:
        # "Too early to create image: no default root window" in
        # tests with no Tk root. Re-raise with a clearer hint.
        raise RuntimeError(
            f"get_icon({name!r}) requires a Tk root; "
            f"use render_icon_image() for headless contexts ({exc})"
        )
    with _ICON_LOCK:
        _cache_put(key, photo)
    return photo


# Convenience aliases — short forms for ergonomic call-sites.
color = get_color
icon = get_icon


def font_sans(size: int = 11, bold: bool = False) -> tuple:
    """Sans-serif font tuple at the given size."""
    return get_font("sans", size, bold)


def font_mono(size: int = 11) -> tuple:
    """Monospace font tuple at the given size."""
    return get_font("mono", size)


# ---------------------------------------------------------------------------
# 4. Surface introspection — used by ready-check + text-API verbs
# ---------------------------------------------------------------------------

def contract_status() -> dict:
    """Return a small dict summarizing the contract's runtime state.

    Used by the ready-check probe + diagnostics. Avoids importing
    Tk in headless contexts.
    """
    return {
        "color_tokens": len(_COLORS_DARK),
        "view_accents": len(_VIEW_ACCENTS),
        "font_aliases": list_font_families(),
        "font_size_tokens": len(_FONT_SIZES),
        "icon_count": len(_LUCIDE_PATHS),
        "renderer": active_renderer(),
        "icon_cache_limit": _ICON_CACHE_LIMIT,
    }
