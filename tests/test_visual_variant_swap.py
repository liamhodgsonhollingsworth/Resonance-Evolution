"""Tests for visual-variant swap on the brief 03 control primitives.

Brief 03 commit 3 — Scenario 2 of the per-module plan's plan-testing
scenarios + the test_visual_variant_swap.py file the plan names in
commit 3's ``Tests:`` bullet.

The contract under test (Decision A1 + SPEC-090): the same functional
state, rendered through different visual variants, produces different
output BUT the functional state itself is unchanged. Specifically:

  1. The functional primitive's state survives an ``displayed_by:``
     swap — value/min/max/etc. unchanged.
  2. Different variants registered for the same primitive produce
     different rendered output for the same primitive_state.
  3. The same variant produces identical output for identical input
     (renderer determinism).
  4. The Apeiron-side raster variant + the Resonance-Website-side HTML
     variant for the same primitive both declare ``presentation-of``
     matching the functional primitive's kind name (manifest validity).

The tests use direct ``render(input)`` invocation of each variant
(import-and-call) rather than substrate dispatch, since the substrate
package is in a different repo. This mirrors the unit-test convention
used by the Resonance-Website renderer tests (test_substrate_roundtrip,
test_device_picker).
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.node import EmitContext, look_at  # noqa: E402


PRESENTATIONS_DIR = ROOT / "renderers" / "presentations"


def _load_variant(filename: str):
    """Load a presentation-variant Python module by file path.

    The presentation-variant .py files import _shared via sys.path
    injection (same pattern as Resonance-Website's renderers). We add
    the presentations directory to sys.path so the import resolves.
    """
    if str(PRESENTATIONS_DIR) not in sys.path:
        sys.path.insert(0, str(PRESENTATIONS_DIR))
    path = PRESENTATIONS_DIR / filename
    spec = importlib.util.spec_from_file_location(path.stem, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


# ---------- Functional state survives displayed_by swap ----------


def test_scroll_bar_state_survives_displayed_by_swap(engine):
    """Setting displayed_by leaves functional state unchanged."""
    engine.spawn("sb_orig", "ScrollBarNode",
                 params={"min": 0.0, "max": 1.0, "value": 0.42,
                         "orientation": "vertical"})
    engine.spawn("sb_swap", "ScrollBarNode",
                 params={"min": 0.0, "max": 1.0, "value": 0.42,
                         "orientation": "vertical",
                         "displayed_by": "scroll_bar_chunky_v1"})
    a = engine.nodes["sb_orig"].state
    b = engine.nodes["sb_swap"].state
    # Functional fields identical; only displayed_by differs.
    for k in ("min", "max", "value", "orientation"):
        assert a[k] == b[k], f"functional field {k!r} drifted on swap"
    assert a["displayed_by"] == ""
    assert b["displayed_by"] == "scroll_bar_chunky_v1"


def test_slider_state_survives_displayed_by_swap(engine):
    engine.spawn("sl_a", "SliderNode",
                 params={"min": -5.0, "max": 5.0, "value": 1.5, "step": 0.5})
    engine.spawn("sl_b", "SliderNode",
                 params={"min": -5.0, "max": 5.0, "value": 1.5, "step": 0.5,
                         "displayed_by": "slider_knob_v1"})
    a = engine.nodes["sl_a"].state
    b = engine.nodes["sl_b"].state
    for k in ("min", "max", "value", "step", "orientation"):
        assert a[k] == b[k]
    assert b["displayed_by"] == "slider_knob_v1"


def test_dropdown_state_survives_displayed_by_swap(engine):
    options = [{"id": "x", "label": "X"}, {"id": "y", "label": "Y"}]
    engine.spawn("dd_a", "DropdownNode",
                 params={"options": list(options), "selected": "y"})
    engine.spawn("dd_b", "DropdownNode",
                 params={"options": list(options), "selected": "y",
                         "displayed_by": "dropdown_chunky_v1"})
    a = engine.nodes["dd_a"].state
    b = engine.nodes["dd_b"].state
    assert a["options"] == b["options"]
    assert a["selected"] == b["selected"]


# ---------- Variants produce different output for the same state ----------


def _scroll_bar_state(value: float = 0.42, orientation: str = "vertical") -> dict:
    return {
        "screen_width": 0.4, "screen_height": 2.0, "screen_resolution": 64,
        "min": 0.0, "max": 1.0, "value": value, "orientation": orientation,
        "track_color": [0.2, 0.22, 0.28], "thumb_color": [0.55, 0.60, 0.70],
    }


def _slider_state(value: float = 0.5) -> dict:
    return {
        "screen_width": 2.0, "screen_height": 0.4, "screen_resolution": 64,
        "min": 0.0, "max": 1.0, "value": value, "step": 0.01,
        "orientation": "horizontal",
        "track_color": [0.18, 0.20, 0.26],
        "thumb_color": [0.62, 0.70, 0.82],
    }


def _dropdown_state(selected: str = "a") -> dict:
    return {
        "screen_width": 2.5, "screen_height": 0.5, "screen_resolution": 64,
        "options": [{"id": "a", "label": "Alpha"},
                    {"id": "b", "label": "Beta"},
                    {"id": "c", "label": "Gamma"}],
        "selected": selected,
        "background_color": [0.16, 0.18, 0.24],
        "text_color": [0.92, 0.93, 0.88],
        "chevron_color": [0.62, 0.70, 0.82],
    }


def test_scroll_bar_variants_produce_different_output_same_state():
    """Three variants × same state → three distinct rasters."""
    state = _scroll_bar_state()
    inp = {"primitive_state": state, "context": {}}
    minimal = _load_variant("scroll_bar_minimal_v1.py").render(inp)
    chunky = _load_variant("scroll_bar_chunky_v1.py").render(inp)
    thin = _load_variant("scroll_bar_thin_v1.py").render(inp)

    # All three are RGB float32 arrays.
    for arr in (minimal, chunky, thin):
        assert arr.dtype == np.float32
        assert arr.ndim == 3 and arr.shape[2] == 3

    # And pairwise distinct — variant identity is the visual differential.
    assert not np.array_equal(minimal, chunky)
    assert not np.array_equal(minimal, thin)
    assert not np.array_equal(chunky, thin)


def test_slider_variants_produce_different_output_same_state():
    state = _slider_state()
    inp = {"primitive_state": state, "context": {}}
    minimal = _load_variant("slider_minimal_v1.py").render(inp)
    chunky = _load_variant("slider_chunky_v1.py").render(inp)
    knob = _load_variant("slider_knob_v1.py").render(inp)

    for arr in (minimal, chunky, knob):
        assert arr.dtype == np.float32
        assert arr.ndim == 3 and arr.shape[2] == 3

    assert not np.array_equal(minimal, chunky)
    assert not np.array_equal(minimal, knob)
    assert not np.array_equal(chunky, knob)


def test_dropdown_variants_produce_different_output_same_state():
    state = _dropdown_state()
    inp = {"primitive_state": state, "context": {}}
    minimal = _load_variant("dropdown_minimal_v1.py").render(inp)
    chunky = _load_variant("dropdown_chunky_v1.py").render(inp)
    radial = _load_variant("dropdown_radial_v1.py").render(inp)

    for arr in (minimal, chunky, radial):
        assert arr.dtype == np.float32
        assert arr.ndim == 3 and arr.shape[2] == 3

    assert not np.array_equal(minimal, chunky)
    assert not np.array_equal(minimal, radial)
    assert not np.array_equal(chunky, radial)


# ---------- Variants are deterministic ----------


def test_scroll_bar_minimal_variant_is_deterministic():
    state = _scroll_bar_state(value=0.5)
    inp = {"primitive_state": state, "context": {}}
    mod = _load_variant("scroll_bar_minimal_v1.py")
    a = mod.render(inp)
    b = mod.render(inp)
    np.testing.assert_array_equal(a, b)


def test_slider_knob_variant_is_deterministic():
    state = _slider_state(value=0.7)
    inp = {"primitive_state": state, "context": {}}
    mod = _load_variant("slider_knob_v1.py")
    a = mod.render(inp)
    b = mod.render(inp)
    np.testing.assert_array_equal(a, b)


# ---------- Variants respond to functional-state changes ----------


def test_scroll_bar_chunky_responds_to_value_change():
    """Same variant, different value → different output (variant is
    NOT a constant-output dummy)."""
    inp_lo = {"primitive_state": _scroll_bar_state(value=0.0), "context": {}}
    inp_hi = {"primitive_state": _scroll_bar_state(value=1.0), "context": {}}
    mod = _load_variant("scroll_bar_chunky_v1.py")
    lo = mod.render(inp_lo)
    hi = mod.render(inp_hi)
    assert not np.array_equal(lo, hi)


def test_slider_knob_responds_to_value_change():
    inp_lo = {"primitive_state": _slider_state(value=0.0), "context": {}}
    inp_hi = {"primitive_state": _slider_state(value=1.0), "context": {}}
    mod = _load_variant("slider_knob_v1.py")
    lo = mod.render(inp_lo)
    hi = mod.render(inp_hi)
    assert not np.array_equal(lo, hi)


def test_dropdown_chunky_responds_to_selection_change():
    inp_a = {"primitive_state": _dropdown_state(selected="a"), "context": {}}
    inp_b = {"primitive_state": _dropdown_state(selected="b"), "context": {}}
    mod = _load_variant("dropdown_chunky_v1.py")
    a = mod.render(inp_a)
    b = mod.render(inp_b)
    assert not np.array_equal(a, b)


# ---------- Variant manifests are well-formed ----------


def test_all_variants_declare_presentation_of():
    """Each variant .md declares presentation-of matching the primitive
    kind name. Caught at static-read time so a future commit can't
    silently break the function/visual binding contract."""
    expected = {
        "scroll_bar_minimal_v1.md": "ScrollBarNode",
        "scroll_bar_chunky_v1.md": "ScrollBarNode",
        "scroll_bar_thin_v1.md": "ScrollBarNode",
        "slider_minimal_v1.md": "SliderNode",
        "slider_chunky_v1.md": "SliderNode",
        "slider_knob_v1.md": "SliderNode",
        "dropdown_minimal_v1.md": "DropdownNode",
        "dropdown_chunky_v1.md": "DropdownNode",
        "dropdown_radial_v1.md": "DropdownNode",
    }
    for filename, kind in expected.items():
        path = PRESENTATIONS_DIR / filename
        assert path.exists(), f"missing variant manifest: {filename}"
        text = path.read_text(encoding="utf-8")
        assert f"presentation-of: {kind}" in text, (
            f"{filename} missing 'presentation-of: {kind}' in frontmatter"
        )


def test_all_variants_declare_kind_renderer():
    """Each variant manifest declares kind: renderer (Decision A1 +
    SPEC-082 reuse pattern). The substrate's _execute_renderer
    dispatches on this kind."""
    for path in PRESENTATIONS_DIR.glob("*_v1.md"):
        text = path.read_text(encoding="utf-8")
        assert "kind: renderer" in text, (
            f"{path.name} missing 'kind: renderer' in frontmatter"
        )


def test_all_variants_declare_renderer_spec_body_format():
    """Each variant manifest declares body-format: renderer-spec so the
    substrate's evaluator parses it via the same path as full-document
    renderers (Cross-cut X1 from the per-module plan)."""
    for path in PRESENTATIONS_DIR.glob("*_v1.md"):
        text = path.read_text(encoding="utf-8")
        assert "body-format: renderer-spec" in text, (
            f"{path.name} missing 'body-format: renderer-spec' in frontmatter"
        )


# ---------- Engine emit composes with variant choice (forward-compat slot) ----------


def test_default_emit_path_does_not_require_displayed_by(engine):
    """When displayed_by is empty, the primitive's own emit() handles
    rendering. Variants are an additive override per Decision A1; the
    primitive remains self-sufficient."""
    view = View(
        position=np.array([0.0, 0.0, 5.0], dtype=np.float64),
        orientation=look_at(
            np.array([0.0, 0.0, 5.0]),
            np.array([0.0, 0.0, 0.0]),
        ),
        width=32, height=32,
    )
    engine.spawn("sb_def", "ScrollBarNode", params={"value": 0.5})
    n = engine.nodes["sb_def"]
    ch = engine.types["ScrollBarNode"].emit(
        n.state, view, EmitContext(engine=engine, node=n)
    )
    assert ch["color"].shape == (view.height, view.width, 3)
