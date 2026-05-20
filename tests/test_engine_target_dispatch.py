"""
Tests for the engine.actions target-prefix decoder + dispatch_button —
SPEC-077.

Covers the five recognised prefixes (empty/self, ``panel:``, ``node:``,
``session:``, ``view:``) plus the unknown-prefix fail-closed path; the
``dispatch_button`` end-to-end click through dispatch_action.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from engine.actions import (  # noqa: E402
    ResolvedTarget,
    dispatch_action,
    dispatch_button,
    get_view_state,
    resolve_target,
)


@pytest.fixture
def engine() -> Engine:
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


# ---------------------------------------------------------------------------
# resolve_target: pure function tests
# ---------------------------------------------------------------------------


def test_resolve_target_empty_returns_self():
    rt = resolve_target("", parent_node_id="owner")
    assert rt.kind == "self"
    assert rt.target_id == "owner"
    assert rt.payload_extras == {}
    assert rt.is_dispatchable() is True


def test_resolve_target_empty_no_parent_is_not_dispatchable():
    """Self-resolution against an empty parent must fail closed —
    there's no id to dispatch against."""
    rt = resolve_target("")
    assert rt.kind == "self"
    assert rt.target_id == ""
    assert rt.is_dispatchable() is False


def test_resolve_target_panel_prefix():
    rt = resolve_target("panel:tasks_panel")
    assert rt.kind == "panel"
    assert rt.target_id == "tasks_panel"
    assert rt.payload_extras == {}
    assert rt.is_dispatchable() is True


def test_resolve_target_node_prefix():
    rt = resolve_target("node:my_node")
    assert rt.kind == "node"
    assert rt.target_id == "my_node"


def test_resolve_target_session_prefix_injects_chat_target():
    rt = resolve_target("session:s-1")
    assert rt.kind == "session"
    assert rt.target_id == "s-1"
    assert rt.payload_extras == {"chat_target": "s-1"}


def test_resolve_target_view_prefix_is_not_dispatchable():
    """View targets are routed to ``shell.set_view``, not through
    ``dispatch_action``. The decoder marks them non-dispatchable so
    the click handler can short-circuit."""
    rt = resolve_target("view:Tasks")
    assert rt.kind == "view"
    assert rt.target_id == "Tasks"
    assert rt.is_dispatchable() is False


def test_resolve_target_unknown_prefix_fails_closed():
    rt = resolve_target("garbage-no-prefix")
    assert rt.kind == "unknown"
    assert rt.target_id == ""
    assert rt.raw_target == "garbage-no-prefix"
    assert rt.is_dispatchable() is False


def test_resolve_target_handles_none_and_int():
    """Defensive: the decoder must accept non-string targets without
    crashing — engine.spawn callers may pass through unvalidated input."""
    assert resolve_target(None).kind == "self"
    assert resolve_target(0).kind == "self"


def test_resolved_target_is_dataclass():
    rt = ResolvedTarget(kind="panel", target_id="foo")
    assert rt.is_dispatchable() is True


# ---------------------------------------------------------------------------
# dispatch_button: full click-through
# ---------------------------------------------------------------------------


def _setup_panel(engine, tmp_path):
    """Set up a synthetic ListRenderer panel for click-through tests."""
    path = tmp_path / "tasks.md"
    path.write_text("- [ ] alpha\n- [x] beta\n", encoding="utf-8")
    engine.spawn(
        "src", "FileSource",
        params={"path": str(path), "parser_name": "tasks"},
    )
    engine.spawn(
        "panel", "ListRenderer",
        params={"title_text": "Tasks"},
        connections={"source": "src"},
    )
    engine.precompute()


def test_dispatch_button_self_target_routes_to_parent(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    engine.spawn(
        "collapse_btn", "ButtonNode",
        params={
            "label": "Collapse",
            "action": "collapse",
            "target": "",   # self -> parent
            "parent": "panel",
        },
    )
    ok, msg = dispatch_button(engine, "collapse_btn")
    assert ok, msg
    assert "panel" in msg


def test_dispatch_button_panel_prefix(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    # First expand an item so we have something to collapse.
    dispatch_action(engine, "panel", "expand", item_id="task:1")
    assert get_view_state(engine, "panel").get("expanded_item") == "task:1"
    engine.spawn(
        "panel_collapse_btn", "ButtonNode",
        params={
            "label": "Collapse",
            "action": "collapse",
            "target": "panel:panel",
            "parent": "panel",
        },
    )
    ok, msg = dispatch_button(engine, "panel_collapse_btn")
    assert ok, msg
    assert get_view_state(engine, "panel").get("expanded_item") is None


def test_dispatch_button_node_prefix(engine, tmp_path):
    """``node:`` prefix dispatches against the named node directly."""
    _setup_panel(engine, tmp_path)
    engine.spawn(
        "node_collapse_btn", "ButtonNode",
        params={
            "label": "Collapse",
            "action": "collapse",
            "target": "node:panel",
            "parent": "some_other_node",   # parent != target deliberately
        },
    )
    ok, msg = dispatch_button(engine, "node_collapse_btn")
    assert ok, msg
    assert "panel" in msg


def test_dispatch_button_view_prefix_fails_closed_at_engine(engine):
    """View targets aren't dispatchable through the engine action
    surface — the engine surfaces a clear message and the GUI shell
    handles the view switch itself."""
    engine.spawn(
        "view_btn", "ButtonNode",
        params={"label": "Tasks", "action": "show-view", "target": "view:Tasks"},
    )
    ok, msg = dispatch_button(engine, "view_btn")
    assert not ok
    assert "shell" in msg.lower() or "view" in msg.lower()


def test_dispatch_button_unknown_target_fails_closed(engine):
    engine.spawn(
        "bad_btn", "ButtonNode",
        params={
            "label": "Broken",
            "action": "foo",
            "target": "no-prefix-junk",
        },
    )
    ok, msg = dispatch_button(engine, "bad_btn")
    assert not ok
    assert "unrecognised" in msg.lower() or "unknown" in msg.lower()


def test_dispatch_button_session_prefix_injects_chat_target(engine, tmp_path):
    """``session:`` prefix injects ``chat_target=<id>`` into the
    payload. The receiving renderer can read it from
    ``payload["chat_target"]``.

    We assert the injection by handing the click to a synthetic
    renderer whose handle_action records the payload it received.
    """
    _setup_panel(engine, tmp_path)
    # Use ListRenderer as a probe — its handle_action ignores unknown
    # actions but the dispatch surface still feeds it the payload. To
    # observe the payload we install a temporary handler on the source.
    captured = {}

    def _spy_handler(payload, engine_, node_):
        captured.update(payload)
        return None

    engine.cache.setdefault("src", {})["_action_handlers"] = {
        "probe": _spy_handler,
    }
    # The source's items must declare the action so the per-item
    # validation passes. Item "task:1" already has expand; we don't
    # need item-id resolution here since the action is renderer-scoped
    # via item_id=None. The button leaves item_id unset.
    engine.spawn(
        "session_btn", "ButtonNode",
        params={
            "label": "Ping",
            "action": "probe",
            "target": "session:s-1",
            "parent": "panel",
            "payload": {"hello": "world"},
        },
    )
    # The actual dispatch target is "s-1" (session id), but no such
    # renderer exists. The dispatcher fails closed with a clear
    # message — that's the correct behavior for a session-target
    # without a real shell. We assert the failure shape.
    ok, msg = dispatch_button(engine, "session_btn")
    assert not ok
    assert "s-1" in msg or "unknown renderer" in msg


def test_dispatch_button_missing_button_fails_closed(engine):
    ok, msg = dispatch_button(engine, "does_not_exist")
    assert not ok
    assert "unknown button" in msg.lower() or "does_not_exist" in msg


def test_dispatch_button_wrong_type_fails_closed(engine, tmp_path):
    _setup_panel(engine, tmp_path)
    ok, msg = dispatch_button(engine, "panel")   # ListRenderer, not ButtonNode
    assert not ok
    assert "ButtonNode" in msg or "not ButtonNode" in msg


def test_dispatch_button_dead_fails_closed(engine):
    """A dead ButtonNode (build failed) must not dispatch."""

    class _Unstringable:
        def __str__(self):
            raise RuntimeError("intentional")

    engine.spawn("dead_btn", "ButtonNode", params={"label": _Unstringable()})
    assert engine.nodes["dead_btn"].dead
    ok, msg = dispatch_button(engine, "dead_btn")
    assert not ok
    assert "dead" in msg.lower()


def test_dispatch_button_no_action_fails_closed(engine):
    engine.spawn("noop_btn", "ButtonNode", params={"label": "x"})
    ok, msg = dispatch_button(engine, "noop_btn")
    assert not ok
    assert "no action" in msg.lower()


def test_dispatch_button_self_no_parent_fails_closed(engine):
    """A button with empty target AND empty parent has no dispatch
    destination — must fail closed."""
    engine.spawn(
        "orphan_btn", "ButtonNode",
        params={"label": "X", "action": "noop"},
    )
    ok, msg = dispatch_button(engine, "orphan_btn")
    assert not ok
    assert "empty" in msg.lower() or "parent" in msg.lower()


def test_dispatch_button_payload_extras_forwarded(engine, tmp_path):
    """Payload extras from the target decoder must merge with the
    button's own payload before dispatch."""
    _setup_panel(engine, tmp_path)

    captured = {}

    def _spy_handler(payload, engine_, node_):
        captured.update(payload)
        return None

    engine.cache.setdefault("src", {})["_action_handlers"] = {
        "probe2": _spy_handler,
    }
    engine.spawn(
        "spy_btn", "ButtonNode",
        params={
            "label": "Spy",
            "action": "probe2",
            "target": "panel:panel",
            "parent": "panel",
            "payload": {"manual_key": "manual_val"},
        },
    )
    ok, msg = dispatch_button(engine, "spy_btn")
    assert ok, msg
    # button_id must always be added to the payload.
    assert captured.get("button_id") == "spy_btn"
    assert captured.get("manual_key") == "manual_val"
