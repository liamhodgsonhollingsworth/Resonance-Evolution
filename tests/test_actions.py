"""
Tests for the action primitive (wish #006 cluster):

- engine.actions.dispatch_action routes to the renderer's handle_action.
- View-state lives at engine.cache["__view_state__"][renderer_id].
- Module isolation: a broken handle_action does not crash dispatch.
- Item resolution via the renderer's "source" connection.
- Action validation against the item's declared actions list.
- Renderer-scoped actions (item_id=None) bypass item validation.
- view-state survives engine.precompute() re-runs.
"""

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.actions import (  # noqa: E402
    VIEW_STATE_CACHE_KEY,
    dispatch_action,
    get_view_state,
)


@pytest.fixture
def engine():
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


# ---------------------------------------------------------------------------
# happy path
# ---------------------------------------------------------------------------

def _setup_panel(engine, tmp_path, text="- [ ] alpha\n- [x] beta\n"):
    path = tmp_path / "tasks.md"
    path.write_text(text)
    engine.spawn(
        "src",
        "FileSource",
        params={"path": str(path), "parser_name": "tasks"},
    )
    engine.spawn(
        "panel",
        "ListRenderer",
        params={"title_text": "Tasks", "screen_resolution": 96},
        connections={"source": "src"},
    )
    engine.precompute()


def test_dispatch_action_routes_to_renderer_handle_action(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    ok, msg = dispatch_action(
        engine, "panel", "expand", item_id="task:1"
    )
    assert ok, msg
    state = get_view_state(engine, "panel")
    assert state.get("expanded_item") == "task:1"


def test_dispatch_action_renderer_scoped_action_clears_state(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    # expand first
    dispatch_action(engine, "panel", "expand", item_id="task:1")
    assert get_view_state(engine, "panel").get("expanded_item") == "task:1"
    # collapse with no item-id
    ok, msg = dispatch_action(engine, "panel", "collapse")
    assert ok, msg
    assert get_view_state(engine, "panel").get("expanded_item") is None


def test_view_state_per_renderer_isolated(engine, tmp_path):
    """Two ListRenderers sharing one source still keep separate
    view-state. Touching panel_a's expanded_item must not affect
    panel_b's."""
    _setup_panel(engine, tmp_path)
    engine.spawn(
        "panel_b",
        "ListRenderer",
        params={"title_text": "Tasks-B"},
        connections={"source": "src"},
    )
    dispatch_action(engine, "panel", "expand", item_id="task:1")
    assert get_view_state(engine, "panel").get("expanded_item") == "task:1"
    assert get_view_state(engine, "panel_b").get("expanded_item") is None


def test_view_state_survives_precompute_rerun(engine, tmp_path):
    """A second engine.precompute() must not wipe view-state. precompute
    writes to engine.cache[node_id]; view-state lives under
    engine.cache["__view_state__"][renderer_id]."""
    _setup_panel(engine, tmp_path)
    dispatch_action(engine, "panel", "expand", item_id="task:2")
    engine.precompute()
    assert get_view_state(engine, "panel").get("expanded_item") == "task:2"


# ---------------------------------------------------------------------------
# failure-mode handling
# ---------------------------------------------------------------------------

def test_dispatch_action_unknown_renderer(engine):
    ok, msg = dispatch_action(engine, "no_such_renderer", "expand")
    assert not ok
    assert "unknown renderer" in msg


def test_dispatch_action_dead_renderer(engine):
    engine.spawn(
        "broken",
        "ListRenderer",
        # invalid param shape that build() will reject? actually build()
        # is lenient — force dead state directly for test clarity.
    )
    engine.nodes["broken"].dead = True
    engine.nodes["broken"].error = "test-fixture marked dead"
    ok, msg = dispatch_action(engine, "broken", "expand")
    assert not ok
    assert "dead" in msg


def test_dispatch_action_renderer_type_without_handle_action(engine):
    """A renderer-type that doesn't expose handle_action gets reported,
    not crashed. We use TextRenderer here since it currently has no
    handle_action."""
    engine.spawn("tr", "TextRenderer")
    ok, msg = dispatch_action(engine, "tr", "expand")
    assert not ok
    assert "handle_action" in msg


def test_dispatch_action_item_not_found(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    ok, msg = dispatch_action(engine, "panel", "expand", item_id="task:999")
    assert not ok
    assert "not found" in msg


def test_dispatch_action_action_not_in_item_actions(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    # default actions = ["expand"]; "delete" is not declared
    ok, msg = dispatch_action(
        engine, "panel", "delete", item_id="task:1"
    )
    assert not ok
    assert "not declared" in msg


def test_dispatch_action_module_isolation(engine, tmp_path):
    """A broken handle_action must not crash dispatch. We forge a
    renderer module with a handle_action that raises, and verify
    dispatch returns False without raising."""
    _setup_panel(engine, tmp_path)

    # Replace handle_action on the engine's view of the module with a
    # function that always raises. The engine looks up the module via
    # engine.types[type_name] (not via from-import) so monkey-patching
    # via engine.types is the path that actually changes engine behavior.
    saved = engine.types["ListRenderer"].handle_action
    try:
        def boom(state, action_name, payload, engine_, node):
            raise RuntimeError("kaboom")
        engine.types["ListRenderer"].handle_action = boom
        ok, msg = dispatch_action(engine, "panel", "expand", item_id="task:1")
        assert not ok
        assert "raised" in msg
        # No engine crash. errors list captured the trace.
        assert any("kaboom" in e for e in engine.errors)
    finally:
        engine.types["ListRenderer"].handle_action = saved


# ---------------------------------------------------------------------------
# get_view_state
# ---------------------------------------------------------------------------

def test_get_view_state_creates_empty_dict_for_new_renderer(engine):
    state = get_view_state(engine, "unseen_renderer")
    assert state == {}
    # And the same dict is returned on repeat call (live cache slot).
    state["foo"] = "bar"
    again = get_view_state(engine, "unseen_renderer")
    assert again is state
    assert again.get("foo") == "bar"


def test_view_state_lives_under_reserved_cache_key(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    dispatch_action(engine, "panel", "expand", item_id="task:1")
    assert VIEW_STATE_CACHE_KEY in engine.cache
    assert "panel" in engine.cache[VIEW_STATE_CACHE_KEY]


def test_text_api_invoke_command(engine, tmp_path):
    """The `invoke` text command routes through dispatch_action and
    surfaces an OK/ERR prefix in its result message."""
    from tools.text_test import dispatch_command
    _setup_panel(engine, tmp_path)
    result, _ = dispatch_command(engine, "invoke panel task:1 expand")
    assert result.startswith("OK"), result
    assert get_view_state(engine, "panel").get("expanded_item") == "task:1"


def test_text_api_expand_sugar(engine, tmp_path):
    """The `expand` text command is equivalent to invoking expand."""
    from tools.text_test import dispatch_command
    _setup_panel(engine, tmp_path)
    result, _ = dispatch_command(engine, "expand panel task:2")
    assert result.startswith("OK"), result
    assert get_view_state(engine, "panel").get("expanded_item") == "task:2"


def test_text_api_collapse_sugar(engine, tmp_path):
    """The `collapse` text command targets the renderer; no item-id."""
    from tools.text_test import dispatch_command
    _setup_panel(engine, tmp_path)
    dispatch_command(engine, "expand panel task:1")
    result, _ = dispatch_command(engine, "collapse panel")
    assert result.startswith("OK"), result
    assert get_view_state(engine, "panel").get("expanded_item") is None


def test_text_api_error_messages_carry_through(engine, tmp_path):
    """When the action fails the text command returns an ERR-prefixed
    message that names the failure cause."""
    from tools.text_test import dispatch_command
    _setup_panel(engine, tmp_path)
    result, _ = dispatch_command(engine, "expand panel task:999")
    assert result.startswith("ERR"), result
    assert "not found" in result


def test_text_api_grammar_lists_action_verbs():
    """TextRenderer.command_grammar() includes the three new verbs."""
    from renderers.text import command_grammar
    grammar = "\n".join(command_grammar())
    assert "invoke" in grammar
    assert "expand" in grammar
    assert "collapse" in grammar


def test_dispatch_payload_passthrough(engine, tmp_path):
    """Caller-supplied payload entries should pass through to
    handle_action. Verify by monkey-patching handle_action to record
    the payload it received."""
    _setup_panel(engine, tmp_path)
    received = {}
    saved = engine.types["ListRenderer"].handle_action
    try:
        def record(state, action_name, payload, engine_, node):
            received.update(payload)
            return {"_test_recorded": True}
        engine.types["ListRenderer"].handle_action = record
        ok, _ = dispatch_action(
            engine, "panel", "expand", item_id="task:1",
            payload={"custom_key": "custom_value"},
        )
        assert ok
        assert received.get("custom_key") == "custom_value"
        assert received.get("item_id") == "task:1"
        assert received.get("item", {}).get("title") == "alpha"
    finally:
        engine.types["ListRenderer"].handle_action = saved
