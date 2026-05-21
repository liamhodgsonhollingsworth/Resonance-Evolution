"""Command-line entry point — drive the running Streamlit page from a terminal.

Two usage modes:

1. **Inject into a running page**: write commands into the bridge
   queue at ``state/workflow/cli_command_queue.txt`` so the page's
   next refresh tick picks them up and dispatches as if the maintainer
   had typed them into the in-page terminal.

       python -m tools.workflow_streamlit.cli idea-queue.add "fix the oscillation"
       python -m tools.workflow_streamlit.cli session.status
       python -m tools.workflow_streamlit.cli chat.send "hello session"

2. **Headless dispatch (no Streamlit)**: useful for tests and offline
   scripting. Constructs an Engine + SessionManager + Inbox directly,
   builds a CommandContext, runs the command, prints the result.

       python -m tools.workflow_streamlit.cli --headless idea-queue.list

The default is mode (1): write to the queue and exit. Add ``--headless``
or ``-H`` to fall back to direct dispatch.

Either mode shares one command catalog; the same handlers run.
"""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path
from typing import List

from .cli_bridge import enqueue
from .command_registry import CommandContext, CommandRegistry
from .commands import register_all
from .config import load_config


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m tools.workflow_streamlit.cli",
        description="Inject commands into the running Streamlit page (or dispatch headlessly).",
    )
    p.add_argument(
        "-H", "--headless",
        action="store_true",
        help="Skip the queue; construct a fresh runtime and dispatch in-process.",
    )
    p.add_argument(
        "--apeiron-root",
        type=Path,
        default=None,
        help="Override the Apeiron repo root (default: auto-detect from this file).",
    )
    p.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="The command line to run — e.g. `idea-queue.add some text`",
    )
    return p


def main(argv: List[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    if not args.command:
        print("error: no command given (try `help`)", file=sys.stderr)
        return 2
    cmd_line = " ".join(shlex.quote(a) for a in args.command)
    cfg = load_config(apeiron_root=args.apeiron_root)
    if args.headless:
        return _run_headless(cfg, cmd_line)
    return _enqueue_for_page(cfg, cmd_line)


def _enqueue_for_page(cfg, cmd_line: str) -> int:
    enqueue(cfg.state_dir, cmd_line)
    queue_file = cfg.state_dir / "cli_command_queue.txt"
    print(f"queued: {cmd_line}")
    print(f"  file: {queue_file}")
    print("  (the running Streamlit page will dispatch on its next refresh tick)")
    return 0


def _run_headless(cfg, cmd_line: str) -> int:
    # Constructing a fresh Engine + SessionManager + Inbox without
    # touching Streamlit. Used for CI tests and one-shot scripting.
    from engine.core import Engine
    from engine.file_watcher import FileWatcher
    from tools.workflow.inbox import Inbox
    from tools.workflow.session_manager import SessionManager

    engine = Engine(root_dir=cfg.apeiron_root)
    engine.discover()
    scene_path = cfg.apeiron_root / "scenes" / cfg.default_scene
    if scene_path.exists():
        try:
            engine.load_scene(scene_path)
            engine.precompute()
        except Exception:
            pass
    fw = FileWatcher(engine=engine)
    sm = SessionManager(state_dir=cfg.state_dir)
    inbox = Inbox(state_dir=cfg.state_dir)

    registry = CommandRegistry()
    register_all(registry)

    ctx = CommandContext(
        engine=engine,
        session_manager=sm,
        inbox=inbox,
        file_watcher=fw,
        config=cfg,
        apeiron_root=cfg.apeiron_root,
    )
    result = registry.run(cmd_line, ctx, source="cli")
    if result.message:
        print(result.message)
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
