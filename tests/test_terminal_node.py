"""
Tests for TerminalNode — SPEC-303.

The terminal substrate primitive that landed via the website-MVP
misframing recovery arc (2026-05-23 / 2026-05-24). Maintainer's
closing-turn verbatim spec:

  *"the terminal being a specific node that can be linked to a text
  box node such that I can have rectangle -> text + scroll bar ->
  terminal and the text in the box is then determined full by the
  logic of a CLI."*

These tests cover:

- Engine registration via ``engine.discover()``.
- ``build()`` defaults — every documented field present with the
  documented default.
- ``build()`` value-passthrough — supplied values survive build.
- Invalid ``cli_kind`` / ``visibility`` enum values fall back to a
  documented default (defensive).
- ``describe()`` produces a one-line summary including all three
  bindings + the cli_kind + endpoint.
- ``emit()`` returns empty render channels (no visual contribution —
  rendering happens via the linked text-box nodes).
- ``select_children()`` returns ``[]`` (terminal nodes are dispatch
  hubs; their linked text-boxes are SIBLINGS, not children).
- Round-trip through the standard module-clipboard serializer.
- Verb dispatch — ``submit`` records state transitions; ``get_state``
  is a pure read; ``set_visibility`` cycles through the three states.
- Dispatch handler registration — ``set_dispatch_handler`` /
  ``get_dispatch_handler`` round-trip; submit invokes the registered
  handler with the right shape; handler-returns are normalized
  defensively.
- The three ``cli_kind`` paths (dispatch_web_action / shell /
  python_callable) all route through the same handler interface +
  produce the same state-transition shape.
- Binding integrity — two TerminalNodes can coexist with different
  link sets; the link is via field-reference, not parent-child.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine, View  # noqa: E402
from engine.node import EmitContext  # noqa: E402
from node_types.terminal import (  # noqa: E402
    CLI_KINDS,
    VISIBILITIES,
    _normalize_handler_result,
)


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def _terminal_module(engine_):
    """Return the terminal node-type module THE ENGINE LOADED.

    Apeiron's ``engine.discover()`` imports each node-type module
    under a synthesized name (``apeiron_node_types_<name>``), NOT as
    ``node_types.<name>``. Module-level state (like the dispatch-
    handler slot) lives in the engine-loaded module — the standard
    ``import node_types.terminal`` produces a DIFFERENT module
    object that the verbs never consult. Tests that interact with
    handler registration must address the engine-loaded module.
    """
    return engine_.types["TerminalNode"]


@pytest.fixture(autouse=True)
def _clear_dispatch_handler(engine):
    """Each test starts with no dispatch handler registered (so the
    handler-absent code paths are testable, and registered handlers
    from prior tests don't leak)."""
    _terminal_module(engine).set_dispatch_handler(None)
    yield
    _terminal_module(engine).set_dispatch_handler(None)


# ---------------------------------------------------------------------------
# Registration + manifest
# ---------------------------------------------------------------------------


def test_terminal_node_registers(engine):
    assert "TerminalNode" in engine.types
    m = engine.types["TerminalNode"].manifest()
    assert m.name == "TerminalNode"
    assert m.version == "1.0"


def test_manifest_declares_documented_fields(engine):
    """Every field the SPEC-303 contract names appears in the manifest's
    inputs dict — defensive check that the schema didn't drift away
    from the spec body."""
    m = engine.types["TerminalNode"].manifest()
    documented = {
        "cli_kind", "cli_endpoint", "cli_args_schema", "cli_natural_language",
        "input_node", "output_node", "history_node",
        "visibility", "polling_interval_ms",
        "layer", "displayed_by",
    }
    for field in documented:
        assert field in m.inputs, f"manifest missing input {field!r}"


def test_cli_kinds_enum_matches_arc_handoff():
    """Per arc handoff Section 4.1: the three cli.kind options are
    dispatch_web_action / shell / python_callable. The enum must
    reflect all three so the dispatch routing is complete."""
    assert set(CLI_KINDS) == {"dispatch_web_action", "shell", "python_callable"}


def test_visibilities_enum_matches_existing_terminal_states():
    """Per arc handoff Section 4.1: visibility is hidden / compact /
    expanded — matches the existing bottom-terminal renderer's three-
    state toggle so migration is 1:1."""
    assert set(VISIBILITIES) == {"hidden", "compact", "expanded"}


# ---------------------------------------------------------------------------
# build() — defaults + value-passthrough + enum guards
# ---------------------------------------------------------------------------


def test_build_defaults_full_state(engine):
    engine.spawn("t1", "TerminalNode", params={})
    node = engine.nodes["t1"]
    assert not node.dead
    state = node.state
    assert state["cli_kind"] == "dispatch_web_action"
    assert state["cli_endpoint"] == ""
    assert state["cli_args_schema"] == {}
    assert state["cli_natural_language"] is False
    assert state["input_node"] == ""
    assert state["output_node"] == ""
    assert state["history_node"] == ""
    assert state["visibility"] == "compact"
    assert state["polling_interval_ms"] == 500
    assert state["layer"] == 0
    assert state["displayed_by"] == ""
    # Per-instance state initialized.
    assert state["last_input"] == ""
    assert state["last_output"] == ""
    assert state["history"] == []


def test_build_value_passthrough(engine):
    engine.spawn(
        "t2",
        "TerminalNode",
        params={
            "cli_kind": "shell",
            "cli_endpoint": "ls {{input}}",
            "cli_args_schema": {"cwd": ""},
            "cli_natural_language": False,
            "input_node": "tb_input_1",
            "output_node": "tb_output_1",
            "history_node": "tb_history_1",
            "visibility": "expanded",
            "polling_interval_ms": 250,
            "layer": 5,
        },
    )
    state = engine.nodes["t2"].state
    assert state["cli_kind"] == "shell"
    assert state["cli_endpoint"] == "ls {{input}}"
    assert state["cli_args_schema"] == {"cwd": ""}
    assert state["input_node"] == "tb_input_1"
    assert state["output_node"] == "tb_output_1"
    assert state["history_node"] == "tb_history_1"
    assert state["visibility"] == "expanded"
    assert state["polling_interval_ms"] == 250
    assert state["layer"] == 5


def test_build_invalid_cli_kind_falls_back_to_dispatch_web_action(engine):
    engine.spawn("t3", "TerminalNode", params={"cli_kind": "telepathy"})
    state = engine.nodes["t3"].state
    assert state["cli_kind"] == "dispatch_web_action"


def test_build_invalid_visibility_falls_back_to_compact(engine):
    engine.spawn("t4", "TerminalNode", params={"visibility": "northeast"})
    state = engine.nodes["t4"].state
    assert state["visibility"] == "compact"


def test_build_invalid_args_schema_falls_back_to_empty(engine):
    """A non-dict cli_args_schema must not crash build — defensive."""
    engine.spawn("t5", "TerminalNode", params={"cli_args_schema": "not-a-dict"})
    state = engine.nodes["t5"].state
    assert state["cli_args_schema"] == {}


# ---------------------------------------------------------------------------
# describe() + emit() + select_children()
# ---------------------------------------------------------------------------


def test_describe_one_line_with_all_bindings(engine):
    engine.spawn(
        "t6",
        "TerminalNode",
        params={
            "cli_kind": "dispatch_web_action",
            "cli_endpoint": "bottom_terminal_v1",
            "cli_natural_language": True,
            "input_node": "tb_in",
            "output_node": "tb_out",
            "history_node": "tb_hist",
            "visibility": "compact",
        },
    )
    node = engine.nodes["t6"]
    ctx = EmitContext(engine=engine, node=node)
    text = engine.types["TerminalNode"].describe(node.state, ctx)
    assert "TerminalNode" in text
    assert "dispatch_web_action" in text
    assert "bottom_terminal_v1" in text
    assert "tb_in" in text
    assert "tb_out" in text
    assert "tb_hist" in text
    assert "compact" in text
    # NL flag visible for diagnostics.
    assert "NL" in text


def test_describe_surfaces_unbound_links(engine):
    engine.spawn("t7", "TerminalNode", params={})
    node = engine.nodes["t7"]
    ctx = EmitContext(engine=engine, node=node)
    text = engine.types["TerminalNode"].describe(node.state, ctx)
    assert "unbound" in text.lower()
    assert "unset" in text.lower()


def test_emit_returns_empty_channels(engine):
    """The terminal node has no visual emit — the GUI shell renders
    via the linked text-box nodes the maintainer composes against."""
    engine.spawn("t8", "TerminalNode", params={})
    node = engine.nodes["t8"]
    view = View(width=16, height=12)
    ctx = EmitContext(engine=engine, node=node)
    channels = engine.types["TerminalNode"].emit(node.state, view, ctx)
    assert "color" in channels
    assert "depth" in channels
    assert channels["color"].shape == (12, 16, 3)
    assert channels["color"].sum() == 0
    import numpy as np
    assert np.all(np.isposinf(channels["depth"]))


def test_select_children_returns_empty(engine):
    """Terminal nodes are dispatch hubs; their linked text-boxes are
    SIBLINGS via field-reference, not children. select_children must
    be empty so the engine doesn't try to recurse into the linked
    text-box ids."""
    engine.spawn(
        "t9",
        "TerminalNode",
        params={
            "input_node": "tb_a",
            "output_node": "tb_b",
            "history_node": "tb_c",
        },
    )
    node = engine.nodes["t9"]
    children = engine.types["TerminalNode"].select_children(
        node.state, View(), engine, node,
    )
    assert children == []


# ---------------------------------------------------------------------------
# Verb dispatch — submit / get_state / set_visibility
# ---------------------------------------------------------------------------


def test_submit_without_handler_records_no_op_trace(engine):
    """With no dispatch handler registered (the test default),
    submit records a no-op trace + a NOT-DISPATCHED success=False.
    This is the substrate-level state-transition test — independent
    of the host's dispatch implementation."""
    engine.spawn(
        "t_sub_1",
        "TerminalNode",
        params={"cli_kind": "shell", "cli_endpoint": "echo {{input}}"},
    )
    node = engine.nodes["t_sub_1"]
    delta = engine.types["TerminalNode"].handle_action(
        node.state, "submit", {"text": "hello"}, engine, node,
    )
    assert delta is not None
    assert delta["last_input"] == "hello"
    assert delta["last_submit"]["success"] is False
    assert "no dispatch handler" in delta["last_submit"]["message"].lower()
    # History appended.
    assert len(delta["history"]) == 1
    assert delta["history"][0]["input"] == "hello"
    assert delta["history"][0]["success"] is False


def test_submit_with_handler_dispatches_with_full_payload(engine):
    """submit invokes the registered handler with (cli_kind, endpoint,
    payload). The payload carries the typed text + merged args +
    natural_language flag."""
    received: list[tuple] = []

    def handler(cli_kind, endpoint, payload):
        received.append((cli_kind, endpoint, dict(payload)))
        return (True, "ok", "output-string")

    _terminal_module(engine).set_dispatch_handler(handler)

    engine.spawn(
        "t_sub_2",
        "TerminalNode",
        params={
            "cli_kind": "dispatch_web_action",
            "cli_endpoint": "bottom_terminal_v1",
            "cli_args_schema": {"default_arg": 1},
            "cli_natural_language": True,
        },
    )
    node = engine.nodes["t_sub_2"]
    delta = engine.types["TerminalNode"].handle_action(
        node.state, "submit",
        {"text": "visit_url about", "args": {"override": "x"}},
        engine, node,
    )
    assert len(received) == 1
    cli_kind, endpoint, payload = received[0]
    assert cli_kind == "dispatch_web_action"
    assert endpoint == "bottom_terminal_v1"
    assert payload["text"] == "visit_url about"
    # args merged: schema default + per-call override.
    assert payload["args"]["default_arg"] == 1
    assert payload["args"]["override"] == "x"
    assert payload["natural_language"] is True
    # Delta surfaces the success + output.
    assert delta["last_submit"]["success"] is True
    assert delta["last_output"] == "output-string"


def test_submit_handler_exception_records_failure(engine):
    """A handler that raises does NOT crash submit; the exception is
    captured as a failed dispatch with the type+message in the trace."""
    def handler(cli_kind, endpoint, payload):
        raise RuntimeError("backend down")

    _terminal_module(engine).set_dispatch_handler(handler)

    engine.spawn("t_sub_3", "TerminalNode", params={})
    node = engine.nodes["t_sub_3"]
    delta = engine.types["TerminalNode"].handle_action(
        node.state, "submit", {"text": "x"}, engine, node,
    )
    assert delta["last_submit"]["success"] is False
    assert "RuntimeError" in delta["last_submit"]["message"]
    assert "backend down" in delta["last_submit"]["message"]


def test_history_bounded_at_1024(engine):
    """The in-state history is a working window; bounded so a long-
    running terminal doesn't grow unbounded. The host's action-log
    is the canonical long-term store."""
    def handler(cli_kind, endpoint, payload):
        return (True, "ok", "x")

    _terminal_module(engine).set_dispatch_handler(handler)
    engine.spawn("t_hist", "TerminalNode", params={})
    node = engine.nodes["t_hist"]
    for i in range(1100):
        engine.types["TerminalNode"].handle_action(
            node.state, "submit", {"text": f"cmd-{i}"}, engine, node,
        )
    assert len(node.state["history"]) == 1024
    # Oldest entries dropped; newest preserved.
    assert node.state["history"][-1]["input"] == "cmd-1099"
    assert node.state["history"][0]["input"] == "cmd-76"


def test_get_state_is_pure_read(engine):
    """get_state must not mutate the terminal state."""
    engine.spawn(
        "t_get",
        "TerminalNode",
        params={
            "input_node": "tb_in",
            "output_node": "tb_out",
            "visibility": "expanded",
        },
    )
    node = engine.nodes["t_get"]
    state_snapshot = dict(node.state)
    delta = engine.types["TerminalNode"].handle_action(
        node.state, "get_state", {}, engine, node,
    )
    assert delta["last_get_state"]["visibility"] == "expanded"
    assert delta["last_get_state"]["input_node"] == "tb_in"
    assert delta["last_get_state"]["output_node"] == "tb_out"
    # No mutation of pre-read fields.
    for k in ("input_node", "output_node", "visibility", "cli_kind"):
        assert node.state[k] == state_snapshot[k]


def test_set_visibility_explicit_value(engine):
    engine.spawn("t_vis", "TerminalNode", params={"visibility": "hidden"})
    node = engine.nodes["t_vis"]
    delta = engine.types["TerminalNode"].handle_action(
        node.state, "set_visibility", {"visibility": "expanded"},
        engine, node,
    )
    assert delta["visibility"] == "expanded"
    assert delta["last_set_visibility"]["clamped"] is False
    assert node.state["visibility"] == "expanded"


def test_set_visibility_cycle(engine):
    """Default cycle: hidden -> compact -> expanded -> hidden."""
    engine.spawn("t_cyc", "TerminalNode", params={"visibility": "hidden"})
    node = engine.nodes["t_cyc"]
    seq = []
    for _ in range(4):
        engine.types["TerminalNode"].handle_action(
            node.state, "set_visibility", {"visibility": "cycle"},
            engine, node,
        )
        seq.append(node.state["visibility"])
    assert seq == ["compact", "expanded", "hidden", "compact"]


def test_set_visibility_invalid_clamps_to_compact(engine):
    engine.spawn("t_clmp", "TerminalNode", params={"visibility": "hidden"})
    node = engine.nodes["t_clmp"]
    delta = engine.types["TerminalNode"].handle_action(
        node.state, "set_visibility", {"visibility": "invisible-ink"},
        engine, node,
    )
    assert delta["visibility"] == "compact"
    assert delta["last_set_visibility"]["clamped"] is True


def test_unknown_action_returns_none(engine):
    """An unrecognized action name returns None — caller distinguishes
    'verb not on this node' from 'verb dispatched and returned no
    delta' by the None-vs-dict result."""
    engine.spawn("t_unk", "TerminalNode", params={})
    node = engine.nodes["t_unk"]
    result = engine.types["TerminalNode"].handle_action(
        node.state, "unknown-verb", {}, engine, node,
    )
    assert result is None


# ---------------------------------------------------------------------------
# Three cli_kind paths exercised through the same handler interface
# ---------------------------------------------------------------------------


def _record_handler():
    calls: list[dict] = []

    def handler(cli_kind, endpoint, payload):
        calls.append({"kind": cli_kind, "endpoint": endpoint, "payload": dict(payload)})
        return (True, "ok", f"output-{cli_kind}")

    return handler, calls


def test_cli_kind_dispatch_web_action_path(engine):
    """cli_kind=dispatch_web_action routes the typed text through the
    handler with the renderer-id as endpoint."""
    handler, calls = _record_handler()
    _terminal_module(engine).set_dispatch_handler(handler)
    engine.spawn(
        "t_dwa",
        "TerminalNode",
        params={
            "cli_kind": "dispatch_web_action",
            "cli_endpoint": "bottom_terminal_v1",
            "cli_natural_language": True,
        },
    )
    node = engine.nodes["t_dwa"]
    engine.types["TerminalNode"].handle_action(
        node.state, "submit", {"text": "send hello"}, engine, node,
    )
    assert len(calls) == 1
    assert calls[0]["kind"] == "dispatch_web_action"
    assert calls[0]["endpoint"] == "bottom_terminal_v1"
    assert calls[0]["payload"]["text"] == "send hello"
    assert calls[0]["payload"]["natural_language"] is True
    assert node.state["last_output"] == "output-dispatch_web_action"


def test_cli_kind_shell_path(engine):
    """cli_kind=shell routes through the same handler interface; the
    handler is responsible for forwarding to exec_shell."""
    handler, calls = _record_handler()
    _terminal_module(engine).set_dispatch_handler(handler)
    engine.spawn(
        "t_sh",
        "TerminalNode",
        params={
            "cli_kind": "shell",
            "cli_endpoint": "echo {{input}}",
        },
    )
    node = engine.nodes["t_sh"]
    engine.types["TerminalNode"].handle_action(
        node.state, "submit", {"text": "hi"}, engine, node,
    )
    assert len(calls) == 1
    assert calls[0]["kind"] == "shell"
    assert calls[0]["endpoint"] == "echo {{input}}"
    assert calls[0]["payload"]["text"] == "hi"
    # NL flag is False by default for non-chat terminals.
    assert calls[0]["payload"]["natural_language"] is False
    assert node.state["last_output"] == "output-shell"


def test_cli_kind_python_callable_path(engine):
    """cli_kind=python_callable routes through the same handler
    interface; the handler is responsible for forwarding to
    exec_python (or a substrate `execute()` call)."""
    handler, calls = _record_handler()
    _terminal_module(engine).set_dispatch_handler(handler)
    engine.spawn(
        "t_py",
        "TerminalNode",
        params={
            "cli_kind": "python_callable",
            "cli_endpoint": "alethea.search({{input}})",
        },
    )
    node = engine.nodes["t_py"]
    engine.types["TerminalNode"].handle_action(
        node.state, "submit", {"text": "'hello'"}, engine, node,
    )
    assert len(calls) == 1
    assert calls[0]["kind"] == "python_callable"
    assert calls[0]["endpoint"] == "alethea.search({{input}})"
    assert node.state["last_output"] == "output-python_callable"


# ---------------------------------------------------------------------------
# Handler-result normalization
# ---------------------------------------------------------------------------


def test_normalize_handler_result_three_tuple():
    assert _normalize_handler_result((True, "msg", "out")) == (True, "msg", "out")


def test_normalize_handler_result_two_tuple():
    """2-tuple = (success, message); message doubles as output."""
    assert _normalize_handler_result((False, "err")) == (False, "err", "err")


def test_normalize_handler_result_dict():
    res = _normalize_handler_result(
        {"success": True, "message": "m", "output": "o"}
    )
    assert res == (True, "m", "o")


def test_normalize_handler_result_dict_output_defaults_to_message():
    res = _normalize_handler_result({"success": True, "message": "m"})
    assert res == (True, "m", "m")


def test_normalize_handler_result_bool():
    assert _normalize_handler_result(True) == (True, "", "")
    assert _normalize_handler_result(False) == (False, "", "")


def test_normalize_handler_result_str():
    assert _normalize_handler_result("hello") == (True, "", "hello")


def test_normalize_handler_result_unknown_shape():
    success, message, output = _normalize_handler_result(object())
    assert success is False
    assert "object" in message
    assert output == ""


# ---------------------------------------------------------------------------
# Dispatch handler registration round-trip
# ---------------------------------------------------------------------------


def test_set_dispatch_handler_round_trip(engine):
    def h(k, e, p):
        return (True, "", "")
    mod = _terminal_module(engine)
    mod.set_dispatch_handler(h)
    assert mod.get_dispatch_handler() is h
    mod.set_dispatch_handler(None)
    assert mod.get_dispatch_handler() is None


# ---------------------------------------------------------------------------
# Module-clipboard round-trip
# ---------------------------------------------------------------------------


def test_round_trip_via_module_clipboard(engine):
    """A TerminalNode must serialize + paste through the existing
    SPEC-073 clipboard with no special-case handling."""
    from tools.module_clipboard import paste_text_to_engine, serialize_module

    engine.spawn(
        "src_term",
        "TerminalNode",
        params={
            "cli_kind": "shell",
            "cli_endpoint": "ls",
            "input_node": "tb_in",
            "output_node": "tb_out",
            "visibility": "expanded",
        },
    )
    text = serialize_module(engine, "src_term", include_subtree=True)
    new_ids = paste_text_to_engine(engine, text)
    assert "src_term_2" in new_ids
    copied = engine.nodes["src_term_2"]
    assert copied.type_name == "TerminalNode"
    assert copied.state["cli_kind"] == "shell"
    assert copied.state["cli_endpoint"] == "ls"
    assert copied.state["input_node"] == "tb_in"
    assert copied.state["output_node"] == "tb_out"
    assert copied.state["visibility"] == "expanded"


# ---------------------------------------------------------------------------
# Coexistence + dead-node handling
# ---------------------------------------------------------------------------


def test_two_terminals_coexist_with_different_bindings(engine):
    """Multiple TerminalNodes with different link sets coexist — the
    link is via field-reference, not parent-child containment."""
    engine.spawn(
        "ta", "TerminalNode",
        params={"input_node": "tb_a_in", "output_node": "tb_a_out"},
    )
    engine.spawn(
        "tb", "TerminalNode",
        params={"input_node": "tb_b_in", "output_node": "tb_b_out"},
    )
    assert engine.nodes["ta"].state["input_node"] == "tb_a_in"
    assert engine.nodes["tb"].state["input_node"] == "tb_b_in"


def test_dead_terminal_isolates_from_engine(engine):
    """A TerminalNode whose params produce a build failure marks
    itself dead without leaking the exception."""

    class _Unstringable:
        def __str__(self):
            raise RuntimeError("intentional")

    engine.spawn("t_dead", "TerminalNode", params={"cli_endpoint": _Unstringable()})
    node = engine.nodes["t_dead"]
    assert node.dead is True
    assert "build failed" in node.error
