"""
Tests for SPEC-073 module clipboard (copy/paste as text).

Covers serialize / parse / instantiate + the gui_shell wiring +
the text-API copy-module / paste-module commands.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.module_clipboard import (
    instantiate_module,
    parse_module,
    paste_text_to_engine,
    serialize_module,
)


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _engine_with_scene():
    """Build a real Engine with the workflow scene loaded so tests
    exercise the full spawn pipeline."""
    from engine import Engine
    from tools.workflow.trust import render_trust_set

    root = Path(__file__).parent.parent.resolve()
    e = Engine(root_dir=root, trust_set=render_trust_set(root))
    e.discover()
    e.load_scene(root / "scenes" / "workflow_view.json")
    return e


# ---------------------------------------------------------------------------
# serialize_module.
# ---------------------------------------------------------------------------


def test_serialize_single_node_round_trips():
    e = _engine_with_scene()
    text = serialize_module(e, "tasks_source", include_subtree=False)
    payload = json.loads(text)
    assert "module" in payload
    assert len(payload["module"]) == 1
    assert payload["module"][0]["id"] == "tasks_source"
    assert payload["module"][0]["type"] == "FileSource"


def test_serialize_includes_subtree():
    e = _engine_with_scene()
    text = serialize_module(e, "task_panel", include_subtree=True)
    payload = json.loads(text)
    ids = [n["id"] for n in payload["module"]]
    # task_panel + its source.
    assert "task_panel" in ids
    assert "tasks_source" in ids


def test_serialize_unknown_raises():
    e = _engine_with_scene()
    with pytest.raises(KeyError):
        serialize_module(e, "nonexistent")


def test_serialize_preserves_params_and_connections():
    e = _engine_with_scene()
    text = serialize_module(e, "task_panel", include_subtree=False)
    payload = json.loads(text)
    n = payload["module"][0]
    # ListRenderer carries screen_width etc. as params.
    assert "screen_width" in n["params"]
    # Connection to source preserved.
    assert "source" in n["connections"]


# ---------------------------------------------------------------------------
# parse_module.
# ---------------------------------------------------------------------------


def test_parse_canonical_shape():
    text = json.dumps({"module": [{"id": "x", "type": "T", "params": {}, "connections": {}}]})
    module = parse_module(text)
    assert len(module) == 1
    assert module[0]["id"] == "x"


def test_parse_single_node_dict():
    text = json.dumps({"id": "x", "type": "T"})
    module = parse_module(text)
    assert len(module) == 1


def test_parse_bare_list():
    text = json.dumps([{"id": "a", "type": "T"}, {"id": "b", "type": "T"}])
    module = parse_module(text)
    assert len(module) == 2


def test_parse_empty_raises():
    with pytest.raises(ValueError):
        parse_module("")


def test_parse_invalid_json_raises():
    with pytest.raises(ValueError):
        parse_module("not json at all")


def test_parse_missing_id_raises():
    with pytest.raises(ValueError):
        parse_module(json.dumps([{"type": "T"}]))


def test_parse_missing_type_raises():
    with pytest.raises(ValueError):
        parse_module(json.dumps([{"id": "x"}]))


def test_parse_wrong_top_level_raises():
    with pytest.raises(ValueError):
        parse_module(json.dumps({"not_module": []}))


# ---------------------------------------------------------------------------
# instantiate_module.
# ---------------------------------------------------------------------------


def test_instantiate_no_collision_keeps_id():
    e = _engine_with_scene()
    module = [{"id": "fresh_node", "type": "FileSource",
               "params": {"path": "tasks.md", "parser_name": "tasks"},
               "connections": {}}]
    new_ids = instantiate_module(e, module)
    assert new_ids == ["fresh_node"]
    assert "fresh_node" in e.nodes


def test_instantiate_collision_auto_renames():
    e = _engine_with_scene()
    # tasks_source already exists in the loaded scene.
    module = [{"id": "tasks_source", "type": "FileSource",
               "params": {"path": "tasks.md", "parser_name": "tasks"},
               "connections": {}}]
    new_ids = instantiate_module(e, module)
    assert new_ids == ["tasks_source_2"]
    assert "tasks_source_2" in e.nodes
    # Original still present.
    assert "tasks_source" in e.nodes


def test_instantiate_collision_repeated_auto_renames_incrementally():
    e = _engine_with_scene()
    module = [{"id": "tasks_source", "type": "FileSource",
               "params": {"path": "tasks.md", "parser_name": "tasks"},
               "connections": {}}]
    instantiate_module(e, module)
    instantiate_module(e, module)
    new_ids = instantiate_module(e, module)
    assert new_ids == ["tasks_source_4"]


def test_instantiate_no_auto_rename_raises_on_collision():
    e = _engine_with_scene()
    module = [{"id": "tasks_source", "type": "FileSource",
               "params": {"path": "tasks.md", "parser_name": "tasks"},
               "connections": {}}]
    with pytest.raises(ValueError):
        instantiate_module(e, module, auto_rename=False)


def test_instantiate_rewrites_internal_connections():
    """A multi-node snippet where node B references node A by id
    must keep that reference internally consistent after rename."""
    e = _engine_with_scene()
    # Use ids that already exist so both get renamed.
    module = [
        {"id": "tasks_source", "type": "FileSource",
         "params": {"path": "tasks.md", "parser_name": "tasks"},
         "connections": {}},
        {"id": "task_panel", "type": "ListRenderer",
         "params": {"screen_width": 2.0, "screen_height": 4.6,
                    "screen_resolution": 384, "font_size": 12,
                    "title_text": "Pasted", "background_color": [0,0,0],
                    "title_color": [1,1,1]},
         "connections": {"source": "tasks_source"}},
    ]
    new_ids = instantiate_module(e, module)
    assert new_ids == ["tasks_source_2", "task_panel_2"]
    # The pasted panel's source connection should point at the
    # pasted source, not the original.
    new_panel = e.nodes["task_panel_2"]
    assert new_panel.connections["source"] == "tasks_source_2"


def test_instantiate_external_connection_preserved():
    """When a snippet references a node NOT in the snippet, the
    reference passes through unchanged so the new node sees the
    same external target the original did."""
    e = _engine_with_scene()
    module = [
        {"id": "task_panel", "type": "ListRenderer",
         "params": {"screen_width": 2.0, "screen_height": 4.6,
                    "screen_resolution": 384, "font_size": 12,
                    "title_text": "Pasted", "background_color": [0,0,0],
                    "title_color": [1,1,1]},
         "connections": {"source": "external_source_not_in_snippet"}},
    ]
    new_ids = instantiate_module(e, module)
    new_panel = e.nodes[new_ids[0]]
    assert new_panel.connections["source"] == "external_source_not_in_snippet"


# ---------------------------------------------------------------------------
# Round-trip property.
# ---------------------------------------------------------------------------


def test_copy_then_paste_creates_duplicate():
    e = _engine_with_scene()
    text = serialize_module(e, "task_panel", include_subtree=True)
    new_ids = paste_text_to_engine(e, text)
    # task_panel + tasks_source both renamed.
    assert "task_panel_2" in new_ids
    # Duplicate is its own node (different from original).
    assert e.nodes["task_panel_2"].id == "task_panel_2"
    assert e.nodes["task_panel"].id == "task_panel"


def test_round_trip_preserves_params():
    e = _engine_with_scene()
    original_params = dict(e.nodes["task_panel"].params)
    text = serialize_module(e, "task_panel", include_subtree=False)
    paste_text_to_engine(e, text)
    new_params = dict(e.nodes["task_panel_2"].params)
    # Every param round-trips.
    assert new_params == original_params


# ---------------------------------------------------------------------------
# gui_shell wiring.
# ---------------------------------------------------------------------------


def test_gui_shell_copy_returns_text():
    from tools.gui_test_driver import GuiDriver

    drv = GuiDriver()
    drv.build()
    # Drop a node into the stub engine so copy has something to read.
    from engine.node import NodeInstance
    drv.shell.engine.nodes = {  # type: ignore[attr-defined]
        "test_node": NodeInstance(
            id="test_node", type_name="FileSource",
            params={"path": "x.md"}, connections={},
        )
    }
    text = drv.copy_module("test_node")
    assert "test_node" in text
    assert "FileSource" in text


def test_gui_shell_copy_unknown_node_raises():
    from tools.gui_test_driver import GuiDriver

    drv = GuiDriver()
    drv.build()
    drv.shell.engine.nodes = {}  # type: ignore[attr-defined]
    with pytest.raises(KeyError):
        drv.copy_module("nonexistent")


def test_gui_shell_paste_from_text():
    """Paste a JSON snippet directly (no Tk clipboard needed)."""
    from tools.gui_test_driver import GuiDriver
    from engine import Engine
    from tools.workflow.trust import render_trust_set

    drv = GuiDriver()
    drv.build()
    # Swap in a real engine so spawn works.
    root = Path(__file__).parent.parent.resolve()
    real_engine = Engine(root_dir=root, trust_set=render_trust_set(root))
    real_engine.discover()
    drv.shell.engine = real_engine

    text = json.dumps({
        "module": [
            {"id": "pasted_src", "type": "FileSource",
             "params": {"path": "tasks.md", "parser_name": "tasks"},
             "connections": {}},
        ]
    })
    new_ids = drv.paste_module(text)
    assert new_ids == ["pasted_src"]
    assert "pasted_src" in real_engine.nodes


def test_gui_shell_paste_malformed_raises():
    from tools.gui_test_driver import GuiDriver

    drv = GuiDriver()
    drv.build()
    with pytest.raises(ValueError):
        drv.paste_module("not json")


# ---------------------------------------------------------------------------
# text-API integration.
# ---------------------------------------------------------------------------


def test_text_api_copy_module():
    from tools.text_test import dispatch_command

    e = _engine_with_scene()
    msg, _ = dispatch_command(e, "copy-module tasks_source")
    # Should be JSON with a module field.
    assert "module" in msg
    payload = json.loads(msg)
    assert payload["module"][0]["id"] == "tasks_source"


def test_text_api_copy_module_unknown_returns_err():
    from tools.text_test import dispatch_command

    e = _engine_with_scene()
    msg, _ = dispatch_command(e, "copy-module nonexistent")
    assert msg.startswith("ERR:")


def test_text_api_paste_module():
    from tools.text_test import dispatch_command

    e = _engine_with_scene()
    snippet = json.dumps({"module": [
        {"id": "via_text_api", "type": "FileSource",
         "params": {"path": "tasks.md", "parser_name": "tasks"},
         "connections": {}}
    ]})
    msg, _ = dispatch_command(e, f"paste-module {snippet}")
    assert msg.startswith("OK:")
    assert "via_text_api" in e.nodes


def test_text_api_paste_malformed_returns_err():
    from tools.text_test import dispatch_command

    e = _engine_with_scene()
    msg, _ = dispatch_command(e, "paste-module {not-json")
    assert msg.startswith("ERR:")


# ---------------------------------------------------------------------------
# Compose with the engine's discovery cycle.
# ---------------------------------------------------------------------------


def test_paste_then_precompute_yields_items():
    """A pasted FileSource backed by tasks.md must produce items on
    the next precompute — proving the end-to-end paste-to-render
    path is wired."""
    e = _engine_with_scene()
    snippet = json.dumps({
        "module": [
            {"id": "extra_tasks", "type": "FileSource",
             "params": {"path": "tasks.md", "parser_name": "tasks"},
             "connections": {}}
        ]
    })
    paste_text_to_engine(e, snippet)
    e.precompute()
    entry = e.cache.get("extra_tasks", {})
    assert isinstance(entry, dict)
    assert "items" in entry
