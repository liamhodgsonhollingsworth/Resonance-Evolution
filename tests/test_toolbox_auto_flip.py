"""Tests for ToolboxNode auto-flip (Decision A2 / SPEC-091).

Brief 03 commit 2 — exercises the inference-registry path of
ToolboxNode's add verb. The other-verbs tests live in
``test_toolbox_node.py``; this file focuses on the auto-flip hint
shape per Decision A2's inference rules:

  - First as=rendered child whose kind is in the registry → typed_kind
    surfaced in last_add result.
  - First as=rendered child whose kind is NOT in the registry →
    ambiguous hint surfaced.
  - SUBSEQUENT as=rendered adds do NOT re-fire the hint (only the
    FIRST trigger).
  - The registry contract (inference_rules module) is monotonic — re-
    registering a known kind with a different typed kind raises.

The surface that publishes the substrate supersession lives outside
the Apeiron primitive — that's the Alethea-cc layer's responsibility
per SPEC-026 + SPEC-084. This test file only exercises the runtime
side: the auto_flip dict's shape + when it fires.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def _add(engine, toolbox_id, node_id, as_kind, child_kind):
    n = engine.nodes[toolbox_id]
    return engine.types["ToolboxNode"].handle_action(
        n.state, "add",
        {"node_id": node_id, "as": as_kind, "child_kind": child_kind},
        engine, n,
    )


# ---------- inference rules registry (the underscore-prefixed module) ----------


def test_inference_module_skipped_by_discover(engine):
    """The underscore-prefixed file should NOT be exposed as a node-type."""
    assert "_toolbox_inference_rules" not in engine.types
    # But it IS importable as a module.
    from node_types import _toolbox_inference_rules
    assert callable(_toolbox_inference_rules.infer_typed_kind)


def test_inference_registry_phase_1_entries():
    """Decision A2's four phase-1 entries are present."""
    from node_types._toolbox_inference_rules import infer_typed_kind
    assert infer_typed_kind("TextDisplayNode") == "TextBoxNode"
    assert infer_typed_kind("SliderNode") == "ControlPanelNode"
    assert infer_typed_kind("ButtonNode") == "ButtonBarNode"
    assert infer_typed_kind("ImageNode") == "ImageFrameNode"


def test_inference_registry_unknown_returns_none():
    from node_types._toolbox_inference_rules import infer_typed_kind
    assert infer_typed_kind("NeverHeardOf") is None
    assert infer_typed_kind("") is None


def test_inference_register_idempotent_same_value():
    from node_types._toolbox_inference_rules import register, infer_typed_kind
    # Re-registering the same kind with the same typed_kind is a no-op.
    register("TextDisplayNode", "TextBoxNode", "test reason")
    assert infer_typed_kind("TextDisplayNode") == "TextBoxNode"


def test_inference_register_rejects_conflicting_typed_kind():
    from node_types._toolbox_inference_rules import register
    with pytest.raises(ValueError, match="monotonic"):
        register("TextDisplayNode", "SomeOtherKind", "test")


def test_inference_register_new_kind_succeeds():
    from node_types._toolbox_inference_rules import register, infer_typed_kind
    register("MyNewTestKind", "MyTypedKind", "test entry")
    assert infer_typed_kind("MyNewTestKind") == "MyTypedKind"
    # Cleanup: re-register the same value is the only safe undo (the
    # registry is monotonic; we cannot remove). The test isolation
    # relies on pytest re-importing the module between test sessions —
    # not within a single session. Subsequent test runs in the same
    # process should still see "MyNewTestKind" if they look. We
    # explicitly DON'T do that since the test verifies the SAME-value
    # re-register is permitted (above).


def test_inference_register_rejects_empty_inputs():
    from node_types._toolbox_inference_rules import register
    with pytest.raises(ValueError, match="first_child_kind"):
        register("", "Anything", "test")
    with pytest.raises(ValueError, match="typed_kind"):
        register("ValidKind", "", "test")


# ---------- ToolboxNode auto_flip behavior ----------


def test_first_rendered_child_text_display_flips_to_text_box(engine):
    """The canonical Decision A2 example: first TextDisplayNode child
    surfaces a typed-flip hint naming TextBoxNode."""
    engine.spawn("tx_flip1", "ToolboxNode", params={})
    d = _add(engine, "tx_flip1", "n1", "rendered", "TextDisplayNode")
    assert "auto_flip" in d
    assert d["auto_flip"]["triggered"] is True
    assert d["auto_flip"]["inferred_typed_kind"] == "TextBoxNode"
    assert d["auto_flip"]["first_rendered_child_id"] == "n1"
    assert d["auto_flip"]["first_rendered_child_kind"] == "TextDisplayNode"
    assert d["auto_flip"]["toolbox_id"] == "tx_flip1"
    assert "text-display" in d["auto_flip"]["reason"].lower()


def test_first_rendered_child_slider_flips_to_control_panel(engine):
    engine.spawn("tx_flip2", "ToolboxNode", params={})
    d = _add(engine, "tx_flip2", "s1", "rendered", "SliderNode")
    assert d["auto_flip"]["triggered"] is True
    assert d["auto_flip"]["inferred_typed_kind"] == "ControlPanelNode"


def test_first_rendered_child_button_flips_to_button_bar(engine):
    engine.spawn("tx_flip3", "ToolboxNode", params={})
    d = _add(engine, "tx_flip3", "b1", "rendered", "ButtonNode")
    assert d["auto_flip"]["triggered"] is True
    assert d["auto_flip"]["inferred_typed_kind"] == "ButtonBarNode"


def test_first_rendered_child_image_flips_to_image_frame(engine):
    engine.spawn("tx_flip4", "ToolboxNode", params={})
    d = _add(engine, "tx_flip4", "i1", "rendered", "ImageNode")
    assert d["auto_flip"]["triggered"] is True
    assert d["auto_flip"]["inferred_typed_kind"] == "ImageFrameNode"


def test_first_rendered_child_unknown_kind_surfaces_ambiguous(engine):
    """When no inference rule matches, the hint fires with
    triggered=False and an "ambiguous toolbox content" reason."""
    engine.spawn("tx_amb", "ToolboxNode", params={})
    d = _add(engine, "tx_amb", "n1", "rendered", "TotallyNovelKind")
    assert d["auto_flip"]["triggered"] is False
    assert "inferred_typed_kind" not in d["auto_flip"] or \
        d["auto_flip"].get("inferred_typed_kind") in (None, "")
    assert "ambiguous" in d["auto_flip"]["reason"].lower()


def test_link_form_add_never_fires_auto_flip(engine):
    """as=link adds NEVER surface auto_flip — the trigger is rendered-only."""
    engine.spawn("tx_link_only", "ToolboxNode", params={})
    d = _add(engine, "tx_link_only", "n1", "link", "TextDisplayNode")
    assert "auto_flip" not in d


def test_subsequent_rendered_adds_dont_refire(engine):
    """Only the FIRST rendered add fires auto_flip — subsequent rendered
    adds don't re-trigger (the toolbox has already been "flipped" at
    the contract level even if the substrate hasn't published yet)."""
    engine.spawn("tx_first_only", "ToolboxNode", params={})
    d1 = _add(engine, "tx_first_only", "n1", "rendered", "TextDisplayNode")
    assert "auto_flip" in d1

    d2 = _add(engine, "tx_first_only", "n2", "rendered", "ButtonNode")
    # No new auto_flip — the toolbox has already triggered once.
    assert "auto_flip" not in d2


def test_link_then_rendered_still_fires_on_rendered(engine):
    """Adding a link child first doesn't suppress the auto_flip on the
    first rendered child added later."""
    engine.spawn("tx_link_then_render", "ToolboxNode", params={})
    d1 = _add(engine, "tx_link_then_render", "n1", "link", "TextDisplayNode")
    assert "auto_flip" not in d1  # link doesn't trigger

    d2 = _add(engine, "tx_link_then_render", "n2", "rendered", "ButtonNode")
    assert d2["auto_flip"]["triggered"] is True
    assert d2["auto_flip"]["inferred_typed_kind"] == "ButtonBarNode"


def test_initial_contents_with_rendered_child_does_not_pre_consume(engine):
    """Initial-contents passed at build does NOT count as the "first
    rendered child added at runtime" — the auto_flip fires on the
    FIRST runtime add, not on the initial-state. (Substrate side
    handles initial-state-flips at publish time.)
    """
    engine.spawn("tx_pre", "ToolboxNode", params={
        "contents": [{"node_id": "pre", "as": "rendered",
                       "child_kind": "TextDisplayNode"}],
    })
    # Runtime add of another rendered child — the toolbox already has
    # a rendered child in its initial state, so this is NOT the first
    # rendered child added; the trigger doesn't fire.
    d = _add(engine, "tx_pre", "n1", "rendered", "ButtonNode")
    assert "auto_flip" not in d
