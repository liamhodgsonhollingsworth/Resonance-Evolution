"""
ChatInterpreter — parses chat-log messages into engine commands.

Builds on top of ChatInterface (which renders a chat log onto a screen).
ChatInterpreter reads the log file, tries to parse each new message as
a known command, and produces one of three outcomes per message:

  - "matched"  — the message parses as a known command; the interpreter
                 records the parsed command in its output log so a
                 dispatcher (TextRenderer, or future runtime) can execute
                 it. The dispatch itself is a separate node-type concern.
  - "novel"    — the message doesn't match any known command. If Claude
                 Code is connected (claude_connected: true), the
                 interpreter writes a `requested:` line to the chat log
                 asking Claude Code to implement the novel command. If
                 Claude Code is not connected, the interpreter writes a
                 `not yet learned:` response.
  - "noise"    — empty lines or already-handled lines; skipped.

The parse pipeline is exposed as a sub-graph of child layer-nodes. v1
ships one inline layer (substring match against known commands). Each
new layer is a new node-type file in node_types/; chaining is via
connections, so growing the language is editing the graph.

State:
- log_path: chat log file
- known_commands: list[str] — commands the interpreter recognizes
- parsed_offset: int — bytes already read from the log
- claude_connected: bool — whether the novelty fallthrough goes to
  Claude Code or surfaces a "not yet learned" response
- output_log: list of {"line", "outcome", "parsed"} per processed message

No visual emit — purely a logic node. describe() reports its state.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Dict, List

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


DEFAULT_COMMANDS = [
    "describe",
    "describe-subtree",
    "list-types",
    "list-nodes",
    "spawn",
    "connect",
    "move",
    "look-at",
    "render",
    "render-text",
]


def manifest() -> Manifest:
    return Manifest(
        name="ChatInterpreter",
        version="1.0",
        renderer_id="raster",
        inputs={"log_path": "str", "known_commands": "list[str]",
                "claude_connected": "bool"},
        outputs={"chat_outcomes": "list[dict]"},
        description=(
            "Parses chat-log messages into engine commands. Novel "
            "messages route to Claude Code (when connected) or surface "
            "as 'not yet learned'. Extensible via a sub-graph of "
            "parse layers."
        ),
    )


def build(params):
    return {
        "log_path": str(params.get("log_path", "logs/chat.txt")),
        "known_commands": list(params.get("known_commands", DEFAULT_COMMANDS)),
        "parsed_offset": 0,
        "claude_connected": bool(params.get("claude_connected", False)),
        "output_log": [],
    }


def precompute_hook(state, engine, node):
    """Parse any new lines in the chat log; classify each."""
    log_path = Path(state["log_path"])
    if not log_path.exists():
        return {"outcomes": list(state.get("output_log", []))}

    raw = log_path.read_text(encoding="utf-8", errors="replace")
    new_text = raw[state["parsed_offset"]:]
    state["parsed_offset"] = len(raw)

    pending_responses: List[str] = []
    for line in new_text.splitlines():
        outcome = _classify(line, state["known_commands"])
        state["output_log"].append(outcome)
        if outcome["outcome"] == "novel":
            if state["claude_connected"]:
                pending_responses.append(f"requested: {line}\n")
            else:
                pending_responses.append(f"not yet learned: {line}\n")

    # Append response lines back to the log so the chat surface
    # reflects the interpreter's state. claude_connected=true routes
    # novel commands to Claude Code via "requested:"; not-connected
    # surfaces "not yet learned:" so the user knows their input was
    # received but couldn't be handled.
    if pending_responses:
        with log_path.open("a", encoding="utf-8") as f:
            for response in pending_responses:
                f.write(response)

    return {
        "outcomes": list(state["output_log"]),
        "parsed_offset": state["parsed_offset"],
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """No visual contribution; chat outcomes flow through cache to the
    dispatcher."""
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return (f"ChatInterpreter id={ctx.node.id} log={state['log_path']} "
            f"known={len(state['known_commands'])} parsed_offset={state['parsed_offset']} "
            f"claude_connected={state['claude_connected']}")


# ---------------------------------------------------------------------------
# Parse helpers
# ---------------------------------------------------------------------------


def _classify(line: str, known_commands: List[str]) -> Dict[str, Any]:
    s = line.strip()
    if not s:
        return {"line": line, "outcome": "noise", "parsed": None}
    if s.startswith("requested:") or s.startswith("not yet learned:"):
        return {"line": line, "outcome": "noise", "parsed": None}
    first = s.split(None, 1)[0]
    if first in known_commands:
        return {"line": line, "outcome": "matched", "parsed": first}
    return {"line": line, "outcome": "novel", "parsed": None}
