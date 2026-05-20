"""
Tests for the view registry — SPEC-067.

ViewSpec is the declarative shape; ViewRegistry is the ordered map with
archive/restore semantics; default_view_registry() bootstraps the
sidebar contents. These tests pin every primitive the GuiShell + the
text-API ``set-view`` command depend on.
"""

from __future__ import annotations

import pytest

from tools.workflow_gui.view_registry import (
    ViewRegistry,
    ViewSpec,
    default_view_registry,
)


# ---------------------------------------------------------------------------
# ViewSpec.
# ---------------------------------------------------------------------------


def test_view_spec_frozen():
    spec = ViewSpec(name="Tasks", kind="source", source_id="tasks_source")
    with pytest.raises(Exception):
        spec.name = "Renamed"


def test_view_spec_defaults():
    spec = ViewSpec(name="Foo", kind="gui_inbox")
    assert spec.source_id is None
    assert spec.panel_id is None
    assert spec.description == ""
    assert spec.scene_root is None
    assert spec.text_body == ""
    assert spec.custom_renderer is None


# ---------------------------------------------------------------------------
# ViewRegistry construction + registration.
# ---------------------------------------------------------------------------


def test_empty_registry():
    reg = ViewRegistry()
    assert reg.names() == []
    assert reg.list_views() == []
    assert len(reg) == 0


def test_register_one_view():
    reg = ViewRegistry()
    spec = ViewSpec(name="Tasks", kind="source", source_id="tasks_source")
    reg.register(spec)
    assert reg.names() == ["Tasks"]
    assert reg.get("Tasks") is spec
    assert len(reg) == 1


def test_register_preserves_order():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.register(ViewSpec(name="B", kind="source", source_id="b"))
    reg.register(ViewSpec(name="C", kind="source", source_id="c"))
    assert reg.names() == ["A", "B", "C"]


def test_register_replace_keeps_position():
    """Re-registering an existing name updates the spec but keeps the
    view at its prior position in the display order."""
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.register(ViewSpec(name="B", kind="source", source_id="b"))
    reg.register(ViewSpec(name="C", kind="source", source_id="c"))
    # Update B with a different source id.
    reg.register(ViewSpec(name="B", kind="source", source_id="b2"))
    assert reg.names() == ["A", "B", "C"]
    assert reg.get("B").source_id == "b2"


def test_register_invalid_kind_raises():
    reg = ViewRegistry()
    with pytest.raises(ValueError):
        reg.register(ViewSpec(name="X", kind="not-a-kind"))


def test_get_returns_none_for_unknown():
    reg = ViewRegistry()
    assert reg.get("Nonexistent") is None


def test_contains():
    reg = default_view_registry()
    assert "Tasks" in reg
    assert "Nonexistent" not in reg
    assert 42 not in reg  # type-mismatch is safe


# ---------------------------------------------------------------------------
# Archive / restore.
# ---------------------------------------------------------------------------


def test_archive_hides_from_visible():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.register(ViewSpec(name="B", kind="source", source_id="b"))
    assert reg.archive("A") is True
    assert reg.names() == ["B"]
    assert "A" in reg.archived_names()


def test_archive_preserves_spec():
    reg = ViewRegistry()
    spec = ViewSpec(name="A", kind="source", source_id="a")
    reg.register(spec)
    reg.archive("A")
    assert reg.get("A") is spec  # still recoverable


def test_archive_unknown_returns_false():
    reg = ViewRegistry()
    assert reg.archive("Nope") is False


def test_archive_already_archived_returns_false():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.archive("A")
    assert reg.archive("A") is False  # second archive is no-op


def test_restore_brings_back():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.register(ViewSpec(name="B", kind="source", source_id="b"))
    reg.archive("A")
    assert "A" not in reg.names()
    assert reg.restore("A") is True
    # Restored at original position (before B).
    assert reg.names() == ["A", "B"]


def test_restore_unknown_returns_false():
    reg = ViewRegistry()
    assert reg.restore("Nope") is False


def test_is_archived():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    assert reg.is_archived("A") is False
    reg.archive("A")
    assert reg.is_archived("A") is True
    reg.restore("A")
    assert reg.is_archived("A") is False


# ---------------------------------------------------------------------------
# Unregister.
# ---------------------------------------------------------------------------


def test_unregister_removes_completely():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    assert reg.unregister("A") is True
    assert reg.names() == []
    assert reg.get("A") is None


def test_unregister_unknown_returns_false():
    reg = ViewRegistry()
    assert reg.unregister("Nope") is False


def test_unregister_archived():
    """Unregistering an archived view should still clean up the
    archive list (no zombie entries)."""
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.archive("A")
    assert reg.unregister("A") is True
    assert "A" not in reg.archived_names()


# ---------------------------------------------------------------------------
# Backward-compat shim: as_tabs.
# ---------------------------------------------------------------------------


def test_as_tabs_source_kind():
    reg = ViewRegistry()
    reg.register(
        ViewSpec(name="Tasks", kind="source", source_id="tasks_source", panel_id="task_panel")
    )
    assert reg.as_tabs() == [("Tasks", "tasks_source", "task_panel")]


def test_as_tabs_gui_inbox_kind():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="Inbox", kind="gui_inbox"))
    assert reg.as_tabs() == [("Inbox", "_inbox", None)]


def test_as_tabs_3d_kind():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="3D", kind="3d"))
    assert reg.as_tabs() == [("3D", "_3d", None)]


def test_as_tabs_text_kind():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="Logs", kind="text"))
    assert reg.as_tabs() == [("Logs", "_text:Logs", None)]


def test_as_tabs_skips_archived():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a"))
    reg.register(ViewSpec(name="B", kind="source", source_id="b"))
    reg.archive("A")
    assert reg.as_tabs() == [("B", "b", None)]


def test_help_map():
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a", description="A desc"))
    reg.register(ViewSpec(name="B", kind="gui_inbox", description="B desc"))
    assert reg.help_map() == {"A": "A desc", "B": "B desc"}


def test_help_map_falls_back_to_name():
    """When a view has no description, the help map returns the name
    so Ctrl-hover still shows something useful."""
    reg = ViewRegistry()
    reg.register(ViewSpec(name="A", kind="source", source_id="a", description=""))
    assert reg.help_map() == {"A": "A"}


# ---------------------------------------------------------------------------
# Default registry.
# ---------------------------------------------------------------------------


def test_default_registry_has_all_arc_k_tabs():
    """The default registry must preserve every Arc K tab so the
    existing sidebar contents don't drop a view on upgrade."""
    reg = default_view_registry()
    required = {
        "Tasks", "Ideas", "Wishlist", "Inbox", "Chat",
        "Quarantine", "Trusted Senders", "3D",
    }
    visible = set(reg.names())
    assert required.issubset(visible)


def test_default_registry_includes_logs_demonstration():
    """The Logs view is the in-tree demonstration that adding a new
    view is one ViewSpec config row."""
    reg = default_view_registry()
    spec = reg.get("Logs")
    assert spec is not None
    assert spec.kind == "text"


def test_default_registry_specs_have_descriptions():
    """Every visible view's description must be non-empty so Ctrl-hover
    help (SPEC-074) shows something useful for every tab."""
    reg = default_view_registry()
    for spec in reg.list_views():
        assert spec.description, f"view {spec.name!r} has empty description"


def test_default_registry_source_kind_has_required_fields():
    """Source-kind views must specify both source_id and panel_id so
    the data provider + action dispatcher have everything they need."""
    reg = default_view_registry()
    for spec in reg.list_views():
        if spec.kind == "source":
            assert spec.source_id, f"source view {spec.name!r} missing source_id"
            assert spec.panel_id, f"source view {spec.name!r} missing panel_id"


def test_default_registry_kinds_are_legal():
    """No invalid kinds slip through (catches a typo in default_view_registry).

    Kept in sync with VALID_KINDS in view_registry.ViewRegistry.register;
    the registry rejects everything else with ValueError at construction
    time."""
    reg = default_view_registry()
    legal = {
        "source", "gui_inbox", "gui_chat", "3d", "text",
        "web",  # SPEC-066 added 2026-05-20
        "custom", "dynamic",
    }
    for spec in reg.list_views():
        assert spec.kind in legal, f"view {spec.name!r} has illegal kind {spec.kind!r}"
