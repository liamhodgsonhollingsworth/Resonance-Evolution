"""
Tests for SPEC-069 phase 2 + phase 3 migration.

Phase 2 replaces every inline hex literal in ``tools/workflow_gui/gui_shell.py``
and ``node_types/list_renderer.py`` with ``visual_contract.get_color(token)``
calls (or a soft-fail helper that wraps it).

Phase 3 replaces every inline ``("Helvetica", N[, "bold"])`` font tuple in
the same files with ``visual_contract.get_font("sans", N, bold=...)`` calls
(or a soft-fail helper that wraps it).

The tests below scan the live file contents for any remaining inline
literals — the regression boundary. Phase 2 + 3 succeed when both audits
report zero hits across the audited files.

The single intentional exception is the ``_FALLBACK_COLORS`` dict
inside ``gui_shell.py`` plus the ``"#000000"`` final-fallback default,
which exist so the shell stays functional when ``visual_contract`` is
unavailable. The audit and these tests agree on that exemption.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent

AUDITED_FILES = [
    "tools/workflow_gui/gui_shell.py",
    "node_types/list_renderer.py",
]

HEX_PATTERN = re.compile(r"#[0-9a-fA-F]{6}")
FONT_PATTERN = re.compile(
    r'\("Helvetica"|\("Cascadia[ A-Za-z]*"|\("Segoe UI"|'
    r'\("Consolas"|\("Courier[ A-Za-z]*"|\("Arial"'
)


def _is_color_exempt(rel_path: str, line: str) -> bool:
    """Mirror the exemption rules in ``tools.text_test``."""
    if rel_path.endswith("gui_shell.py"):
        stripped = line.strip()
        if (stripped.startswith('"') and ': "#' in stripped
                and stripped.endswith('",')):
            return True
        if 'return _FALLBACK_COLORS.get(token,' in stripped:
            return True
    return False


def _is_font_exempt(rel_path: str, line: str) -> bool:
    """Mirror the exemption rules in ``tools.text_test``."""
    if rel_path.endswith("gui_shell.py"):
        stripped = line.strip()
        if 'soft-failing to' in stripped:
            return True
        if stripped.startswith('return ("Helvetica", size'):
            return True
    return False


def _scan(rel_path: str, pattern: re.Pattern, exempt) -> list:
    path = REPO_ROOT / rel_path
    if not path.exists():
        pytest.skip(f"audit target missing: {rel_path}")
    hits = []
    for idx, line in enumerate(path.read_text(encoding="utf-8").splitlines()):
        if pattern.search(line) and not exempt(rel_path, line):
            hits.append((idx + 1, line.rstrip()))
    return hits


# ---------------------------------------------------------------------------
# Phase 2 — palette migration
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("rel_path", AUDITED_FILES)
def test_no_inline_hex_literals(rel_path):
    """No file under audit should contain inline ``#RRGGBB`` hex
    literals at call-sites. The ``_FALLBACK_COLORS`` dict + the
    ``"#000000"`` default in ``gui_shell.py`` are exempt."""
    hits = _scan(rel_path, HEX_PATTERN, _is_color_exempt)
    assert not hits, (
        f"{rel_path}: {len(hits)} inline hex literal(s) remain\n  "
        + "\n  ".join(f"L{ln}: {text}" for ln, text in hits)
    )


def test_gui_shell_C_helper_resolves_to_contract():
    """The ``_C(token)`` helper in ``gui_shell.py`` should resolve
    every contract token to the same value ``get_color(token)``
    would, with the import path live."""
    from tools.visual_contract import get_color, list_color_tokens
    from tools.workflow_gui.gui_shell import _C

    for token in list_color_tokens():
        assert _C(token) == get_color(token), (
            f"_C({token!r}) and get_color({token!r}) disagree"
        )


def test_gui_shell_C_helper_softfails_to_fallback():
    """When the contract is unavailable, ``_C`` should still return a
    ``#RRGGBB`` string — the fallback dict's value, not an
    exception."""
    from tools.workflow_gui.gui_shell import _C, _FALLBACK_COLORS

    # Simulate the unavailable-contract path by passing an unknown
    # token; _C should fall through to the fallback table or to
    # "#000000" (and not raise).
    result = _C("not-a-real-token")
    assert isinstance(result, str)
    assert HEX_PATTERN.match(result), (
        f"_C fallback returned non-hex value: {result!r}"
    )

    # Known tokens must hit the fallback table (the soft-fail path
    # composes with the contract path — both return the same hex).
    for token, expected in _FALLBACK_COLORS.items():
        assert _C(token).lower() == expected.lower(), (
            f"_C({token!r}) -> {_C(token)} != fallback {expected}"
        )


# ---------------------------------------------------------------------------
# Phase 3 — typography migration
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("rel_path", AUDITED_FILES)
def test_no_inline_font_tuples(rel_path):
    """No file under audit should contain inline ``("Helvetica", N)``
    font tuples at call-sites. The helper body / docstring in
    ``gui_shell.py`` is the only exempt occurrence."""
    hits = _scan(rel_path, FONT_PATTERN, _is_font_exempt)
    assert not hits, (
        f"{rel_path}: {len(hits)} inline font tuple(s) remain\n  "
        + "\n  ".join(f"L{ln}: {text}" for ln, text in hits)
    )


def test_gui_shell_F_helper_returns_tuple_of_expected_shape():
    """The ``_F(size[, bold])`` helper should always return a
    Tk-compatible tuple — (family, size) or (family, size, "bold")."""
    from tools.workflow_gui.gui_shell import _F

    plain = _F(11)
    assert isinstance(plain, tuple) and len(plain) == 2, (
        f"_F(11) returned {plain!r}; expected 2-tuple"
    )
    assert isinstance(plain[0], str) and isinstance(plain[1], int)

    bold = _F(14, bold=True)
    assert isinstance(bold, tuple) and len(bold) == 3, (
        f"_F(14, bold=True) returned {bold!r}; expected 3-tuple"
    )
    assert bold[2] == "bold"


def test_gui_shell_F_helper_softfails_to_helvetica():
    """The ``_F`` helper's contract should be: return SOMETHING that
    Tk accepts as a font tuple. Either the live contract or the
    fallback. The fallback returns ``("Helvetica", ...)``."""
    from tools.workflow_gui.gui_shell import _F

    plain = _F(11)
    # The contract-resolved family is Segoe UI on Windows but the
    # stack falls back to Helvetica when nothing is found. Either way
    # the family should be a non-empty string.
    family = plain[0]
    assert family
    assert family in (
        "Segoe UI", "Helvetica", "Arial",
    ), f"_F(11) returned unknown family {family!r}"


# ---------------------------------------------------------------------------
# list_renderer status map migration
# ---------------------------------------------------------------------------

def test_list_renderer_status_colors_have_expected_shape():
    """The ``DEFAULT_STATUS_COLORS`` map should retain its 13-entry
    shape (12 known statuses + the ``None`` sentinel) so the engine's
    consumers don't see a regression in coverage."""
    from node_types.list_renderer import DEFAULT_STATUS_COLORS

    assert len(DEFAULT_STATUS_COLORS) == 13
    expected_keys = {
        "pending", "done", "in_progress", "cancelled", "granted",
        "planning", "granting", "superseded", "resolved", "alert",
        "warn", "ok", None,
    }
    assert set(DEFAULT_STATUS_COLORS) == expected_keys


def test_list_renderer_status_colors_derive_from_contract():
    """When the visual contract is importable, ``DEFAULT_STATUS_COLORS``
    values should match ``status_color(key, "rgb01")`` exactly. This
    enforces the unification claim — 2D + 3D consume one source."""
    from node_types.list_renderer import DEFAULT_STATUS_COLORS
    from tools.visual_contract import status_color

    for key in DEFAULT_STATUS_COLORS:
        if key is None:
            # The None sentinel maps to fg-secondary by contract.
            expected = status_color(None, "rgb01")
        else:
            expected = status_color(key, "rgb01")
        actual = DEFAULT_STATUS_COLORS[key]
        for a, b in zip(actual, expected):
            assert abs(a - b) < 1e-6, (
                f"DEFAULT_STATUS_COLORS[{key!r}]={actual} does not "
                f"derive from contract ({list(expected)})"
            )


def test_list_renderer_status_glyphs_unchanged():
    """The glyph table is unaffected by the palette migration — it
    must keep its 13-entry shape and the same ASCII keys."""
    from node_types.list_renderer import DEFAULT_STATUS_GLYPHS

    assert len(DEFAULT_STATUS_GLYPHS) == 13
    assert DEFAULT_STATUS_GLYPHS["pending"] == "[ ]"
    assert DEFAULT_STATUS_GLYPHS["done"] == "[x]"
    assert DEFAULT_STATUS_GLYPHS[None] == "•"


# ---------------------------------------------------------------------------
# text-API audit verbs
# ---------------------------------------------------------------------------

def test_audit_verbs_registered_in_text_test():
    """Both audit verbs should be registered in ``_COMMANDS`` so
    ``list-commands`` surfaces them."""
    from tools.text_test import _COMMANDS

    assert "visual-contract-audit-colors" in _COMMANDS
    assert "visual-contract-audit-fonts" in _COMMANDS


def test_audit_verbs_pass_against_current_state():
    """The audit verbs should report ``OK`` against the current file
    state — they're the regression boundary the migration installs."""
    from tools.text_test import (
        _cmd_visual_contract_audit_colors,
        _cmd_visual_contract_audit_fonts,
    )

    colors_msg, _ = _cmd_visual_contract_audit_colors(None, None)
    assert colors_msg.startswith("OK"), (
        f"audit-colors regression:\n{colors_msg}"
    )
    fonts_msg, _ = _cmd_visual_contract_audit_fonts(None, None)
    assert fonts_msg.startswith("OK"), (
        f"audit-fonts regression:\n{fonts_msg}"
    )
