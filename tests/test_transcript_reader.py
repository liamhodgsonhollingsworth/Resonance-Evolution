"""
Tests for the transcript reader (SPEC-070).

Covers the parser library, both CLI entry points, edge cases (empty
files, malformed lines, missing sessions), tool-call summary forms, and
the multi-chunk-collapse behavior that keeps streaming assistant
messages from producing duplicate turns.
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path
from typing import List

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from tools.transcript_reader import (  # noqa: E402
    Transcript,
    Turn,
    find_session_jsonl,
    first_user_message,
    list_all_sessions,
    parse_transcript,
    render_markdown,
    summarize_tool_call,
)
from tools import read_transcript  # noqa: E402
from tools import list_transcripts  # noqa: E402


# --- Fixtures ----------------------------------------------------------


def _write_jsonl(path: Path, events: List[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")


def _make_user(text: str, ts: str = "2026-05-20T00:00:00Z") -> dict:
    return {
        "type": "user",
        "timestamp": ts,
        "message": {"role": "user", "content": text},
    }


def _make_assistant(
    blocks: List[dict],
    msg_id: str = "msg_1",
    ts: str = "2026-05-20T00:00:01Z",
) -> dict:
    return {
        "type": "assistant",
        "timestamp": ts,
        "message": {
            "role": "assistant",
            "id": msg_id,
            "content": blocks,
        },
    }


def _make_tool_result(tool_use_id: str = "toolu_1") -> dict:
    return {
        "type": "user",
        "timestamp": "2026-05-20T00:00:02Z",
        "message": {
            "role": "user",
            "content": [
                {
                    "type": "tool_result",
                    "tool_use_id": tool_use_id,
                    "content": "ok",
                },
            ],
        },
    }


# --- summarize_tool_call -----------------------------------------------


def test_summarize_read():
    s = summarize_tool_call("Read", {"file_path": "/x/y.py"})
    assert s == "[Read] /x/y.py"


def test_summarize_write_and_edit():
    assert summarize_tool_call("Write", {"file_path": "/a.txt"}) == "[Write] /a.txt"
    assert summarize_tool_call("Edit", {"file_path": "/b.py"}) == "[Edit] /b.py"


def test_summarize_bash_truncates_long_command():
    long_cmd = "echo " + ("x" * 500)
    s = summarize_tool_call("Bash", {"command": long_cmd})
    assert s.startswith("[Bash] echo ")
    assert s.endswith("...")
    assert len(s) < len(long_cmd)  # truncated


def test_summarize_grep_with_path():
    s = summarize_tool_call("Grep", {"pattern": "foo", "path": "src/"})
    assert s == "[Grep] foo in src/"


def test_summarize_task_update_status():
    s = summarize_tool_call("TaskUpdate", {"taskId": "59", "status": "completed"})
    assert s == "[TaskUpdate] #59 -> completed"


def test_summarize_agent_uses_description():
    s = summarize_tool_call("Agent", {"description": "scan repo"})
    assert s == "[Agent] scan repo"


def test_summarize_ask_user_question_first_question():
    s = summarize_tool_call(
        "AskUserQuestion",
        {"questions": [{"question": "Pick one?"}]},
    )
    assert s == "[AskUserQuestion] Pick one?"


def test_summarize_unknown_tool_falls_back():
    s = summarize_tool_call("NeverHeardOf", {"arg1": "value1"})
    assert s == "[NeverHeardOf] arg1=value1"


def test_summarize_no_input_data():
    assert summarize_tool_call("Foo", {}) == "[Foo]"


def test_summarize_non_dict_input():
    assert summarize_tool_call("Foo", "not a dict") == "[Foo]"


# --- parse_transcript --------------------------------------------------


def test_parse_basic_turn(tmp_path):
    jsonl = tmp_path / "session.jsonl"
    _write_jsonl(jsonl, [
        _make_user("Hello"),
        _make_assistant([{"type": "text", "text": "Hi there."}]),
    ])
    tr = parse_transcript(jsonl)
    assert len(tr.turns) == 1
    assert tr.turns[0].user_text == "Hello"
    assert tr.turns[0].assistant_text == ["Hi there."]
    assert tr.session_id == "session"


def test_parse_collapses_multi_chunk_assistant(tmp_path):
    """Streaming assistant messages share msg_id across multiple lines."""

    jsonl = tmp_path / "session.jsonl"
    _write_jsonl(jsonl, [
        _make_user("go"),
        _make_assistant([{"type": "text", "text": "chunk-1"}], msg_id="msg_X"),
        _make_assistant([{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}], msg_id="msg_X"),
        _make_tool_result(),
        _make_assistant([{"type": "text", "text": "chunk-2"}], msg_id="msg_Y"),
    ])
    tr = parse_transcript(jsonl)
    # One turn, both text chunks accumulated, the Bash tool call present.
    assert len(tr.turns) == 1
    assert tr.turns[0].assistant_text == ["chunk-1", "chunk-2"]
    assert tr.turns[0].tool_calls == ["[Bash] ls"]


def test_parse_filters_queue_operations(tmp_path):
    jsonl = tmp_path / "session.jsonl"
    _write_jsonl(jsonl, [
        {"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-01-01T00:00:00Z"},
        _make_user("Hi"),
        {"type": "queue-operation", "operation": "dequeue"},
        _make_assistant([{"type": "text", "text": "Yo"}]),
    ])
    tr = parse_transcript(jsonl)
    assert len(tr.turns) == 1
    assert tr.turns[0].user_text == "Hi"


def test_parse_filters_thinking_by_default(tmp_path):
    jsonl = tmp_path / "session.jsonl"
    _write_jsonl(jsonl, [
        _make_user("plan"),
        _make_assistant([
            {"type": "thinking", "thinking": "Let me think..."},
            {"type": "text", "text": "Here's the plan."},
        ]),
    ])
    tr = parse_transcript(jsonl)
    # Thinking is parsed (so render can opt-in) but text is what shows.
    assert tr.turns[0].thinking == ["Let me think..."]
    assert tr.turns[0].assistant_text == ["Here's the plan."]


def test_parse_skips_malformed_lines(tmp_path):
    jsonl = tmp_path / "session.jsonl"
    jsonl.write_text(
        "{not valid json\n"
        + json.dumps(_make_user("ok")) + "\n"
        + "another garbage line\n"
        + json.dumps(_make_assistant([{"type": "text", "text": "fine"}])) + "\n",
        encoding="utf-8",
    )
    tr = parse_transcript(jsonl)
    assert len(tr.turns) == 1
    assert tr.turns[0].user_text == "ok"
    assert tr.turns[0].assistant_text == ["fine"]


def test_parse_records_timestamps(tmp_path):
    jsonl = tmp_path / "session.jsonl"
    _write_jsonl(jsonl, [
        _make_user("a", ts="2026-05-20T10:00:00Z"),
        _make_assistant([{"type": "text", "text": "b"}], ts="2026-05-20T10:00:05Z"),
        _make_user("c", ts="2026-05-20T11:00:00Z"),
    ])
    tr = parse_transcript(jsonl)
    assert tr.started == "2026-05-20T10:00:00Z"
    assert tr.ended == "2026-05-20T11:00:00Z"


def test_parse_empty_file(tmp_path):
    jsonl = tmp_path / "empty.jsonl"
    jsonl.write_text("", encoding="utf-8")
    tr = parse_transcript(jsonl)
    assert tr.turns == []
    assert tr.started == ""


def test_parse_tool_result_does_not_create_new_turn(tmp_path):
    """tool_result blocks (role=user, content=list) are NOT new turns."""

    jsonl = tmp_path / "session.jsonl"
    _write_jsonl(jsonl, [
        _make_user("real prompt"),
        _make_assistant([
            {"type": "tool_use", "name": "Read", "input": {"file_path": "/x"}},
        ]),
        _make_tool_result(),
        _make_assistant([{"type": "text", "text": "done"}], msg_id="msg_2"),
    ])
    tr = parse_transcript(jsonl)
    # One user-typed prompt → one turn (with both assistant chunks merged).
    assert len(tr.turns) == 1
    assert tr.turns[0].user_text == "real prompt"
    assert "[Read] /x" in tr.turns[0].tool_calls


# --- render_markdown ---------------------------------------------------


def test_render_includes_session_metadata():
    tr = Transcript(
        session_id="abc-123",
        project_slug="C--Users-Liam-Desktop-Apeiron",
        started="2026-05-20T00:00:00Z",
        ended="2026-05-20T01:00:00Z",
    )
    out = render_markdown(tr)
    assert "# Session abc-123" in out
    assert "C--Users-Liam-Desktop-Apeiron" in out
    assert "2026-05-20T00:00:00Z" in out
    assert "**Turns:** 0" in out


def test_render_basic_turn():
    tr = Transcript(session_id="s1", project_slug="p")
    tr.turns.append(Turn(
        user_text="Hello",
        assistant_text=["Hi there."],
        tool_calls=["[Read] /x.py"],
        timestamp="2026-05-20T00:00:00Z",
    ))
    out = render_markdown(tr)
    assert "## Turn 1" in out
    assert "> Hello" in out  # user as blockquote
    assert "Hi there." in out
    assert "- [Read] /x.py" in out


def test_render_omits_thinking_by_default():
    tr = Transcript(session_id="s1", project_slug="p")
    tr.turns.append(Turn(
        user_text="go",
        thinking=["secret thoughts"],
        assistant_text=["public reply"],
    ))
    out = render_markdown(tr)
    assert "secret thoughts" not in out
    assert "public reply" in out


def test_render_includes_thinking_when_opted_in():
    tr = Transcript(session_id="s1", project_slug="p")
    tr.turns.append(Turn(
        user_text="go",
        thinking=["the thinking content"],
        assistant_text=["the response"],
    ))
    out = render_markdown(tr, include_thinking=True)
    assert "the thinking content" in out
    assert "**Thinking:**" in out


def test_render_size_reduction(tmp_path):
    """The SPEC names a 360KB → 3KB collapse — verify the order of magnitude."""

    # Generate 1000 lines of mostly-tool-use noise + a few user/assistant text blocks.
    events: List[dict] = []
    for i in range(2):
        events.append(_make_user(f"prompt {i}", ts=f"2026-05-20T00:00:{i:02d}Z"))
        for j in range(50):
            events.append(_make_assistant(
                [{"type": "tool_use", "name": "Read", "input": {"file_path": f"/x{j}.py"}}],
                msg_id=f"msg_{i}",
                ts=f"2026-05-20T00:01:{j:02d}Z",
            ))
        events.append(_make_assistant(
            [{"type": "text", "text": f"reply {i}"}],
            msg_id=f"msg_{i}_final",
            ts=f"2026-05-20T00:02:{i:02d}Z",
        ))
    jsonl = tmp_path / "big.jsonl"
    _write_jsonl(jsonl, events)
    raw_size = jsonl.stat().st_size

    tr = parse_transcript(jsonl)
    rendered = render_markdown(tr)
    assert len(rendered) < raw_size  # always smaller
    # We get an actual reduction, not just shave a few bytes.
    assert len(rendered) * 2 < raw_size


# --- find_session_jsonl + list_all_sessions ----------------------------


def test_find_session_in_specific_project(tmp_path):
    proj = tmp_path / "C--Users-Liam-Desktop-X"
    proj.mkdir()
    (proj / "abc.jsonl").write_text("{}", encoding="utf-8")
    assert find_session_jsonl(
        "abc", "C--Users-Liam-Desktop-X", projects_dir=tmp_path,
    ) is not None
    assert find_session_jsonl(
        "missing", "C--Users-Liam-Desktop-X", projects_dir=tmp_path,
    ) is None


def test_find_session_across_all_projects(tmp_path):
    (tmp_path / "P1").mkdir()
    (tmp_path / "P2").mkdir()
    (tmp_path / "P2" / "wanted.jsonl").write_text("{}", encoding="utf-8")
    found = find_session_jsonl("wanted", projects_dir=tmp_path)
    assert found is not None
    assert found.parent.name == "P2"


def test_find_session_missing_returns_none(tmp_path):
    (tmp_path / "P1").mkdir()
    assert find_session_jsonl("nope", projects_dir=tmp_path) is None


def test_list_all_sessions_finds_jsonls(tmp_path):
    p1 = tmp_path / "P1"
    p2 = tmp_path / "P2"
    p1.mkdir()
    p2.mkdir()
    (p1 / "a.jsonl").write_text("{}", encoding="utf-8")
    (p1 / "b.jsonl").write_text("{}", encoding="utf-8")
    (p2 / "c.jsonl").write_text("{}", encoding="utf-8")
    sessions = list_all_sessions(projects_dir=tmp_path)
    ids = {s["session_id"] for s in sessions}
    assert ids == {"a", "b", "c"}


def test_list_all_sessions_project_filter(tmp_path):
    p1 = tmp_path / "Apeiron"
    p2 = tmp_path / "Alethea"
    p1.mkdir()
    p2.mkdir()
    (p1 / "a.jsonl").write_text("{}", encoding="utf-8")
    (p2 / "b.jsonl").write_text("{}", encoding="utf-8")
    sessions = list_all_sessions(project_filter="Apeiron", projects_dir=tmp_path)
    assert len(sessions) == 1
    assert sessions[0]["project_slug"] == "Apeiron"


def test_list_all_sessions_missing_projects_dir():
    result = list_all_sessions(projects_dir=Path("/definitely/does/not/exist"))
    assert result == []


# --- first_user_message ------------------------------------------------


def test_first_user_message(tmp_path):
    jsonl = tmp_path / "s.jsonl"
    _write_jsonl(jsonl, [
        _make_user("Hello world"),
        _make_assistant([{"type": "text", "text": "Hi"}]),
        _make_user("Second prompt"),
    ])
    assert first_user_message(jsonl) == "Hello world"


def test_first_user_message_truncates(tmp_path):
    jsonl = tmp_path / "s.jsonl"
    _write_jsonl(jsonl, [_make_user("x" * 500)])
    summary = first_user_message(jsonl, max_chars=20)
    assert len(summary) == 23  # 20 chars + "..."
    assert summary.endswith("...")


def test_first_user_message_replaces_newlines(tmp_path):
    jsonl = tmp_path / "s.jsonl"
    _write_jsonl(jsonl, [_make_user("line one\nline two")])
    assert "\n" not in first_user_message(jsonl)


def test_first_user_message_missing_file():
    assert first_user_message(Path("/does/not/exist.jsonl")) == ""


def test_first_user_message_skips_tool_result_user_blocks(tmp_path):
    """tool_result blocks have role=user but list-content; ignore them."""

    jsonl = tmp_path / "s.jsonl"
    _write_jsonl(jsonl, [
        _make_tool_result(),  # role=user, content=list — must not count
        _make_user("Real prompt"),
    ])
    assert first_user_message(jsonl) == "Real prompt"


# --- CLI integration ---------------------------------------------------


def test_read_transcript_cli_writes_to_out(tmp_path, monkeypatch):
    """End-to-end: build a fixture, run main(), check the output file."""

    proj = tmp_path / "P"
    proj.mkdir()
    jsonl = proj / "fixture-id.jsonl"
    _write_jsonl(jsonl, [
        _make_user("hello"),
        _make_assistant([{"type": "text", "text": "world"}]),
    ])
    monkeypatch.setattr(
        "tools.transcript_reader.PROJECTS_DIR", tmp_path,
    )
    # Also patch the symbol re-imported into the CLI module's namespace.
    monkeypatch.setattr(
        "tools.read_transcript.find_session_jsonl",
        lambda sid, proj=None: jsonl if sid == "fixture-id" else None,
    )
    out_file = tmp_path / "rendered.md"
    rc = read_transcript.main([
        "fixture-id",
        "--out", str(out_file),
    ])
    assert rc == 0
    content = out_file.read_text(encoding="utf-8")
    assert "# Session fixture-id" in content
    assert "> hello" in content
    assert "world" in content


def test_read_transcript_cli_missing_session_returns_nonzero(monkeypatch, capsys):
    monkeypatch.setattr(
        "tools.read_transcript.find_session_jsonl",
        lambda sid, proj=None: None,
    )
    rc = read_transcript.main(["never-existed"])
    assert rc == 1
    err = capsys.readouterr().err
    assert "never-existed" in err


def test_list_transcripts_cli(tmp_path, monkeypatch, capsys):
    proj = tmp_path / "Apeiron"
    proj.mkdir()
    jsonl = proj / "abc.jsonl"
    _write_jsonl(jsonl, [_make_user("hi")])
    monkeypatch.setattr(
        "tools.list_transcripts.list_all_sessions",
        lambda project_filter=None: [{
            "session_id": "abc",
            "project_slug": "Apeiron",
            "size_bytes": 100,
            "mtime": 1747756800.0,  # 2026-05-20T12:00:00Z
            "path": str(jsonl),
        }],
    )
    rc = list_transcripts.main([])
    assert rc == 0
    out = capsys.readouterr().out
    assert "abc" in out
    assert "Apeiron" in out
    assert "0.1KB" in out  # 100 bytes → 0.1 KB
