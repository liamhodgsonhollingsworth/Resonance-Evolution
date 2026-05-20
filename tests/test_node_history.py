"""
Tests for the per-node edit-history writer + reader — SPEC-076.

History is the append-only NDJSON at ``state/node_history/<id>.jsonl``
written by the engine's mutation surface (spawn / set_param /
connect / disconnect / archive / restore).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from tools.node_history import (  # noqa: E402
    append_history_row,
    clear_node_history,
    history_dir,
    history_path,
    read_node_history,
)


@pytest.fixture
def engine_in_tmp(tmp_path) -> Engine:
    """An engine that loads node-types from the repo root.

    History writes during the test are redirected to ``tmp_path`` by
    the autouse ``_node_history_in_tmp`` fixture in ``conftest.py``
    (via the ``APEIRON_NODE_HISTORY_ROOT_OVERRIDE`` env var read by
    ``tools.node_history.history_dir``). The engine's
    ``root_dir`` keeps pointing at ROOT so ``discover()`` finds
    ButtonNode and friends.
    """
    e = Engine(root_dir=ROOT)
    e.discover()
    return e


def test_history_dir_is_created(tmp_path):
    target = history_dir(tmp_path)
    assert target.exists()
    assert target.is_dir()
    assert target.name == "node_history"


def test_history_path_rejects_unsafe_ids(tmp_path):
    with pytest.raises(ValueError):
        history_path(tmp_path, "../escape")
    with pytest.raises(ValueError):
        history_path(tmp_path, ".hidden")
    with pytest.raises(ValueError):
        history_path(tmp_path, "a/b")


def test_history_path_resolves_simple_id(tmp_path):
    p = history_path(tmp_path, "node_alpha")
    assert p.parent == history_dir(tmp_path)
    assert p.name == "node_alpha.jsonl"


def test_append_row_writes_jsonl(tmp_path):
    row = append_history_row(
        tmp_path, "node_a", "spawn",
        payload={"type": "Task"},
        summary="spawn Task",
    )
    assert row["kind"] == "spawn"
    assert row["ts"]
    path = history_path(tmp_path, "node_a")
    assert path.exists()
    lines = path.read_text(encoding="utf-8").strip().splitlines()
    assert len(lines) == 1
    parsed = json.loads(lines[0])
    assert parsed["kind"] == "spawn"
    assert parsed["payload"]["type"] == "Task"
    assert parsed["summary"] == "spawn Task"


def test_append_then_read_multiple_rows(tmp_path):
    append_history_row(tmp_path, "node_a", "spawn",
                       payload={"type": "Task"})
    append_history_row(tmp_path, "node_a", "set_param",
                       payload={"key": "title", "new": "X"},
                       summary="title -> X")
    append_history_row(tmp_path, "node_a", "archive",
                       summary="archived")
    rows = read_node_history(tmp_path, "node_a")
    assert len(rows) == 3
    # Newest-first.
    assert rows[0]["kind"] == "archive"
    assert rows[1]["kind"] == "set_param"
    assert rows[2]["kind"] == "spawn"


def test_read_chronological_order(tmp_path):
    append_history_row(tmp_path, "node_a", "spawn")
    append_history_row(tmp_path, "node_a", "set_param")
    rows = read_node_history(tmp_path, "node_a", newest_first=False)
    assert rows[0]["kind"] == "spawn"
    assert rows[1]["kind"] == "set_param"


def test_read_missing_returns_empty_list(tmp_path):
    assert read_node_history(tmp_path, "ghost") == []


def test_read_skips_malformed_lines(tmp_path):
    append_history_row(tmp_path, "node_a", "spawn")
    # Append a malformed line directly.
    path = history_path(tmp_path, "node_a")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("not-valid-json\n")
    append_history_row(tmp_path, "node_a", "set_param")
    rows = read_node_history(tmp_path, "node_a")
    # Two parseable rows; the malformed one is skipped.
    assert len(rows) == 2
    kinds = {r["kind"] for r in rows}
    assert kinds == {"spawn", "set_param"}


def test_read_logs_malformed_to_engine_errors(tmp_path):
    """When an engine handle is supplied, malformed lines log to its
    ``errors`` list — useful for diagnostics in the History view."""

    class _StubEngine:
        errors = []

    engine = _StubEngine()
    append_history_row(tmp_path, "node_a", "spawn")
    path = history_path(tmp_path, "node_a")
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("garbage\n")
    read_node_history(tmp_path, "node_a", engine=engine)
    assert any("malformed" in e for e in engine.errors)


def test_append_serialization_failure_degrades(tmp_path):
    """A payload containing a non-JSON value must not crash the
    writer. The row is written in a degraded form with a sentinel
    flag so the reader still surfaces it."""

    class _NotSerialisable:
        pass

    row = append_history_row(
        tmp_path, "node_a", "set_param",
        payload={"obj": _NotSerialisable()},
    )
    # The returned row reflects the degraded shape.
    assert row["payload"] == {"__serialization_error__": True}
    rows = read_node_history(tmp_path, "node_a")
    assert len(rows) == 1
    assert rows[0]["payload"]["__serialization_error__"] is True


def test_append_with_empty_node_id_noops(tmp_path):
    row = append_history_row(tmp_path, "", "spawn")
    assert row == {}
    assert read_node_history(tmp_path, "") == []


def test_clear_node_history(tmp_path):
    append_history_row(tmp_path, "node_a", "spawn")
    assert clear_node_history(tmp_path, "node_a") is True
    assert read_node_history(tmp_path, "node_a") == []
    # Idempotent — second clear returns False.
    assert clear_node_history(tmp_path, "node_a") is False


def test_session_id_is_recorded(tmp_path):
    append_history_row(
        tmp_path, "node_a", "spawn",
        session_id="test-session-123",
    )
    rows = read_node_history(tmp_path, "node_a")
    assert rows[0]["session_id"] == "test-session-123"


# ---------------------------------------------------------------------------
# Engine integration: mutation surface writes history.
# ---------------------------------------------------------------------------


def test_engine_spawn_writes_history_row(engine_in_tmp, tmp_path):
    engine_in_tmp.spawn("alpha", "ButtonNode", params={"label": "X"})
    rows = read_node_history(tmp_path, "alpha")
    assert len(rows) == 1
    assert rows[0]["kind"] == "spawn"
    assert rows[0]["payload"]["type"] == "ButtonNode"


def test_engine_set_param_writes_history(engine_in_tmp, tmp_path):
    engine_in_tmp.spawn("alpha", "ButtonNode", params={"label": "X"})
    ok = engine_in_tmp.set_param("alpha", "label", "Y")
    assert ok is True
    rows = read_node_history(tmp_path, "alpha")
    kinds = [r["kind"] for r in rows]
    assert "set_param" in kinds
    sp_row = next(r for r in rows if r["kind"] == "set_param")
    assert sp_row["payload"]["key"] == "label"
    assert sp_row["payload"]["new"] == "Y"


def test_engine_connect_disconnect_write_history(engine_in_tmp, tmp_path):
    engine_in_tmp.spawn("a", "ButtonNode", params={})
    engine_in_tmp.spawn("b", "ButtonNode", params={})
    assert engine_in_tmp.connect("a", "next", "b") is True
    assert engine_in_tmp.disconnect("a", "next") is True
    rows = read_node_history(tmp_path, "a")
    kinds = [r["kind"] for r in rows]
    assert "spawn" in kinds
    assert "connect" in kinds
    assert "disconnect" in kinds


def test_engine_archive_restore_round_trip(engine_in_tmp, tmp_path):
    engine_in_tmp.spawn("a", "ButtonNode", params={})
    assert engine_in_tmp.archive("a") is True
    assert engine_in_tmp.nodes["a"].dead is True
    assert engine_in_tmp.restore("a") is True
    assert engine_in_tmp.nodes["a"].dead is False
    rows = read_node_history(tmp_path, "a")
    kinds = [r["kind"] for r in rows]
    assert "archive" in kinds
    assert "restore" in kinds


def test_engine_mutation_missing_node_returns_false(engine_in_tmp):
    assert engine_in_tmp.set_param("ghost", "x", 1) is False
    assert engine_in_tmp.connect("ghost", "s", "t") is False
    assert engine_in_tmp.disconnect("ghost", "s") is False
    assert engine_in_tmp.archive("ghost") is False
    assert engine_in_tmp.restore("ghost") is False


def test_engine_session_id_stamps_rows(engine_in_tmp, tmp_path):
    """Engine.active_session_id is stamped on every emitted row."""
    engine_in_tmp.active_session_id = "session-xyz"
    engine_in_tmp.spawn("a", "ButtonNode", params={})
    rows = read_node_history(tmp_path, "a")
    assert rows[0]["session_id"] == "session-xyz"
