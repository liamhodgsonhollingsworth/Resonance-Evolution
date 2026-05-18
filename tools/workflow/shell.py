"""
Workflow shell — the interactive REPL that hosts the workflow-from-within
loop.

Boots the Apeiron engine, starts the file-watcher, drives a chat REPL,
spawns Claude Code sessions as subprocesses, and routes messages between
the user, sessions, and the file-based inbox.

The shell is the load-bearing deliverable of Phase 3 in
[design/workflow_from_within_apeiron.md](../../design/workflow_from_within_apeiron.md).
What the maintainer asked for — "all future work performed from inside
the software, including communication with claude code sessions; add ANY
new features from the wishlist without having to restart" — is satisfied
by composing five existing pieces (engine, file-watcher, ChatInterpreter,
TextRenderer, MCPSource) with two new ones (this shell and the session
manager next to it).

UX model:

- A background thread reads `stdin` into a queue so events arriving from
  sessions / the file-watcher / the inbox can print to stdout without
  blocking on the user's typing.
- The main loop alternates: drain the event queue, then poll the input
  queue for 200ms. Either path renders into the same scroll buffer; the
  prompt redraws after each line so the experience stays usable.
- Slash commands are dispatched directly; bare text is routed to the
  currently-targeted session (defaulting to the most recently spawned).
- File-watcher events surface as `[fwatch new Clock node_types/clock.py]`
  so the maintainer can see hot-reload happening in real time. This is
  the visible proof that "add ANY new feature without restart" works.

Run it from the Apeiron repo root:

    python -m tools.workflow [--scene scenes/workflow_view.json]

Slash commands available at the prompt: `/help`, `/list`, `/spawn`,
`/send`, `/target`, `/inbox`, `/wish`, `/render`, `/types`, `/nodes`,
`/dispatch`, `/reload`, `/quit`. Bare text without a slash is sent to the
active session; if no session is active a hint surfaces.
"""

from __future__ import annotations

import argparse
import json
import queue
import shlex
import sys
import threading
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from engine.core import Engine
from engine.file_watcher import FileWatcher

from .inbox import Inbox, InboxMessage
from .session_manager import (
    SessionError,
    SessionEvent,
    SessionManager,
    SessionRecord,
)


HELP_TEXT = """\
Workflow shell -- commands:

  /help                              Show this help.
  /list [sessions|types|nodes|inbox] List sessions / node-types / live nodes / inbox.
  /spawn <type> [name] [-- seed]     Spawn a Claude Code session.
                                       e.g. /spawn workflow-management coordinator
                                       e.g. /spawn parallel-development worker -- build a Clock node-type
  /target <session_id|name|none>     Route bare-text input to this session.
                                       'none' clears the active target.
  /send <session> <message>          Send a message to a specific session.
  /wish <description>                Submit a feature request to the active session.
                                       Auto-spawns one if none is active.
                                       The session is told it can write new
                                       node-type files; the file-watcher picks
                                       them up without a restart.
  /inbox [unread|to <addr>|post ...] Inspect the file-based inbox.
                                       /inbox post <to> <kind> <summary>
                                          [-- body]
  /render <renderer> <viewer_path>   Render a scene via a registered renderer.
                                       Example: /render TextRenderer 0,0,5
  /types                             List currently-registered node-types.
  /nodes                             List live spawned nodes in the scene.
  /dispatch <cmd ...>                Dispatch a text-API command (the same grammar
                                       as tools/text_test.py).
  /reload <type_name>                Manually hot-reload a node-type module.
  /archive <session_id>              Archive a session (terminate + persist).
  /quit                              Exit the shell. Sessions persist on disk.

Bare text (no leading /) is sent to the currently-targeted session. If no
session is targeted, the shell prints a hint and the message is dropped.
"""


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="tools.workflow", description="Apeiron workflow shell.")
    parser.add_argument("--scene", default=None, help="Optional scene to load at boot.")
    parser.add_argument(
        "--state-dir",
        default=None,
        help="State directory (sessions, inbox, raw_logs). Defaults to <repo>/state/workflow/.",
    )
    parser.add_argument(
        "--no-watch",
        action="store_true",
        help="Skip the file-watcher (smoke testing only).",
    )
    parser.add_argument(
        "--root",
        default=None,
        help="Apeiron repo root. Defaults to detection via cwd.",
    )
    args = parser.parse_args(argv)

    root = Path(args.root) if args.root else _detect_root()
    state_dir = Path(args.state_dir) if args.state_dir else (root / "state" / "workflow")

    engine = Engine(root_dir=root)
    engine.discover()

    if args.scene:
        scene_path = (root / "scenes" / args.scene) if not Path(args.scene).is_absolute() else Path(args.scene)
        if scene_path.exists():
            engine.load_scene(scene_path)
        else:
            sys.stderr.write(f"warning: scene not found: {scene_path}\n")

    inbox = Inbox(state_dir=state_dir)
    sm = SessionManager(state_dir=state_dir)

    shell = Shell(engine=engine, session_manager=sm, inbox=inbox, root=root)
    fw: Optional[FileWatcher] = None
    if not args.no_watch:
        fw = FileWatcher(engine, on_event=shell.on_file_event)
        fw.start()
    shell.file_watcher = fw

    try:
        shell.run()
    finally:
        if fw is not None:
            fw.stop()
        sm.shutdown()

    return 0


class Shell:
    def __init__(
        self,
        engine: Engine,
        session_manager: SessionManager,
        inbox: Inbox,
        root: Path,
        out=sys.stdout,
        err=sys.stderr,
        in_=sys.stdin,
    ):
        self.engine = engine
        self.sm = session_manager
        self.inbox = inbox
        self.root = Path(root)
        self.out = out
        self.err = err
        self.in_ = in_
        self.active_session_id: Optional[str] = None
        self.running = False
        self.file_watcher: Optional[FileWatcher] = None
        self._last_inbox_scan = 0.0
        self._seen_inbox_paths: set = set()
        self._lock = threading.Lock()
        # Seed inbox baseline so existing messages don't all flood on first scan.
        for msg in self.inbox.list_all():
            self._seen_inbox_paths.add(str(msg.path))
        # Prompt redraw helpers.
        self._current_input = ""

    # ----- entry -----

    def run(self) -> None:
        self.running = True
        self._print_banner()
        input_q: "queue.Queue[str]" = queue.Queue()
        threading.Thread(target=self._read_stdin, args=(input_q,), daemon=True).start()
        self._print_prompt()
        try:
            while self.running:
                self._drain_session_events()
                self._poll_inbox()
                try:
                    line = input_q.get(timeout=0.2)
                except queue.Empty:
                    continue
                if line is None:
                    self.running = False
                    break
                try:
                    self._handle_input(line)
                except Exception as exc:
                    self._println(f"[error] {exc}")
                self._print_prompt()
        except KeyboardInterrupt:
            self._println("\n[shell] interrupted; shutting down…")

    # ----- handlers -----

    def _handle_input(self, line: str) -> None:
        line = (line or "").strip()
        if not line:
            return
        if line.startswith("/"):
            self._dispatch_slash(line[1:])
            return
        # Bare text → active session
        if self.active_session_id is None:
            self._println(
                "[shell] no active session; spawn one with `/spawn <type>` "
                "or send via `/send <session> <message>`."
            )
            return
        self._send_to(self.active_session_id, line)

    def _dispatch_slash(self, body: str) -> None:
        # Allow `--` to mark a free-form tail so messages with quotes pass through.
        head, _, tail = body.partition(" -- ")
        try:
            argv = shlex.split(head)
        except ValueError as exc:
            self._println(f"[shell] parse error: {exc}")
            return
        if not argv:
            self._println("[shell] empty command. Try /help.")
            return
        cmd, *rest = argv
        if tail:
            rest.append(tail)
        method = getattr(self, f"cmd_{cmd}", None)
        if method is None:
            self._println(f"[shell] unknown command: /{cmd} (try /help)")
            return
        method(rest)

    # ----- commands -----

    def cmd_help(self, _argv: List[str]) -> None:
        self._println(HELP_TEXT)

    def cmd_quit(self, _argv: List[str]) -> None:
        self.running = False

    def cmd_list(self, argv: List[str]) -> None:
        what = (argv[0] if argv else "sessions").lower()
        if what.startswith("session"):
            return self._list_sessions()
        if what == "types":
            return self._list_types()
        if what == "nodes":
            return self._list_nodes()
        if what == "inbox":
            return self._list_inbox(unread_only=False)
        self._println(f"[shell] unknown /list target: {what}")

    def cmd_types(self, _argv: List[str]) -> None:
        self._list_types()

    def cmd_nodes(self, _argv: List[str]) -> None:
        self._list_nodes()

    def cmd_inbox(self, argv: List[str]) -> None:
        if not argv or argv[0] == "unread":
            self._list_inbox(unread_only=True)
            return
        if argv[0] == "all":
            self._list_inbox(unread_only=False)
            return
        if argv[0] == "to":
            if len(argv) < 2:
                self._println("[shell] /inbox to <recipient>")
                return
            recipient = argv[1]
            for msg in self.inbox.list_for(recipient, unread_only=False):
                self._show_inbox(msg)
            return
        if argv[0] == "post":
            if len(argv) < 4:
                self._println("[shell] /inbox post <to> <kind> <summary> [-- body]")
                return
            to, kind, summary = argv[1], argv[2], argv[3]
            body = argv[4] if len(argv) >= 5 else ""
            path = self.inbox.post(to=to, kind=kind, summary=summary, body=body)
            self._println(f"[inbox] posted -> {path}")
            return
        self._println(f"[shell] unknown /inbox sub-command: {argv[0]}")

    def cmd_spawn(self, argv: List[str]) -> None:
        if not argv:
            self._println("[shell] /spawn <session_type> [display_name] [-- seed message]")
            return
        session_type = argv[0]
        display_name = argv[1] if len(argv) > 1 and "--" not in argv[1:] else None
        # Last item is the seed tail when -- was used in body.
        seed_message = None
        if len(argv) >= 3 and " " in argv[-1]:
            seed_message = argv[-1]
        elif len(argv) >= 2 and len(argv[-1]) > 0 and (len(argv) > 2 or len(argv[-1].split()) > 1):
            seed_message = argv[-1] if argv[-1] != display_name else None

        try:
            rec = self.sm.spawn(
                session_type=session_type,
                display_name=display_name,
                seed_message=seed_message,
                cwd=self.root,
            )
        except SessionError as exc:
            self._println(f"[shell] spawn failed: {exc}")
            return
        self.active_session_id = rec.id
        self._println(
            f"[shell] spawned session {rec.display_name} ({rec.id[:8]}) "
            f"type={rec.session_type}. Now active."
        )

    def cmd_send(self, argv: List[str]) -> None:
        if len(argv) < 2:
            self._println("[shell] /send <session_id_or_name> <message>")
            return
        target, *rest = argv
        body = " ".join(rest)
        sid = self._resolve_session(target)
        if not sid:
            self._println(f"[shell] no such session: {target}")
            return
        self._send_to(sid, body)

    def cmd_target(self, argv: List[str]) -> None:
        if not argv:
            self._println(
                f"[shell] active target: {self.active_session_id or '(none)'}"
            )
            return
        choice = argv[0]
        if choice in ("none", "clear", "off"):
            self.active_session_id = None
            self._println("[shell] active target cleared.")
            return
        sid = self._resolve_session(choice)
        if not sid:
            self._println(f"[shell] no such session: {choice}")
            return
        self.active_session_id = sid
        self._println(f"[shell] active target -> {choice}")

    def cmd_wish(self, argv: List[str]) -> None:
        if not argv:
            self._println("[shell] /wish <description of feature to build>")
            return
        description = " ".join(argv).strip()
        sid = self.active_session_id
        if sid is None:
            # Auto-spawn a worker.
            try:
                rec = self.sm.spawn(
                    session_type="parallel-development",
                    display_name="wish-worker",
                    cwd=self.root,
                )
            except SessionError as exc:
                self._println(f"[shell] could not auto-spawn worker: {exc}")
                return
            sid = rec.id
            self.active_session_id = sid
            self._println(
                f"[shell] auto-spawned wish worker ({rec.id[:8]}). "
                "Will route the wish to it."
            )
        prompt = _build_wish_prompt(description, root=self.root)
        self._send_to(sid, prompt)

    def cmd_render(self, argv: List[str]) -> None:
        if len(argv) < 2:
            self._println("[shell] /render <renderer_type> <viewer_origin> [target] [up] [fov]")
            return
        # Defer to tools.text_test for behavior parity.
        try:
            from tools.text_test import dispatch_command
        except Exception as exc:
            self._println(f"[shell] could not import dispatch_command: {exc}")
            return
        result = dispatch_command(self.engine, ["render"] + argv)
        self._println(_format_text_api_result(result))

    def cmd_dispatch(self, argv: List[str]) -> None:
        if not argv:
            self._println("[shell] /dispatch <text-api command ...>")
            return
        try:
            from tools.text_test import dispatch_command
        except Exception as exc:
            self._println(f"[shell] could not import dispatch_command: {exc}")
            return
        result = dispatch_command(self.engine, argv)
        self._println(_format_text_api_result(result))

    def cmd_reload(self, argv: List[str]) -> None:
        if not argv:
            self._println("[shell] /reload <type_name>")
            return
        type_name = argv[0]
        try:
            ok = self.engine.reload_type(type_name)
        except Exception as exc:
            self._println(f"[shell] reload failed: {exc}")
            return
        self._println(f"[shell] reload({type_name}) -> {ok}")

    def cmd_archive(self, argv: List[str]) -> None:
        if not argv:
            self._println("[shell] /archive <session>")
            return
        sid = self._resolve_session(argv[0])
        if not sid:
            self._println(f"[shell] no such session: {argv[0]}")
            return
        self.sm.archive(sid)
        if self.active_session_id == sid:
            self.active_session_id = None
        self._println(f"[shell] archived {sid[:8]}")

    # ----- helpers -----

    def _list_sessions(self) -> None:
        recs = self.sm.list()
        if not recs:
            self._println("[shell] no sessions.")
            return
        for r in recs:
            marker = "*" if r.id == self.active_session_id else " "
            self._println(
                f" {marker} {r.id[:8]} {r.status:8s} {r.session_type:24s} {r.display_name}"
            )

    def _list_types(self) -> None:
        names = sorted(self.engine.types.keys())
        if not names:
            self._println("[shell] no node-types registered.")
            return
        for n in names:
            self._println(f"  {n}")

    def _list_nodes(self) -> None:
        if not self.engine.nodes:
            self._println("[shell] scene is empty.")
            return
        for nid, node in self.engine.nodes.items():
            type_name = getattr(node, "type_name", getattr(node, "type", "?"))
            status = getattr(node, "status", "?")
            self._println(f"  {nid:30s} {type_name:24s} status={status}")

    def _list_inbox(self, unread_only: bool = False) -> None:
        msgs = self.inbox.list_all(unread_only=unread_only)
        if not msgs:
            self._println("[shell] inbox is empty.")
            return
        for m in msgs:
            self._show_inbox(m)

    def _show_inbox(self, msg: InboxMessage) -> None:
        mark = " " if msg.read else "*"
        self._println(
            f" {mark} {time.strftime('%H:%M:%S', time.localtime(msg.ts))} "
            f"to={msg.to:24s} from={msg.sender:24s} kind={msg.kind:12s} "
            f"{msg.summary} :: {msg.path.name}"
        )

    def _resolve_session(self, ident: str) -> Optional[str]:
        recs = self.sm.list()
        for r in recs:
            if r.id == ident or r.id.startswith(ident):
                return r.id
            if r.display_name == ident:
                return r.id
        return None

    def _send_to(self, session_id: str, body: str) -> None:
        try:
            self.sm.send(session_id, body)
            rec = self.sm.get(session_id)
            label = rec.display_name if rec else session_id[:8]
            self._println(f"[shell] -> {label}")
        except SessionError as exc:
            self._println(f"[shell] send failed: {exc}")

    def _drain_session_events(self) -> None:
        events = self.sm.drain_events()
        for ev in events:
            self._show_session_event(ev)

    def _show_session_event(self, ev: SessionEvent) -> None:
        label = ev.session_display_name or ev.session_id[:8]
        if ev.kind == "communication":
            text = (ev.payload.get("text") or "").rstrip()
            if not text:
                return
            self._println(f"\n[{label}] {text}\n")
            return
        if ev.kind == "spawned":
            resumed = ev.payload.get("resumed")
            verb = "resumed" if resumed else "spawned"
            self._println(f"[session/{label}] {verb}")
            return
        if ev.kind == "turn_complete":
            cost = ev.payload.get("total_cost_usd")
            dur = ev.payload.get("duration_ms")
            extras = []
            if cost is not None:
                extras.append(f"${cost:.4f}")
            if dur is not None:
                extras.append(f"{dur}ms")
            tail = f" ({', '.join(extras)})" if extras else ""
            self._println(f"[session/{label}] turn complete{tail}")
            return
        if ev.kind in ("session_idle", "session_error"):
            code = ev.payload.get("exit_code")
            self._println(f"[session/{label}] {ev.kind} exit={code}")
            return
        if ev.kind == "silent_too_long":
            silent = ev.payload.get("silent_for_s")
            self._println(f"[session/{label}] silent for {silent:.0f}s")
            return
        if ev.kind == "tool_use":
            self._println(f"[session/{label}] tool_use {ev.payload.get('name')}")
            return
        # activity / tool_result / archived — minimal:
        self._println(f"[session/{label}] {ev.kind} {ev.payload}")

    def on_file_event(self, kind: str, type_name: str, path: Path) -> None:
        """Called by FileWatcher when a node-type file is added/modified/deleted."""
        self._println(f"[fwatch] {kind} {type_name} {path.relative_to(self.root) if path.is_absolute() and self.root in path.parents else path.name}")

    def _poll_inbox(self) -> None:
        now = time.time()
        if now - self._last_inbox_scan < 1.0:
            return
        self._last_inbox_scan = now
        for msg in self.inbox.list_all():
            key = str(msg.path)
            if key in self._seen_inbox_paths:
                continue
            self._seen_inbox_paths.add(key)
            self._println(
                f"[inbox] new to={msg.to} from={msg.sender} kind={msg.kind} :: {msg.summary}"
            )

    # ----- IO -----

    def _print_banner(self) -> None:
        n_types = len(self.engine.types)
        n_nodes = len(self.engine.nodes)
        self._println("Apeiron workflow shell")
        self._println(
            f"  root={self.root}  node-types={n_types}  scene-nodes={n_nodes}  "
            f"watch={'on' if self.file_watcher else 'off'}"
        )
        self._println("  /help for commands. Bare text is sent to the active session.")
        self._println("")

    def _print_prompt(self) -> None:
        target = "*" if self.active_session_id is None else self.active_session_id[:8]
        try:
            self.out.write(f"workflow [{target}]> ")
            self.out.flush()
        except Exception:
            pass

    def _println(self, text: str = "") -> None:
        try:
            with self._lock:
                self.out.write(text + "\n")
                self.out.flush()
        except Exception:
            pass

    def _read_stdin(self, q: "queue.Queue[str]") -> None:
        for line in iter(self.in_.readline, ""):
            q.put(line.rstrip("\n"))
        q.put(None)  # signal EOF


# ----- helpers / detectors -----


def _detect_root() -> Path:
    cwd = Path.cwd().resolve()
    for p in [cwd, *cwd.parents]:
        if (p / "engine" / "core.py").exists() and (p / "node_types").is_dir():
            return p
    return cwd


def _format_text_api_result(result: Any) -> str:
    if isinstance(result, (dict, list)):
        return json.dumps(result, indent=2, default=str)
    return str(result)


def _build_wish_prompt(description: str, root: Path) -> str:
    """The seed message a wish-worker session receives."""
    rel = root.as_posix()
    return (
        f"You are running inside the Apeiron workflow shell at {rel}.\n\n"
        f"The maintainer has a feature request:\n\n"
        f"    {description}\n\n"
        "Steps:\n"
        "1. Read architecture.md and pick an existing simple node-type to use as a "
        "template (e.g. node_types/cube.py, node_types/light.py, or node_types/"
        "list_renderer.py).\n"
        "2. Create the new file under node_types/<short_name>.py (or "
        "renderers/<short_name>.py if it's a renderer-node). Implement "
        "manifest() with a unique `name`, build(), and emit(). Add "
        "precompute_hook / select_children only if needed.\n"
        "3. Add a test under tests/ when behavior is non-trivial.\n"
        "4. The file-watcher will hot-reload the new type — no restart is "
        "needed. Confirm by saying which type-name to spawn (e.g. "
        "`spawn <Type>`), and the maintainer (or you) can use it "
        "immediately.\n"
        "5. Keep the work small and the diff focused. Reply with a one-line "
        "summary of what landed.\n\n"
        "If the request is ambiguous or trivial, ask one clarifying question "
        "before writing files. Only do work in this repo (Apeiron); do not "
        "make changes elsewhere."
    )


if __name__ == "__main__":
    raise SystemExit(main())
