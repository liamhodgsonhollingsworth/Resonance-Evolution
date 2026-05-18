"""
Tests for the Tier A wish-cluster: parsers, FileSource, MCPSource,
ListRenderer, WorkflowView, and the workflow_view scene end-to-end.

Covers:
- Parser parses real wishlist/tasks/ideas text correctly.
- FileSource reads a file, applies a parser, caches normalized items.
- FileSource gracefully degrades on missing file or unknown parser.
- MCPSource gracefully degrades when MCP server unavailable.
- MCPSource hands tool result to a parser.
- ListRenderer reads items from a connected source via cache and
  produces a non-empty color channel.
- ListRenderer status glyphs differ per item status.
- ListRenderer renders an error message when the source has an error.
- WorkflowView select_children returns visible children by mode.
- workflow_view.json scene loads, precomputes, and assembles.
- text-API: describe on ListRenderer surfaces items + glyphs.
- text-API: describe on WorkflowView surfaces panel/bar inventory.
"""

import json
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View, look_at  # noqa: E402
from engine.node import EmitContext  # noqa: E402
from node_types.parsers.tasks import parse as parse_tasks  # noqa: E402
from node_types.parsers.wishes import parse as parse_wishes  # noqa: E402
from node_types.parsers.ideas import parse as parse_ideas  # noqa: E402
from node_types import file_source, mcp_source, list_renderer, workflow_view  # noqa: E402


# ---------------------------------------------------------------------------
# Parser tests
# ---------------------------------------------------------------------------

def test_tasks_parser_handles_all_status_glyphs():
    text = (
        "- [ ] open one\n"
        "- [x] done one\n"
        "- [~] in progress one\n"
        "- [-] cancelled one\n"
    )
    items = parse_tasks(text)
    assert len(items) == 4
    assert [i["status"] for i in items] == [
        "pending", "done", "in_progress", "cancelled",
    ]
    assert [i["title"] for i in items] == [
        "open one", "done one", "in progress one", "cancelled one",
    ]


def test_tasks_parser_ids_are_line_based_and_stable():
    text = "- [ ] one\n- [ ] two\n"
    items = parse_tasks(text)
    assert items[0]["id"] == "task:1"
    assert items[1]["id"] == "task:2"
    # Re-parse: same input gives same ids
    items2 = parse_tasks(text)
    assert [i["id"] for i in items] == [i["id"] for i in items2]


def test_tasks_parser_indented_continuation_attaches_to_previous_item():
    text = "- [ ] do thing\n  remember to check X\n  also Y\n"
    items = parse_tasks(text)
    assert len(items) == 1
    assert items[0]["body"] == "remember to check X\nalso Y"


def test_wishes_parser_extracts_number_status_tier_title():
    text = (
        "## Tier A — Foundation\n"
        "\n"
        "- **#001** [pending] — **MCP adapter.** Description here.\n"
        "- **#002** [granted] — **TaskPanel.** Another description.\n"
        "## Tier B — Next\n"
        "- **#010** [planning] — **Full-render mode.** ...\n"
    )
    items = parse_wishes(text)
    assert len(items) == 3
    assert items[0]["meta"]["number"] == 1
    assert items[0]["status"] == "pending"
    assert items[0]["title"] == "MCP adapter."
    assert items[0]["meta"]["tier"].startswith("Tier A")
    assert items[2]["meta"]["tier"].startswith("Tier B")
    assert items[2]["status"] == "planning"


def test_tasks_parser_emits_default_actions_for_every_item():
    text = "- [ ] one\n- [x] two\n"
    items = parse_tasks(text)
    assert items
    for item in items:
        assert item["actions"] == ["expand"]


def test_wishes_parser_emits_default_actions_for_every_item():
    text = "## Tier A\n- **#001** [pending] — **One.** body\n"
    items = parse_wishes(text)
    assert items[0]["actions"] == ["expand"]


def test_default_actions_list_is_per_item_copy_not_shared():
    """Each item must own its actions list — mutating one item's list
    must not mutate any other item's list. Without this guarantee, the
    accumulator pattern (renderers extending an item's actions in-place)
    silently affects siblings."""
    text = "- [ ] one\n- [ ] two\n"
    items = parse_tasks(text)
    items[0]["actions"].append("delete")
    assert items[1]["actions"] == ["expand"]


def test_attach_default_actions_preserves_explicit_actions():
    from node_types.parsers import attach_default_actions
    items = [
        {"id": "a", "title": "with-actions", "actions": ["custom", "expand"]},
        {"id": "b", "title": "without-actions"},
    ]
    attach_default_actions(items)
    assert items[0]["actions"] == ["custom", "expand"]
    assert items[1]["actions"] == ["expand"]


def test_attach_default_actions_accepts_default_override():
    from node_types.parsers import attach_default_actions
    items = [{"id": "a", "title": "no-actions"}]
    attach_default_actions(items, default=["expand", "delete"])
    assert items[0]["actions"] == ["expand", "delete"]


def test_ideas_parser_extracts_entries_under_sections():
    text = (
        "## Queue\n"
        "\n"
        "### 2026-05-16 — A first idea\n"
        "\n"
        "**Source:** session foo\n"
        "**Proposed direction:** promote\n"
        "**Summary:** first.\n"
        "\n"
        "### 2026-05-16 — A second idea\n"
        "\n"
        "**Source:** transcript bar\n"
        "**Summary:** second.\n"
        "\n"
        "## Resolved\n"
        "\n"
        "### 2026-05-15 — An old idea\n"
        "\n"
        "**Source:** archive\n"
    )
    items = parse_ideas(text)
    assert len(items) == 3
    assert [i["status"] for i in items] == ["pending", "pending", "resolved"]
    assert items[0]["title"] == "2026-05-16 — A first idea"
    assert items[0]["meta"].get("source") == "session foo"
    assert items[2]["meta"]["section"].startswith("Resolved")


def test_ideas_parser_emits_default_actions_for_every_item():
    text = (
        "## Queue\n\n"
        "### 2026-05-16 — one\n\n"
        "**Source:** s\n"
    )
    items = parse_ideas(text)
    assert items
    assert items[0]["actions"] == ["expand"]


# ---------------------------------------------------------------------------
# FileSource tests
# ---------------------------------------------------------------------------

@pytest.fixture
def engine():
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def test_filesource_reads_file_and_caches_items(tmp_path, engine):
    path = tmp_path / "tasks.md"
    path.write_text("- [ ] alpha\n- [x] beta\n")
    engine.spawn("src", "FileSource", params={"path": str(path), "parser_name": "tasks"})
    engine.precompute()
    cache = engine.cache.get("src")
    assert cache is not None
    assert cache["error"] is None
    assert len(cache["items"]) == 2
    assert cache["items"][0]["title"] == "alpha"


def test_filesource_missing_file_yields_error_not_crash(engine):
    engine.spawn("src", "FileSource", params={"path": "no_such_file.md", "parser_name": "tasks"})
    engine.precompute()
    cache = engine.cache.get("src")
    assert cache is not None
    assert "not found" in cache["error"].lower()
    assert cache["items"] == []


def test_filesource_unknown_parser_yields_error(tmp_path, engine):
    path = tmp_path / "x.md"
    path.write_text("ignored\n")
    engine.spawn("src", "FileSource", params={"path": str(path), "parser_name": "totally_unknown"})
    engine.precompute()
    cache = engine.cache.get("src")
    assert "not found" in cache["error"].lower()


def test_filesource_emits_items_channel(tmp_path, engine):
    path = tmp_path / "t.md"
    path.write_text("- [ ] one\n")
    engine.spawn("src", "FileSource", params={"path": str(path), "parser_name": "tasks"})
    engine.precompute()
    node = engine.nodes["src"]
    ctx = EmitContext(engine=engine, node=node)
    channels = file_source.emit(node.state, View(), ctx)
    assert len(channels["items"]) == 1
    assert channels["items"][0]["title"] == "one"


# ---------------------------------------------------------------------------
# MCPSource tests (graceful-degrade path; live MCP not required)
# ---------------------------------------------------------------------------

def test_mcpsource_missing_tool_name_yields_error(engine):
    engine.spawn("ms", "MCPSource", params={"tool_name": ""})
    engine.precompute()
    cache = engine.cache.get("ms")
    assert "tool_name required" in cache["error"]


def test_mcpsource_unresolvable_tool_yields_graceful_error(engine, monkeypatch):
    """The engine loads modules via spec_from_file_location, so its view of
    `mcp_source` is a different object than `from node_types import mcp_source`.
    Patch the engine's view via engine.types['MCPSource']."""
    engine_module = engine.types["MCPSource"]
    monkeypatch.setattr(engine_module, "DEFAULT_ALETHEA_TOOLS_PATHS", [])
    engine_module._TOOL_CACHE.clear()
    engine.spawn(
        "ms",
        "MCPSource",
        params={"tool_name": "search", "alethea_tools_path": "/no/such/dir"},
    )
    engine.precompute()
    cache = engine.cache.get("ms")
    assert cache["items"] == []
    assert "could not import" in cache["error"].lower()


def test_mcpsource_applies_parser_to_tool_result(engine, monkeypatch):
    """When a parser is named, the (stringified) tool result is fed to it.
    Patch the engine's view of the module so the precompute hook uses our
    fake resolver."""
    fake_tool_result = "- [ ] from-mcp-task\n- [x] another-mcp-task\n"

    def fake_resolve(name, path):
        if name == "search":
            return lambda **kwargs: fake_tool_result
        return None

    engine_module = engine.types["MCPSource"]
    engine_module._TOOL_CACHE.clear()
    monkeypatch.setattr(engine_module, "_resolve_tool", fake_resolve)
    engine.spawn(
        "ms",
        "MCPSource",
        params={"tool_name": "search", "tool_args": {}, "parser_name": "tasks"},
    )
    engine.precompute()
    cache = engine.cache.get("ms")
    assert cache["error"] is None
    assert len(cache["items"]) == 2
    assert cache["items"][0]["title"] == "from-mcp-task"


# ---------------------------------------------------------------------------
# ListRenderer tests
# ---------------------------------------------------------------------------

def test_listrenderer_reads_items_from_source_cache(tmp_path, engine):
    path = tmp_path / "wishes.md"
    path.write_text(
        "## Tier A\n"
        "- **#001** [pending] — **One.** body\n"
        "- **#002** [granted] — **Two.** body\n"
    )
    engine.spawn("src", "FileSource", params={"path": str(path), "parser_name": "wishes"})
    engine.spawn(
        "renderer",
        "ListRenderer",
        params={"title_text": "Wishlist", "screen_resolution": 128},
        connections={"source": "src"},
    )
    engine.precompute()
    view = View(
        position=np.array([0.0, 0.0, 5.0]),
        orientation=look_at(np.array([0.0, 0.0, 5.0]), np.array([0.0, 0.0, 0.0])),
        width=128,
        height=128,
    )
    channels = engine.assemble("renderer", view)
    assert "color" in channels
    color = channels["color"]
    # Color image populated with non-zero pixels (the panel renders something).
    assert color.shape == (128, 128, 3)
    assert color.sum() > 0


def test_listrenderer_renders_source_error_inline(engine):
    engine.spawn("src", "FileSource", params={"path": "no_file.md", "parser_name": "tasks"})
    engine.spawn(
        "renderer",
        "ListRenderer",
        params={"title_text": "Missing", "screen_resolution": 96},
        connections={"source": "src"},
    )
    engine.precompute()
    node = engine.nodes["renderer"]
    ctx = EmitContext(engine=engine, node=node)
    text = list_renderer.describe(node.state, ctx)
    assert "SOURCE ERROR" in text


def test_listrenderer_describe_lists_items_with_glyphs(tmp_path, engine):
    path = tmp_path / "tasks.md"
    path.write_text("- [ ] alpha\n- [x] beta\n- [~] gamma\n")
    engine.spawn("src", "FileSource", params={"path": str(path), "parser_name": "tasks"})
    engine.spawn(
        "renderer",
        "ListRenderer",
        params={"title_text": "Tasks", "screen_resolution": 96},
        connections={"source": "src"},
    )
    engine.precompute()
    node = engine.nodes["renderer"]
    ctx = EmitContext(engine=engine, node=node)
    text = list_renderer.describe(node.state, ctx)
    assert "Tasks" in text
    assert "[ ] alpha" in text
    assert "[x] beta" in text
    assert "[~] gamma" in text


# ---------------------------------------------------------------------------
# WorkflowView tests
# ---------------------------------------------------------------------------

def test_workflow_view_select_children_panels_mode_returns_panels_and_bars(engine):
    engine.spawn("p", "ListRenderer", params={"title_text": "P"})
    engine.spawn("c", "ListRenderer", params={"title_text": "C"})
    engine.spawn(
        "wv",
        "WorkflowView",
        params={"mode": "panels"},
        connections={"panel_a": "p", "chat_bar": "c"},
    )
    node = engine.nodes["wv"]
    selected = workflow_view.select_children(node.state, View(), engine, node)
    # panel_a goes first per the PANEL_CONNECTIONS ordering, then bar_chat.
    assert selected == ["panel_a", "chat_bar"]


def test_workflow_view_full_render_mode_returns_only_full_render(engine):
    engine.spawn("fr", "ListRenderer", params={"title_text": "FullRender"})
    engine.spawn("p", "ListRenderer", params={"title_text": "P"})
    engine.spawn(
        "wv",
        "WorkflowView",
        params={"mode": "full_render"},
        connections={"panel_a": "p", "full_render": "fr"},
    )
    node = engine.nodes["wv"]
    selected = workflow_view.select_children(node.state, View(), engine, node)
    assert selected == ["full_render"]


def test_workflow_view_describe_summarises_mounted_children(engine):
    engine.spawn("p1", "ListRenderer", params={"title_text": "P1"})
    engine.spawn("p2", "ListRenderer", params={"title_text": "P2"})
    engine.spawn("cb", "ListRenderer", params={"title_text": "Chat"})
    engine.spawn(
        "wv",
        "WorkflowView",
        params={"mode": "panels"},
        connections={"panel_a": "p1", "panel_b": "p2", "chat_bar": "cb"},
    )
    node = engine.nodes["wv"]
    ctx = EmitContext(engine=engine, node=node)
    text = workflow_view.describe(node.state, ctx)
    assert "WorkflowView(mode='panels')" in text
    assert "panel_a" in text and "panel_b" in text
    assert "chat_bar" in text


def test_workflow_view_set_mode_validates_value(engine):
    engine.spawn("wv", "WorkflowView", params={"mode": "panels"})
    node = engine.nodes["wv"]
    workflow_view.set_mode(node, "full_render")
    assert node.state["mode"] == "full_render"
    with pytest.raises(ValueError):
        workflow_view.set_mode(node, "nonsense")


# ---------------------------------------------------------------------------
# End-to-end: workflow_view.json scene loads, precomputes, assembles
# ---------------------------------------------------------------------------

def test_workflow_view_scene_loads_and_renders(engine, tmp_path, monkeypatch):
    """Load the scene, run precompute + assemble, confirm a non-empty
    color channel is produced. Use the actual wishlist.md as the wish
    source; the ideas source is allowed to error out (Alethea path may
    not exist on every machine) — the panel renders the error string
    in-place rather than crashing the scene."""
    scene_path = ROOT / "scenes" / "workflow_view.json"
    assert scene_path.exists()
    engine.load_scene(scene_path)
    engine.precompute()

    # Render at a low resolution for test speed
    view = View(
        position=np.array([0.0, 0.0, 9.0]),
        orientation=look_at(np.array([0.0, 0.0, 9.0]), np.array([0.0, 0.0, 0.0])),
        width=192,
        height=96,
        fov_y_radians=0.6,
    )
    channels = engine.assemble("workflow_view", view)
    assert "color" in channels
    color = channels["color"]
    assert color.shape == (96, 192, 3)
    assert color.sum() > 0  # something was drawn

    # Wishes panel should at minimum have read the wishlist file at project root.
    wish_cache = engine.cache.get("wishes_source", {})
    assert wish_cache.get("items"), "wishes_source should have parsed items from wishlist.md"
    titles = [item["title"] for item in wish_cache["items"]]
    assert any("MCP adapter" in t for t in titles)


def test_workflow_view_scene_panel_isolation(engine, monkeypatch):
    """One panel's source failing must not take down the other panels.
    Confirms the module-isolation guarantee against a real scene."""
    scene_path = ROOT / "scenes" / "workflow_view.json"
    engine.load_scene(scene_path)

    # Sabotage the ideas source by pointing it at a non-existent path.
    engine.nodes["ideas_source"].state["path"] = "/no/such/path/ideas_queue.md"
    engine.precompute()

    # The wish panel still has its items.
    wishes = engine.cache.get("wishes_source", {})
    assert wishes.get("items"), "wishes_source should still have items"
    # The ideas source has an error but no crash.
    ideas = engine.cache.get("ideas_source", {})
    assert ideas.get("error") and not ideas.get("items")

    view = View(
        position=np.array([0.0, 0.0, 9.0]),
        orientation=look_at(np.array([0.0, 0.0, 9.0]), np.array([0.0, 0.0, 0.0])),
        width=128,
        height=64,
        fov_y_radians=0.6,
    )
    channels = engine.assemble("workflow_view", view)
    assert channels["color"].sum() > 0  # render still produces output
