"""
Transcript reader library — SPEC-070.

Parses Claude Code session JSONL transcripts at
``~/.claude/projects/<project_slug>/<session_id>.jsonl`` into readable
Markdown. The raw JSONL interleaves message chunks, tool-use deltas, and
internal queue events; this module collapses each turn to a single
maintainer/assistant pair and summarizes every tool call to one line.

The default render filters out:

- ``queue-operation`` events (harness internals).
- Multi-line streaming chunks (assistant messages share a message id
  across chunks; we collapse on message id).
- ``thinking`` blocks (opt-in via ``include_thinking``).
- ``tool_result`` content (always omitted — only ``tool_use`` is
  summarized).
- ``system`` events.

The reader is designed to make prior sessions usable as context: a
360KB raw JSONL collapses to ~3KB of readable conversation.

Used by the two thin CLI entry points ``tools.read_transcript`` (one
session) and ``tools.list_transcripts`` (every session on disk).
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional


PROJECTS_DIR = Path.home() / ".claude" / "projects"

# Caps for one-line tool-call summaries.
_TOOL_ARG_MAX = 120
_BASH_CMD_MAX = 200
_FIRST_USER_PROMPT_MAX = 80


@dataclass
class Turn:
    """One maintainer/assistant turn in a session."""

    user_text: str = ""
    assistant_text: List[str] = field(default_factory=list)
    thinking: List[str] = field(default_factory=list)
    tool_calls: List[str] = field(default_factory=list)
    timestamp: str = ""


@dataclass
class Transcript:
    """A parsed Claude Code session transcript."""

    session_id: str
    project_slug: str
    turns: List[Turn] = field(default_factory=list)
    started: str = ""
    ended: str = ""

    @property
    def user_count(self) -> int:
        return sum(1 for t in self.turns if t.user_text)


def find_session_jsonl(
    session_id: str, project_slug: Optional[str] = None,
    projects_dir: Optional[Path] = None,
) -> Optional[Path]:
    """Locate the JSONL file for ``session_id``, optionally scoped to a project.

    ``projects_dir`` overrides the default ``~/.claude/projects`` (for tests).
    """

    base = projects_dir if projects_dir is not None else PROJECTS_DIR
    if not base.exists():
        return None

    if project_slug is not None:
        p = base / project_slug / f"{session_id}.jsonl"
        return p if p.exists() else None

    for project_dir in base.iterdir():
        if not project_dir.is_dir():
            continue
        p = project_dir / f"{session_id}.jsonl"
        if p.exists():
            return p
    return None


def summarize_tool_call(name: str, input_data: dict) -> str:
    """One-line summary of a ``tool_use`` block — public for tests."""

    if not isinstance(input_data, dict):
        return f"[{name}]"

    if name == "Read":
        return f"[Read] {input_data.get('file_path', '?')}"
    if name == "Write":
        return f"[Write] {input_data.get('file_path', '?')}"
    if name == "Edit":
        return f"[Edit] {input_data.get('file_path', '?')}"
    if name == "Glob":
        return f"[Glob] {input_data.get('pattern', '?')}"
    if name == "Grep":
        pat = input_data.get("pattern", "?")
        path = input_data.get("path", "")
        return f"[Grep] {pat}" + (f" in {path}" if path else "")
    if name in ("Bash", "PowerShell"):
        cmd = str(input_data.get("command", "?"))
        if len(cmd) > _BASH_CMD_MAX:
            cmd = cmd[:_BASH_CMD_MAX] + "..."
        return f"[{name}] {cmd}"
    if name == "Agent":
        return f"[Agent] {input_data.get('description', '?')}"
    if name == "TaskCreate":
        return f"[TaskCreate] {input_data.get('subject', '?')}"
    if name == "TaskUpdate":
        status = input_data.get("status", "")
        suffix = f" -> {status}" if status else ""
        return f"[TaskUpdate] #{input_data.get('taskId', '?')}{suffix}"
    if name == "AskUserQuestion":
        questions = input_data.get("questions", [])
        if isinstance(questions, list) and questions:
            q0 = questions[0]
            if isinstance(q0, dict):
                return f"[AskUserQuestion] {q0.get('question', '?')}"
        return "[AskUserQuestion]"
    if name == "WebFetch":
        return f"[WebFetch] {input_data.get('url', '?')}"
    if name == "WebSearch":
        return f"[WebSearch] {input_data.get('query', '?')}"
    if name == "ToolSearch":
        return f"[ToolSearch] {input_data.get('query', '?')}"
    if name == "ScheduleWakeup":
        reason = input_data.get("reason", "")
        return f"[ScheduleWakeup] {input_data.get('delaySeconds', '?')}s — {reason}"

    # Generic fallback: name + first arg value (truncated).
    args = list(input_data.items())
    if args:
        k, v = args[0]
        sv = str(v).replace("\n", " ")
        if len(sv) > _TOOL_ARG_MAX:
            sv = sv[:_TOOL_ARG_MAX] + "..."
        return f"[{name}] {k}={sv}"
    return f"[{name}]"


def parse_transcript(path: Path) -> Transcript:
    """Parse a session JSONL into a ``Transcript`` object.

    Skips malformed JSON lines without raising; the SPEC contract is
    "make the conversation readable," not "validate the JSONL schema."
    """

    transcript = Transcript(
        session_id=path.stem,
        project_slug=path.parent.name,
    )

    current_turn: Optional[Turn] = None
    seen_message_ids: set[str] = set()
    earliest_ts = ""
    latest_ts = ""

    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            ts = obj.get("timestamp", "")
            if ts:
                if not earliest_ts or ts < earliest_ts:
                    earliest_ts = ts
                if not latest_ts or ts > latest_ts:
                    latest_ts = ts

            t = obj.get("type")
            if t in ("queue-operation", "system"):
                continue

            msg = obj.get("message")
            if not isinstance(msg, dict):
                continue

            role = msg.get("role")
            content = msg.get("content")

            if role == "user":
                # User-typed prompt has string content. tool_result blocks
                # (role=user, content=list) are absorbed into the previous
                # assistant message rather than starting a new turn.
                if isinstance(content, str):
                    current_turn = Turn(timestamp=ts, user_text=content)
                    transcript.turns.append(current_turn)
                continue

            if role == "assistant":
                if not isinstance(content, list):
                    continue

                # Collapse multi-line assistant messages on shared id.
                msg_id = msg.get("id")
                if msg_id and msg_id in seen_message_ids:
                    if current_turn is None:
                        current_turn = Turn(timestamp=ts)
                        transcript.turns.append(current_turn)
                else:
                    if msg_id:
                        seen_message_ids.add(msg_id)
                    if current_turn is None:
                        current_turn = Turn(timestamp=ts)
                        transcript.turns.append(current_turn)

                for block in content:
                    if not isinstance(block, dict):
                        continue
                    bt = block.get("type")
                    if bt == "text":
                        text = block.get("text", "").strip()
                        if text:
                            current_turn.assistant_text.append(text)
                    elif bt == "thinking":
                        thought = block.get("thinking", "").strip()
                        if thought:
                            current_turn.thinking.append(thought)
                    elif bt == "tool_use":
                        name = block.get("name", "?")
                        input_data = block.get("input", {})
                        current_turn.tool_calls.append(
                            summarize_tool_call(name, input_data)
                        )

    transcript.started = earliest_ts
    transcript.ended = latest_ts
    return transcript


def render_markdown(
    transcript: Transcript,
    include_thinking: bool = False,
) -> str:
    """Render a ``Transcript`` as readable Markdown."""

    lines: List[str] = []
    lines.append(f"# Session {transcript.session_id}")
    lines.append("")
    lines.append(f"**Project slug:** `{transcript.project_slug}`")
    if transcript.started:
        lines.append(f"**Started:** {transcript.started}")
    if transcript.ended:
        lines.append(f"**Ended:** {transcript.ended}")
    lines.append(f"**Turns:** {len(transcript.turns)}")
    lines.append("")

    for i, turn in enumerate(transcript.turns, 1):
        lines.append(f"## Turn {i}")
        if turn.timestamp:
            lines.append(f"*{turn.timestamp}*")
        lines.append("")

        if turn.user_text:
            lines.append("**User:**")
            lines.append("")
            for ln in turn.user_text.splitlines():
                lines.append(f"> {ln}")
            lines.append("")

        if include_thinking and turn.thinking:
            lines.append("**Thinking:**")
            lines.append("")
            for thought in turn.thinking:
                for ln in thought.splitlines():
                    lines.append(f"    {ln}")
                lines.append("")

        if turn.assistant_text:
            lines.append("**Assistant:**")
            lines.append("")
            for text in turn.assistant_text:
                lines.append(text)
                lines.append("")

        if turn.tool_calls:
            lines.append("**Tool calls:**")
            lines.append("")
            for tc in turn.tool_calls:
                lines.append(f"- {tc}")
            lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def list_all_sessions(
    project_filter: Optional[str] = None,
    projects_dir: Optional[Path] = None,
) -> List[dict]:
    """Enumerate every session JSONL on disk."""

    results: List[dict] = []
    base = projects_dir if projects_dir is not None else PROJECTS_DIR
    if not base.exists():
        return results

    for project_dir in sorted(base.iterdir()):
        if not project_dir.is_dir():
            continue
        if project_filter and project_filter not in project_dir.name:
            continue
        for jsonl in sorted(project_dir.glob("*.jsonl")):
            try:
                stat = jsonl.stat()
            except OSError:
                continue
            results.append({
                "session_id": jsonl.stem,
                "project_slug": project_dir.name,
                "size_bytes": stat.st_size,
                "mtime": stat.st_mtime,
                "path": str(jsonl),
            })
    return results


def first_user_message(
    path: Path, max_chars: int = _FIRST_USER_PROMPT_MAX,
) -> str:
    """First user-typed prompt in the session, truncated for list display."""

    try:
        with path.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                msg = obj.get("message", {})
                if not isinstance(msg, dict):
                    continue
                if msg.get("role") != "user":
                    continue
                content = msg.get("content")
                if isinstance(content, str):
                    text = content.strip().replace("\n", " ")
                    if len(text) > max_chars:
                        text = text[:max_chars] + "..."
                    return text
    except OSError:
        return ""
    return ""
