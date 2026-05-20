"""
Tests for SPEC-069 phase 1: the Apeiron visual design contract.

Covers every public surface of ``tools/visual_contract.py``:

- Color tokens — coverage, validity, error shape on unknown name.
- Per-view tints — coverage, fallback for unmapped views.
- Font stacks — alias resolution, fallback when nothing in the
  stack is installed, the size-token table.
- Icon registry — coverage of documented per-tab + action icons.
- Icon rendering — round-trip via ``render_icon_image`` (headless,
  no Tk root needed), SVG string well-formedness.
- LRU cache — population, hit-with-same-key, eviction past limit.
- Renderer probe — returns a known label, gracefully falls back
  when cairosvg can't talk to libcairo.

Headless-safe: every test uses ``render_icon_image`` (returns a
PIL.Image) rather than ``get_icon`` (returns a Tk PhotoImage and
needs a default Tk root). The ready-check ``visual_contract`` probe
exercises the Tk path in environments that have one.
"""

from __future__ import annotations

import re

import pytest
from PIL import Image

from tools import visual_contract as vc


# ---------------------------------------------------------------------------
# Color tokens
# ---------------------------------------------------------------------------

REQUIRED_COLOR_TOKENS = {
    "surface-0", "surface-1", "surface-1b", "surface-2",
    "surface-divider", "accent", "accent-hover",
    "fg-primary", "fg-emphasis", "fg-secondary", "fg-muted",
    "status-ok", "status-pending", "status-in-progress",
    "status-alert", "status-warn", "status-granted", "status-cancelled",
}


def test_every_required_color_token_is_present():
    available = set(vc.list_color_tokens())
    missing = REQUIRED_COLOR_TOKENS - available
    assert not missing, f"missing color tokens: {sorted(missing)}"


def test_every_color_token_resolves_to_six_digit_hex():
    for token in vc.list_color_tokens():
        value = vc.get_color(token)
        assert re.fullmatch(r"#[0-9a-fA-F]{6}", value), (
            f"{token!r} -> {value!r} is not #RRGGBB"
        )


def test_get_color_raises_clear_keyerror_on_unknown_token():
    with pytest.raises(KeyError) as exc:
        vc.get_color("not-a-real-token")
    assert "not-a-real-token" in str(exc.value)
    # Error message lists available tokens so the caller can
    # course-correct without re-reading the source.
    assert "surface-0" in str(exc.value)


def test_color_alias_matches_get_color():
    for token in vc.list_color_tokens():
        assert vc.color(token) == vc.get_color(token)


# ---------------------------------------------------------------------------
# Per-view tints
# ---------------------------------------------------------------------------

REQUIRED_VIEW_TINTS = {
    "Tasks", "Ideas", "Wishlist",
    "Quarantine", "Trusted Senders", "Logs",
}


def test_required_view_tints_present():
    missing = REQUIRED_VIEW_TINTS - set(vc.list_view_accents())
    assert not missing, f"missing view tints: {sorted(missing)}"


def test_view_accent_returns_hex_for_mapped_views():
    for name in vc.list_view_accents():
        value = vc.view_accent(name)
        assert re.fullmatch(r"#[0-9a-fA-F]{6}", value), (
            f"view tint for {name!r} -> {value!r}"
        )


def test_view_accent_falls_back_to_surface_1_for_unmapped_view():
    fallback = vc.view_accent("ThisViewIsNotMapped")
    assert fallback == vc.get_color("surface-1")


def test_view_accent_default_is_overridable():
    """An unmapped view honors an explicit default token argument."""
    result = vc.view_accent("Inbox", default="surface-0")
    assert result == vc.get_color("surface-0")


# ---------------------------------------------------------------------------
# Font stacks
# ---------------------------------------------------------------------------

def test_required_font_aliases_present():
    aliases = set(vc.list_font_families())
    assert {"sans", "mono"}.issubset(aliases)


def test_get_font_returns_tuple_with_size():
    f = vc.get_font("sans", 11)
    assert isinstance(f, tuple)
    assert len(f) == 2
    assert isinstance(f[0], str) and f[0]
    assert f[1] == 11


def test_get_font_bold_appends_bold_marker():
    f = vc.get_font("sans", 14, bold=True)
    assert len(f) == 3
    assert f[2] == "bold"


def test_get_font_chosen_family_falls_back_to_first_when_none_installed(
    monkeypatch,
):
    """When the OS reports no families in the stack, ``get_font``
    falls back to the first declared family. Tests by mocking the
    available-families probe to return an empty set."""
    monkeypatch.setattr(vc, "_available_families", lambda: set())
    vc._reset_font_cache()
    sans = vc.get_font("sans", 11)
    # First entry of the sans stack is Segoe UI per the design doc.
    assert sans[0] == "Segoe UI"
    mono = vc.get_font("mono", 11)
    assert mono[0] == "Cascadia Mono"
    vc._reset_font_cache()


def test_get_font_picks_first_available_from_stack(monkeypatch):
    """When Segoe UI is missing but Helvetica is present, the
    sans alias resolves to Helvetica."""
    monkeypatch.setattr(
        vc, "_available_families", lambda: {"Helvetica", "Consolas"}
    )
    vc._reset_font_cache()
    assert vc.get_font("sans", 11)[0] == "Helvetica"
    assert vc.get_font("mono", 11)[0] == "Consolas"
    vc._reset_font_cache()


def test_get_font_unknown_alias_raises():
    with pytest.raises(KeyError) as exc:
        vc.get_font("display", 11)
    assert "display" in str(exc.value)


def test_font_size_tokens_resolve_to_integers():
    for token in vc.list_font_sizes():
        size = vc.get_font_size(token)
        assert isinstance(size, int) and size > 0


def test_font_size_token_unknown_raises():
    with pytest.raises(KeyError) as exc:
        vc.get_font_size("text-jumbo")
    assert "text-jumbo" in str(exc.value)


def test_font_sans_and_font_mono_aliases():
    assert vc.font_sans(11) == vc.get_font("sans", 11)
    assert vc.font_sans(14, bold=True) == vc.get_font("sans", 14, bold=True)
    assert vc.font_mono(11) == vc.get_font("mono", 11)


def test_font_stack_exposes_full_ordered_stack():
    sans = vc.font_stack("sans")
    assert sans[0] == "Segoe UI"
    assert "Helvetica" in sans
    assert "Arial" in sans


# ---------------------------------------------------------------------------
# Icon registry
# ---------------------------------------------------------------------------

REQUIRED_PER_TAB_ICONS = {
    "check-square", "lightbulb", "star", "inbox",
    "message-circle", "shield-alert", "shield-check",
    "box", "file-text", "users",
}

REQUIRED_ACTION_ICONS = {
    "archive", "lock", "unlock",
    "chevron-down", "chevron-right",
    "x", "more-vertical", "copy", "clipboard", "grip-vertical",
}


def test_required_icons_registered():
    names = set(vc.list_icon_names())
    missing = (REQUIRED_PER_TAB_ICONS | REQUIRED_ACTION_ICONS) - names
    assert not missing, f"missing icons: {sorted(missing)}"


def test_get_icon_svg_returns_well_formed_svg_for_every_icon():
    for name in vc.list_icon_names():
        svg = vc.get_icon_svg(name)
        assert svg.startswith("<svg")
        assert svg.endswith("</svg>")
        assert 'viewBox="0 0 24 24"' in svg
        assert 'stroke="' in svg


def test_get_icon_svg_substitutes_color():
    svg = vc.get_icon_svg("check-square", color="#ff0000")
    assert 'stroke="#ff0000"' in svg


def test_get_icon_svg_unknown_name_raises_clear_keyerror():
    with pytest.raises(KeyError) as exc:
        vc.get_icon_svg("not-a-real-icon")
    assert "not-a-real-icon" in str(exc.value)
    # The error message enumerates the known names so callers
    # can recover without re-reading the source.
    assert "check-square" in str(exc.value)


# ---------------------------------------------------------------------------
# Icon rendering
# ---------------------------------------------------------------------------

def test_render_icon_image_produces_pil_image_at_requested_size():
    img = vc.render_icon_image("check-square", size=16)
    assert isinstance(img, Image.Image)
    assert img.size == (16, 16)


@pytest.mark.parametrize("size", [16, 20, 24, 32])
def test_render_icon_image_honors_multiple_sizes(size):
    img = vc.render_icon_image("star", size=size)
    assert img.size == (size, size)


def test_render_icon_image_unknown_name_raises_keyerror():
    with pytest.raises(KeyError) as exc:
        vc.render_icon_image("not-a-real-icon", size=16)
    assert "not-a-real-icon" in str(exc.value)


def test_render_icon_image_zero_size_raises_valueerror():
    with pytest.raises(ValueError):
        vc.render_icon_image("check-square", size=0)


def test_render_icon_image_falls_back_when_cairosvg_unavailable(monkeypatch):
    """Force the PIL path by disabling the cairosvg probe and
    verify the result is still a non-empty image of the right size."""
    monkeypatch.setattr(vc, "_HAVE_CAIROSVG", False)
    monkeypatch.setattr(vc, "_RENDERER_PROBED", True)
    img = vc.render_icon_image("inbox", size=24)
    assert img.size == (24, 24)
    # The image must contain some non-transparent pixels — otherwise
    # the PIL renderer is silently producing blanks. Use the bbox of
    # non-transparent content rather than getdata (which is
    # deprecated in Pillow 14).
    bbox = img.getbbox()
    assert bbox is not None, "PIL fallback produced an all-transparent image"


def test_active_renderer_returns_known_label():
    label = vc.active_renderer()
    assert label in ("cairosvg", "pil")


def test_contract_status_reports_summary():
    status = vc.contract_status()
    assert status["color_tokens"] >= len(REQUIRED_COLOR_TOKENS)
    assert status["icon_count"] >= len(REQUIRED_PER_TAB_ICONS)
    assert status["renderer"] in ("cairosvg", "pil")
    assert "sans" in status["font_aliases"]


# ---------------------------------------------------------------------------
# LRU cache
# ---------------------------------------------------------------------------

class _StubPhotoImage:
    """Drop-in PhotoImage stand-in for cache tests."""

    def __init__(self, pil_img):
        self.size = pil_img.size
        self._pil = pil_img


def _swap_in_stub_photoimage(monkeypatch):
    """Replace ``PIL.ImageTk.PhotoImage`` with the stub so ``get_icon``
    doesn't need a Tk default root."""
    import PIL.ImageTk
    monkeypatch.setattr(PIL.ImageTk, "PhotoImage", _StubPhotoImage)


def test_get_icon_cache_hits_with_same_key(monkeypatch):
    _swap_in_stub_photoimage(monkeypatch)
    vc.clear_icon_cache()
    a = vc.get_icon("check-square", size=16)
    b = vc.get_icon("check-square", size=16)
    assert a is b, "second get_icon call should return cached object"


def test_get_icon_cache_distinguishes_by_size_and_color(monkeypatch):
    _swap_in_stub_photoimage(monkeypatch)
    vc.clear_icon_cache()
    small = vc.get_icon("star", size=16)
    large = vc.get_icon("star", size=24)
    red = vc.get_icon("star", size=16, color="#ff0000")
    assert small is not large
    assert small is not red
    # Same key gives the same object back.
    assert vc.get_icon("star", size=24) is large


def test_get_icon_cache_evicts_past_limit(monkeypatch):
    """Filling the cache beyond its limit drops the oldest entries."""
    _swap_in_stub_photoimage(monkeypatch)
    vc.clear_icon_cache()
    names = vc.list_icon_names()
    # Fill with (name, size) pairs — vary size to multiply keys.
    limit = vc._ICON_CACHE_LIMIT
    sizes_to_fill = list(range(8, 8 + limit + 5))
    for size in sizes_to_fill:
        vc.get_icon(names[0], size=size)
    # The first ``size`` we inserted should have been evicted.
    assert len(vc._ICON_CACHE) == limit
    first_key = (names[0], sizes_to_fill[0], vc.get_color("fg-primary"))
    cached_keys = [k for k, _ in vc._ICON_CACHE]
    assert first_key not in cached_keys


def test_clear_icon_cache_drops_everything(monkeypatch):
    _swap_in_stub_photoimage(monkeypatch)
    vc.get_icon("box", size=16)
    assert vc._ICON_CACHE
    vc.clear_icon_cache()
    assert not vc._ICON_CACHE


# ---------------------------------------------------------------------------
# Text-API verbs (dispatch through tools.text_test)
# ---------------------------------------------------------------------------

def test_visual_contract_text_api_list_colors():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(_DummyEngine(), "visual-contract-list-colors")
    assert "color tokens" in msg
    for token in REQUIRED_COLOR_TOKENS:
        assert token in msg


def test_visual_contract_text_api_list_icons():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(_DummyEngine(), "visual-contract-list-icons")
    assert "icons" in msg
    for name in REQUIRED_PER_TAB_ICONS:
        assert name in msg


def test_visual_contract_text_api_list_fonts():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(_DummyEngine(), "visual-contract-list-fonts")
    assert "sans" in msg
    assert "mono" in msg


def test_visual_contract_text_api_resolve_icon_default_size():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(
        _DummyEngine(), "visual-contract-resolve-icon check-square"
    )
    assert msg.startswith("OK:")
    assert "16x16" in msg


def test_visual_contract_text_api_resolve_icon_with_size():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(
        _DummyEngine(), "visual-contract-resolve-icon star 24"
    )
    assert msg.startswith("OK:")
    assert "24x24" in msg


def test_visual_contract_text_api_resolve_icon_unknown():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(
        _DummyEngine(), "visual-contract-resolve-icon not-a-real-icon"
    )
    assert msg.startswith("ERR:")
    assert "not-a-real-icon" in msg


def test_visual_contract_text_api_resolve_icon_bad_size():
    from tools.text_test import dispatch_command
    msg, _ = dispatch_command(
        _DummyEngine(), "visual-contract-resolve-icon star notanint"
    )
    assert msg.startswith("ERR:")
    assert "integer" in msg


class _DummyEngine:
    """Minimal stand-in for the ``Engine`` argument the dispatcher
    expects. The visual-contract verbs don't read it, but the
    ``dispatch_command`` signature does."""
    pass
