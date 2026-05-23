"""test_paste_command.py — tests for the SPEC-087 `paste.add` CLI verb.

Per brief 02 commit 4 (Decision B3, SPEC-087).

Covers:
- The `paste.add` command's argument-parsing surface.
- Dispatcher integration: pasted text routes per Decision B3.
- `--skip-spawn` dry-run mode returns the decision without spawning.
- Base64-encoded payload decoding (the canonical CLI-bridge form).
- MIME hint + source hint propagation.
- Unsupported-kind error path (until brief 03 lands the type-names,
  the spawn fails predictably and the dispatch decision is still
  reported).
- The `paste.dispatch-info` introspection command.

The test bypasses Streamlit + the full engine — it constructs a thin
CommandContext + a minimal engine stub, dispatches via the registered
command, and asserts on the CommandResult shape. Per SPEC-081 the
command surface is the system's text-API; this test pins the contract.

Run:
    cd Apeiron && python -m pytest tests/test_paste_command.py -v
"""
from __future__ import annotations

import base64
import json
import sys
from pathlib import Path
from typing import Any, Dict, List

import pytest

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.command_registry import (  # noqa: E402
    Command,
    CommandContext,
    CommandRegistry,
    CommandResult,
)
from tools.workflow_streamlit.commands import (  # noqa: E402
    _allocate_paste_node_id,
    _paste_decode_content,
    _PASTE_KIND_TO_TYPE_NAME,
    _try_import_paste_dispatch,
    build_paste_commands,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


class _FakeViewState:
    """Mock view-state carrier — records dispatch calls + serves predictable
    `last_spawn` payloads so the spawn-success / spawn-failure paths are
    exercisable without a real SceneMutator."""

    def __init__(self) -> None:
        self.dispatch_calls: List[Dict[str, Any]] = []
        self.last_spawn: Dict[str, Any] = {}


class _FakeEngine:
    """Minimal engine stub for command tests.

    Tracks node ids in `nodes` so `_allocate_paste_node_id` exercises
    collision avoidance. The `actions.dispatch_action` mock records each
    call and writes a configurable `last_spawn` view-state payload.
    """

    def __init__(self) -> None:
        self.nodes: Dict[str, Any] = {}
        self.cache: Dict[str, Any] = {}
        self._view_states: Dict[str, Dict[str, Any]] = {}
        self.dispatch_log: List[Dict[str, Any]] = []
        self.spawn_should_succeed = True

    def set_node_present(self, node_id: str) -> None:
        self.nodes[node_id] = object()

    def dispatch(
        self,
        renderer_id: str,
        action_name: str,
        payload: Dict[str, Any],
    ) -> None:
        self.dispatch_log.append(
            {"renderer_id": renderer_id, "action_name": action_name, "payload": payload}
        )
        state = self._view_states.setdefault(renderer_id, {})
        if action_name == "spawn":
            node_id = payload.get("node_id", "")
            type_name = payload.get("type_name", "")
            if self.spawn_should_succeed:
                state["last_spawn"] = {
                    "spawned": True,
                    "node_id": node_id,
                    "type_name": type_name,
                }
                if node_id:
                    self.nodes[node_id] = object()
            else:
                state["last_spawn"] = {
                    "spawned": False,
                    "reason": "stubbed scene_mutator failure",
                }

    def get_view_state(self, renderer_id: str) -> Dict[str, Any]:
        return self._view_states.get(renderer_id, {})


@pytest.fixture
def fake_engine() -> _FakeEngine:
    return _FakeEngine()


@pytest.fixture
def patch_engine_actions(monkeypatch: pytest.MonkeyPatch, fake_engine: _FakeEngine):
    """Patch `engine.actions.dispatch_action` + `get_view_state` so the
    command-handler's lookup hits the fake engine."""
    import engine.actions as engine_actions

    monkeypatch.setattr(
        engine_actions,
        "dispatch_action",
        lambda eng, renderer_id, action_name, payload=None: fake_engine.dispatch(
            renderer_id, action_name, payload or {}
        ),
    )
    monkeypatch.setattr(
        engine_actions,
        "get_view_state",
        lambda eng, renderer_id: fake_engine.get_view_state(renderer_id),
    )
    return engine_actions


@pytest.fixture
def cmd_context(tmp_path: Path, fake_engine: _FakeEngine) -> CommandContext:
    """Minimal CommandContext for paste-command tests."""

    class _FakeConfig:
        state_dir = tmp_path

    return CommandContext(
        engine=fake_engine,
        session_manager=None,
        inbox=None,
        file_watcher=None,
        config=_FakeConfig(),
        apeiron_root=APEIRON_ROOT,
        active_session_id=None,
        user="maintainer",
        scratch={},
    )


# ---------------------------------------------------------------------------
# Helper-function tests
# ---------------------------------------------------------------------------


class TestPasteDecodeContent:
    def test_passes_through_plain_text(self):
        text, was_b64 = _paste_decode_content("hello world")
        assert text == "hello world"
        assert was_b64 is False

    def test_decodes_base64_utf8(self):
        b64 = base64.b64encode("hello".encode("utf-8")).decode("ascii")
        text, was_b64 = _paste_decode_content(b64)
        assert text == "hello"
        assert was_b64 is True

    def test_decodes_base64_with_data_uri(self):
        original = "data:image/png;base64,iVBORw0KGgo="
        b64 = base64.b64encode(original.encode("utf-8")).decode("ascii")
        text, was_b64 = _paste_decode_content(b64)
        assert text == original
        assert was_b64 is True

    def test_text_with_spaces_is_not_decoded(self):
        # Spaces mean it can't be base64; should pass through.
        text, was_b64 = _paste_decode_content("hello world (with spaces)")
        assert was_b64 is False


class TestAllocatePasteNodeId:
    def test_returns_base_when_no_collision(self, cmd_context):
        chosen = _allocate_paste_node_id(cmd_context, "pasted_text_node")
        assert chosen == "pasted_text_node"

    def test_increments_when_collision(self, cmd_context, fake_engine):
        fake_engine.set_node_present("pasted_text_node")
        chosen = _allocate_paste_node_id(cmd_context, "pasted_text_node")
        assert chosen == "pasted_text_node_2"

    def test_finds_smallest_free_suffix(self, cmd_context, fake_engine):
        fake_engine.set_node_present("pasted_text_node")
        fake_engine.set_node_present("pasted_text_node_2")
        fake_engine.set_node_present("pasted_text_node_3")
        chosen = _allocate_paste_node_id(cmd_context, "pasted_text_node")
        assert chosen == "pasted_text_node_4"


# ---------------------------------------------------------------------------
# Toolbox import path
# ---------------------------------------------------------------------------


class TestTryImportPasteDispatch:
    def test_dispatcher_is_importable(self):
        pd, err = _try_import_paste_dispatch()
        assert err is None
        assert pd is not None
        assert hasattr(pd, "dispatch")


# ---------------------------------------------------------------------------
# build_paste_commands shape
# ---------------------------------------------------------------------------


class TestBuildPasteCommands:
    def test_two_commands_registered(self):
        cmds = build_paste_commands()
        names = {c.name for c in cmds}
        assert names == {"paste.add", "paste.dispatch-info"}

    def test_paste_add_has_usage(self):
        cmds = build_paste_commands()
        paste_add = next(c for c in cmds if c.name == "paste.add")
        assert "--mime" in paste_add.arg_help
        assert "--source" in paste_add.arg_help
        assert "--skip-spawn" in paste_add.arg_help


# ---------------------------------------------------------------------------
# paste.add dispatch — dry-run mode (no engine side-effects)
# ---------------------------------------------------------------------------


class TestPasteAddDryRun:
    def _registry(self) -> CommandRegistry:
        r = CommandRegistry()
        r.register_many(build_paste_commands())
        return r

    def test_text_routes_to_text_node(self, cmd_context, patch_engine_actions):
        r = self._registry()
        result = r.run("paste.add --skip-spawn hello world", cmd_context, source="system")
        assert result.ok
        assert result.data["route"] == "text-node"
        assert result.data["kind"] == "text-node"

    def test_url_routes_to_link_node(self, cmd_context, patch_engine_actions):
        r = self._registry()
        result = r.run(
            "paste.add --skip-spawn https://example.com/page",
            cmd_context, source="system",
        )
        assert result.ok
        assert result.data["route"] == "link-node"
        assert result.data["detected_via"] == "url-shape"
        assert result.data["params"]["href"] == "https://example.com/page"

    def test_code_routes_to_code_node(self, cmd_context, patch_engine_actions):
        r = self._registry()
        # Multi-line content can't be passed via shlex split. Build the
        # CommandContext + run the handler directly with explicit args.
        from tools.workflow_streamlit.commands import _paste_add
        result = _paste_add(
            cmd_context,
            ["--skip-spawn", "--", "#!/bin/bash\necho hi"],
        )
        assert result.ok
        assert result.data["route"] == "code-node"
        assert result.data["params"]["language"] == "bash"

    def test_mime_hint_propagates(self, cmd_context, patch_engine_actions):
        from tools.workflow_streamlit.commands import _paste_add
        result = _paste_add(
            cmd_context,
            ["--mime", "text/markdown", "--skip-spawn", "--", "# Heading"],
        )
        assert result.ok
        assert result.data["route"] == "text-node"
        assert result.data["detected_via"] == "mime-markdown"
        assert result.data["params"]["body_format"] == "markdown"

    def test_node_json_routes_to_module_clipboard(self, cmd_context, patch_engine_actions):
        r = self._registry()
        payload = json.dumps({"module": [{"id": "n1", "type": "TextNode"}]})
        b64 = base64.b64encode(payload.encode("utf-8")).decode("ascii")
        result = r.run(
            f"paste.add --skip-spawn {b64}",
            cmd_context, source="system",
        )
        assert result.ok
        assert result.data["route"] == "module_clipboard"
        assert result.data["detected_via"] == "node-json"
        assert result.data["params"] is None  # module-clipboard route has no spawn_spec

    def test_empty_content_errors(self, cmd_context, patch_engine_actions):
        r = self._registry()
        result = r.run("paste.add --skip-spawn", cmd_context, source="system")
        assert not result.ok
        assert "empty" in result.message.lower()


# ---------------------------------------------------------------------------
# paste.add full spawn flow — dispatcher → scene_mutator_main.spawn
# ---------------------------------------------------------------------------


class TestPasteAddSpawnFlow:
    def _registry(self) -> CommandRegistry:
        r = CommandRegistry()
        r.register_many(build_paste_commands())
        return r

    def test_text_paste_dispatches_spawn(self, cmd_context, patch_engine_actions, fake_engine):
        r = self._registry()
        result = r.run("paste.add hello world", cmd_context, source="system")
        assert result.ok, result.message
        # spawn was dispatched against scene_mutator_main with the right type
        spawn_calls = [
            c for c in fake_engine.dispatch_log
            if c["renderer_id"] == "scene_mutator_main" and c["action_name"] == "spawn"
        ]
        assert spawn_calls, "expected a spawn dispatch"
        payload = spawn_calls[0]["payload"]
        assert payload["type_name"] == "TextNode"
        assert payload["params"]["body"] == "hello world"
        assert payload["params"]["body_format"] == "plain"
        # response carries the spawn id and route info
        assert result.data["spawned_id"].startswith("pasted_text_node")
        assert result.data["route"] == "text-node"

    def test_link_paste_dispatches_spawn(self, cmd_context, patch_engine_actions, fake_engine):
        r = self._registry()
        result = r.run(
            "paste.add https://example.com/page", cmd_context, source="system",
        )
        assert result.ok, result.message
        spawn_calls = [
            c for c in fake_engine.dispatch_log
            if c["action_name"] == "spawn"
        ]
        assert spawn_calls
        assert spawn_calls[0]["payload"]["type_name"] == "LinkNode"
        assert spawn_calls[0]["payload"]["params"]["href"] == "https://example.com/page"

    def test_scene_mutator_failure_surfaces(self, cmd_context, patch_engine_actions, fake_engine):
        fake_engine.spawn_should_succeed = False
        r = self._registry()
        result = r.run("paste.add hello", cmd_context, source="system")
        assert not result.ok
        assert "scene_mutator rejected" in result.message
        assert "kind=text-node" in result.message


# ---------------------------------------------------------------------------
# Routing table introspection
# ---------------------------------------------------------------------------


class TestPasteDispatchInfo:
    def test_lists_known_kinds(self, cmd_context, patch_engine_actions):
        r = CommandRegistry()
        r.register_many(build_paste_commands())
        result = r.run("paste.dispatch-info", cmd_context, source="system")
        assert result.ok
        for kind in _PASTE_KIND_TO_TYPE_NAME:
            assert kind in result.message
        # data carries the mapping dict
        for kind, type_name in _PASTE_KIND_TO_TYPE_NAME.items():
            assert result.data[kind] == type_name


# ---------------------------------------------------------------------------
# Per-content fixtures — every dispatch table row spawns the right kind
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "content,mime,expected_route,expected_type",
    [
        ("hello world", None, "text-node", "TextNode"),
        ("# Heading\n\nsome body", None, "text-node", "TextNode"),
        ("https://example.com", None, "link-node", "LinkNode"),
        ("#!/bin/bash\necho hi", None, "code-node", "CodeNode"),
        ("plain", "text/markdown", "text-node", "TextNode"),
    ],
)
def test_dispatch_table_round_trip(
    cmd_context, patch_engine_actions, fake_engine,
    content: str, mime: str, expected_route: str, expected_type: str,
):
    r = CommandRegistry()
    r.register_many(build_paste_commands())
    if mime:
        cmd_str = f"paste.add --mime {mime} -- {content}"
    else:
        cmd_str = f"paste.add -- {content}"
    result = r.run(cmd_str, cmd_context, source="system")
    assert result.ok, f"{cmd_str}: {result.message}"
    spawn_calls = [c for c in fake_engine.dispatch_log if c["action_name"] == "spawn"]
    assert spawn_calls
    assert spawn_calls[0]["payload"]["type_name"] == expected_type
    assert result.data["route"] == expected_route


# ---------------------------------------------------------------------------
# JS handler emission — the renderer's <script> block carries paste-capture
# ---------------------------------------------------------------------------


class TestRendererPasteHandlerEmission:
    """The JS that captures Ctrl+V is embedded in the renderer fragment.

    Per Decision B3 + brief 02 commit 4: when the JS handler fires it
    POSTs the highest-priority payload to the CLI bridge. This test
    asserts the handler text is emitted (not that it runs — that path
    is exercised by the brief 06 plan-testing scenarios with a real
    browser-driver).
    """

    def _render(self):
        from tools.workflow_streamlit.renderers.workflow_continuous_scroll_v1 import render
        wv = {
            "id": "sha256:probe_wv",
            "name": "workflow_view_main",
            "kind": "workflow_view",
            "body-format": "workflow-view",
            "body": {
                "positions": [
                    {
                        "node_id": "n1",
                        "appended_at": "2026-05-22T00:00:00Z",
                        "appended_by": "test",
                        "provenance": {"source": "test"},
                    }
                ],
                "default_paste_location": "end",
                "metadata": {},
            },
        }
        return render({"content_nodes": [wv], "context": {}})

    def test_emits_paste_event_listener(self):
        html = self._render()
        assert "addEventListener('paste'" in html
        assert "handle_paste_event" in html

    def test_emits_priority_chain(self):
        html = self._render()
        # The handler must check image > uri-list > text/plain.
        assert "image/" in html
        assert "text/uri-list" in html
        assert "text/plain" in html

    def test_emits_base64_helper(self):
        html = self._render()
        assert "btoa(" in html

    def test_emits_cli_bridge_endpoint(self):
        html = self._render()
        assert "/cli-bridge/queue" in html
        assert "paste.add" in html

    def test_surface_made_focusable(self):
        html = self._render()
        assert "tabindex" in html
