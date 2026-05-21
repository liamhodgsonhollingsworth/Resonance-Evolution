"""Command registry — the GUI↔CLI 1:1 contract for the workflow surface.

Every interactive surface in the Streamlit GUI is also a textual
command. The terminal panel renders the command log, accepts typed
input, and dispatches against this registry. GUI buttons in panels
call the same handler the terminal would, then push the textual form
of the invocation into the log so the maintainer always sees the
isomorphic CLI command for each click — the "as much 1:1 as possible"
property the maintainer named in the workflow plan.

Three external interfaces use the registry identically:

1. **GUI buttons** — a panel's render function dispatches via
   ``CommandRegistry.run`` and the result echoes to the terminal.
2. **Terminal input** — typed text becomes ``CommandRegistry.run``.
3. **External CLI** — ``tools.workflow_streamlit.cli`` writes commands
   to a watched file; ``cli_bridge`` drains the file and dispatches.

There is exactly one place a command's behavior is implemented (its
handler); everything else is presentation.
"""

from __future__ import annotations

import shlex
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional


@dataclass
class CommandResult:
    """Return value from a command handler."""
    ok: bool = True
    message: str = ""
    data: Any = None

    @classmethod
    def ok_msg(cls, message: str = "ok", data: Any = None) -> "CommandResult":
        return cls(ok=True, message=message, data=data)

    @classmethod
    def err(cls, message: str) -> "CommandResult":
        return cls(ok=False, message=message)


@dataclass
class CommandContext:
    """What command handlers see. Same shape as PanelContext + room to grow."""
    engine: Any
    session_manager: Any
    inbox: Any
    file_watcher: Any
    config: Any
    apeiron_root: Any
    active_session_id: Optional[str] = None
    user: Optional[str] = None
    # Scratch reserved for handlers that need to communicate sideways
    # to a sibling panel within a single rerun.
    scratch: dict = field(default_factory=dict)


CommandHandler = Callable[[CommandContext, List[str]], CommandResult]


@dataclass
class Command:
    name: str                     # canonical name, e.g. "idea-queue.add"
    description: str              # one-line for `help`
    handler: CommandHandler
    arg_help: str = ""            # usage string, e.g. "<text...>"
    aliases: List[str] = field(default_factory=list)

    def usage(self) -> str:
        return f"{self.name} {self.arg_help}".strip()


@dataclass
class CommandLogEntry:
    ts: float
    source: str                   # "gui" | "terminal" | "cli" | "system"
    command: str                  # the raw textual command (what would appear in CLI)
    result: Optional[CommandResult] = None


class CommandRegistry:
    """Process-wide registry mapping textual command names to handlers.

    Lives on the cached runtime (so it's shared across every Streamlit
    rerun in the same browser session). Panels register their commands
    on first construction via ``register_panel_commands``; the terminal
    drains the resulting catalog for the help command and tab-complete.

    Re-registering an existing name is allowed — it replaces the
    handler. This is useful for hot-reloaded panel modules.
    """

    def __init__(self, max_log_entries: int = 500) -> None:
        self._commands: Dict[str, Command] = {}
        self._aliases: Dict[str, str] = {}
        self._log: List[CommandLogEntry] = []
        self._max_log_entries = max_log_entries

    # ----- registration -----

    def register(self, command: Command) -> None:
        self._commands[command.name] = command
        for alias in command.aliases:
            self._aliases[alias] = command.name

    def register_many(self, commands: List[Command]) -> None:
        for c in commands:
            self.register(c)

    def commands(self) -> List[Command]:
        return sorted(self._commands.values(), key=lambda c: c.name)

    def get(self, name: str) -> Optional[Command]:
        resolved = self._aliases.get(name, name)
        return self._commands.get(resolved)

    # ----- dispatch -----

    def run(
        self,
        command_line: str,
        ctx: CommandContext,
        source: str = "terminal",
    ) -> CommandResult:
        """Parse a command line and dispatch.

        Shell-style argument splitting (``shlex``). Empty input is a
        no-op OK. Unknown commands return an err with a hint.

        Every dispatch also prints a structured line to stdout so the
        cmd window (the "desktop terminal" surface) shows the parsing
        side — name, parsed args, source, OK/ERR. The in-page terminal
        renders the readable form; this print is the non-readable
        engineering view of the same event.
        """
        line = (command_line or "").strip()
        if not line:
            return CommandResult.ok_msg("")
        try:
            parts = shlex.split(line, posix=True)
        except ValueError as exc:
            result = CommandResult.err(f"parse error: {exc}")
            self._append_log(source, line, result)
            _stdout_echo(source, line, [], "parse-err", result)
            return result
        if not parts:
            return CommandResult.ok_msg("")
        name, args = parts[0], parts[1:]
        cmd = self.get(name)
        if cmd is None:
            result = CommandResult.err(f"unknown command: {name} (try `help`)")
            self._append_log(source, line, result)
            _stdout_echo(source, line, parts, "unknown", result)
            return result
        try:
            result = cmd.handler(ctx, args)
        except Exception as exc:
            result = CommandResult.err(f"{name}: {type(exc).__name__}: {exc}")
        self._append_log(source, line, result)
        _stdout_echo(source, line, parts, name, result)
        return result

    def run_gui(
        self,
        command_name: str,
        ctx: CommandContext,
        *args: str,
    ) -> CommandResult:
        """Shortcut for a GUI panel to invoke a command by name + args.

        The textual form is reconstructed for the log so a click in the
        GUI shows up in the terminal as the CLI command a typist would
        run. Strings are shell-escaped via ``shlex.join``.
        """
        textual = shlex.join([command_name, *args])
        return self.run(textual, ctx, source="gui")

    # ----- log -----

    def _append_log(self, source: str, command: str, result: CommandResult) -> None:
        self._log.append(
            CommandLogEntry(ts=time.time(), source=source, command=command, result=result)
        )
        if len(self._log) > self._max_log_entries:
            # Drop the oldest entries beyond the cap.
            self._log = self._log[-self._max_log_entries:]

    def log(self, limit: Optional[int] = None) -> List[CommandLogEntry]:
        if limit is None:
            return list(self._log)
        return list(self._log[-limit:])

    def clear_log(self) -> None:
        self._log = []


def _stdout_echo(source: str, line: str, parts, resolved: str, result: CommandResult) -> None:
    """Print the parsing side of a dispatch to stdout.

    Designed for the cmd window where ``streamlit run`` is hosted —
    the maintainer keeps that window open while using the page; every
    GUI button click, CLI injection, and typed command lands here in
    its parsed form. The in-page terminal renders the same event
    readably for the maintainer.
    """
    import sys as _sys
    marker = "ok" if result.ok else "err"
    parsed = repr(parts) if parts else "[]"
    msg_short = (result.message or "").splitlines()[0] if result.message else ""
    if len(msg_short) > 100:
        msg_short = msg_short[:97] + "..."
    try:
        print(
            f"[dispatch source={source} resolved={resolved} {marker}] "
            f"input={line!r} argv={parsed} -> {msg_short}",
            flush=True,
            file=_sys.stdout,
        )
    except UnicodeEncodeError:
        # Windows cp1252 console can't render non-ASCII chars; degrade
        # to ASCII so the dispatch echo still surfaces.
        ascii_msg = msg_short.encode("ascii", errors="replace").decode("ascii")
        ascii_input = line.encode("ascii", errors="replace").decode("ascii")
        print(
            f"[dispatch source={source} resolved={resolved} {marker}] "
            f"input={ascii_input!r} argv={parsed} -> {ascii_msg}",
            flush=True,
            file=_sys.stdout,
        )


def format_log_entry(entry: CommandLogEntry) -> str:
    """Plain-text rendering of a log entry. Used by tests + the terminal."""
    when = time.strftime("%H:%M:%S", time.localtime(entry.ts))
    src = f"[{entry.source}]"
    line = f"{when} {src} $ {entry.command}"
    if entry.result is not None:
        marker = "OK" if entry.result.ok else "ERR"
        if entry.result.message:
            line += f"\n           [{marker}] {entry.result.message}"
        elif not entry.result.ok:
            line += f"\n           [{marker}]"
    return line
