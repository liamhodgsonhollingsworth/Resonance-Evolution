"""File-queue bridge for external command injection.

The browser-side Streamlit page can't accept TCP traffic from arbitrary
clients (it'd be a security hole and Streamlit doesn't expose a hook).
Instead, the running page polls a tiny on-disk queue file each refresh
tick. External callers (the maintainer's coding session, the
``cli`` entry point in this package, future scheduled jobs) write
newline-separated commands into the queue; the bridge drains and
dispatches them through the same ``CommandRegistry`` the terminal
panel uses.

Net effect: any process that can write to the queue file behaves
exactly as the maintainer typing into the terminal. That's the
"literally injecting the text directly into the website just as the
buttons/user would do" property the maintainer named.

Queue file format: one shell-quoted command per line. Lines starting
with ``#`` are comments. Empty lines are skipped. After draining, the
file is truncated atomically (write empty, rename) so the next polling
tick sees a fresh queue.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional, Tuple

from .command_registry import CommandContext, CommandRegistry, CommandResult


# Default location, relative to the workflow state dir.
QUEUE_FILENAME = "cli_command_queue.txt"


def queue_path(state_dir: Path) -> Path:
    return Path(state_dir) / QUEUE_FILENAME


def enqueue(state_dir: Path, command: str) -> None:
    """Append a command to the bridge queue.

    Used by ``tools.workflow_streamlit.cli`` to send a command to a
    running Streamlit page. Atomic enough for one-writer-one-reader —
    the small risk of overlap is bounded by line-buffered appends and
    the drain step's rewrite.
    """
    if not command.strip():
        return
    path = queue_path(state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    line = command.rstrip("\n") + "\n"
    # Append with explicit utf-8 + no newline rewriting so Windows
    # doesn't sneak \r\n into the queue.
    with path.open("a", encoding="utf-8", newline="") as f:
        f.write(line)


@dataclass
class DrainResult:
    commands: List[str]
    results: List[CommandResult]


def drain(
    state_dir: Path,
    registry: CommandRegistry,
    ctx: CommandContext,
    max_per_tick: int = 32,
) -> DrainResult:
    """Read, dispatch, and truncate the queue.

    ``max_per_tick`` caps how many commands run per call so a runaway
    producer can't lock up the rendering loop. Anything beyond the cap
    stays in the file for the next tick.

    The drain is best-effort: if the file is locked momentarily by a
    concurrent writer, the next tick will retry.
    """
    path = queue_path(state_dir)
    if not path.exists():
        return DrainResult(commands=[], results=[])
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return DrainResult(commands=[], results=[])
    lines = [ln for ln in raw.splitlines() if ln.strip() and not ln.lstrip().startswith("#")]
    if not lines:
        # File exists but is empty — clear it so we don't poll noise.
        _safe_truncate(path)
        return DrainResult(commands=[], results=[])

    to_run = lines[:max_per_tick]
    remaining = lines[max_per_tick:]

    commands: List[str] = []
    results: List[CommandResult] = []
    for cmd_line in to_run:
        commands.append(cmd_line)
        result = registry.run(cmd_line, ctx, source="cli")
        results.append(result)

    # Rewrite the file with only the unprocessed remainder.
    _safe_rewrite(path, remaining)
    return DrainResult(commands=commands, results=results)


def _safe_truncate(path: Path) -> None:
    try:
        path.write_text("", encoding="utf-8")
    except OSError:
        pass


def _safe_rewrite(path: Path, lines: List[str]) -> None:
    """Replace the queue file with the given remaining lines."""
    body = ("\n".join(lines) + "\n") if lines else ""
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        tmp.write_text(body, encoding="utf-8")
        os.replace(tmp, path)
    except OSError:
        # On a transient Windows lock, fall back to a direct write —
        # the next tick will succeed.
        try:
            path.write_text(body, encoding="utf-8")
        except OSError:
            pass
