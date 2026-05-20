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
import os
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

from .auth import DEFAULT_ACCOUNTS_PATH
from .inbox import Inbox, InboxMessage
from .session_manager import (
    SessionError,
    SessionEvent,
    SessionManager,
    SessionRecord,
)
from .quarantine import quarantine_delete, quarantine_promote_sender, scan_message
from .trust import (
    render_trust_set,
    sender_trust_set,
    session_trust_set,
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
  /realtime [scene] [w] [h]          Open the scene in an interactive Tk window.
                                       Default scene: scenes/workflow_view.json.
                                       Default size: 800x600. WASD = move,
                                       mouse = look, Esc = WorkflowView mode
                                       toggle / quit. Blocks the shell until
                                       the window closes.
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
    parser.add_argument(
        "--no-default-session",
        action="store_true",
        help="Skip auto-spawn of the default workflow-management session at startup (smoke testing).",
    )
    parser.add_argument(
        "--alethea-root",
        default=None,
        help="Path to the Alethea repo root, used to locate the design-specification skill + SPECIFICATIONS doc for the workflow-management seed prompt. Defaults to a sibling-of-Apeiron heuristic.",
    )
    parser.add_argument(
        "--launch-realtime",
        action="store_true",
        help=(
            "Spawn the realtime window in a separate process at startup. "
            "Used by scripts/launch_apeiron.bat for one-click GUI launch "
            "(SPEC-001). The shell and the window run concurrently as "
            "two processes — both share scene files, state dir, and "
            "inbox via the filesystem."
        ),
    )
    parser.add_argument(
        "--skip-auth",
        action="store_true",
        help=(
            "Skip the login gate (SPEC-056). For testing or for dev "
            "workflows where authentication is enforced elsewhere. "
            "Default is to require sign-in before the shell boots."
        ),
    )
    parser.add_argument(
        "--accounts-path",
        default=None,
        help="Override the accounts store path. Defaults to <repo>/state/accounts.json.",
    )
    args = parser.parse_args(argv)

    root = Path(args.root) if args.root else _detect_root()
    state_dir = Path(args.state_dir) if args.state_dir else (root / "state" / "workflow")
    alethea_root = Path(args.alethea_root) if args.alethea_root else _detect_alethea_root(root)
    accounts_path = (
        Path(args.accounts_path) if args.accounts_path else (root / DEFAULT_ACCOUNTS_PATH)
    )

    current_user: Optional[str] = None
    if not args.skip_auth:
        try:
            from .login_gate import run_login_gate
        except Exception as exc:
            sys.stderr.write(
                f"error: could not load login gate ({exc}); pass --skip-auth to bypass.\n"
            )
            return 2
        current_user = run_login_gate(accounts_path=accounts_path)
        if current_user is None:
            sys.stderr.write("Sign-in cancelled. Exiting.\n")
            return 1

    render_ts = render_trust_set(root)
    engine = Engine(root_dir=root, trust_set=render_ts)
    engine.discover()

    initial_scene_root: Optional[str] = None
    initial_scene_path: Optional[Path] = None
    if args.scene:
        scene_path = (root / "scenes" / args.scene) if not Path(args.scene).is_absolute() else Path(args.scene)
        # Allow `--scene workflow_view` as shorthand for the .json file —
        # the maintainer's desktop shortcut launcher passes the bare name
        # and shouldn't have to know about file extensions.
        if not scene_path.exists() and scene_path.suffix != ".json":
            with_suffix = scene_path.with_suffix(".json")
            if with_suffix.exists():
                scene_path = with_suffix
        if scene_path.exists():
            initial_scene_root = engine.load_scene(scene_path)
            initial_scene_path = scene_path
        else:
            sys.stderr.write(f"warning: scene not found: {scene_path}\n")

    sender_ts = sender_trust_set(root, user=current_user)
    session_ts = session_trust_set(root, user=current_user)

    inbox = Inbox(
        state_dir=state_dir,
        sender_trust=sender_ts,
        session_trust=session_ts,
    )
    sm = SessionManager(state_dir=state_dir)

    for source_id in engine.untrusted_encounters:
        inbox.post(
            to=current_user or "LHH",
            kind="trust-decision",
            summary=f"Untrusted node-type source: {source_id}",
            body=(
                f"Apeiron discovered a node-type source file at "
                f"`{source_id}` that is not in the render-trust set. "
                f"The source was NOT loaded — any scene referencing its "
                f"type-name will render the typed-zero placeholder.\n\n"
                f"To promote this source to trusted, add the path to "
                f"`state/trusted_sources.json` under the `trusted` list "
                f"(version 1 format), or use a future trust-management "
                f"action once the UI surface lands."
            ),
            sender="apeiron-engine",
        )

    shell = Shell(
        engine=engine,
        session_manager=sm,
        inbox=inbox,
        root=root,
        alethea_root=alethea_root,
        sender_trust=sender_ts,
        session_trust=session_ts,
    )
    shell.current_user = current_user
    shell.last_scene_root = initial_scene_root
    shell.last_scene_path = initial_scene_path
    fw: Optional[FileWatcher] = None
    if not args.no_watch:
        fw = FileWatcher(engine, on_event=shell.on_file_event)
        fw.start()
    shell.file_watcher = fw

    if not args.no_default_session:
        shell.ensure_default_workflow_mgmt_session()

    if args.launch_realtime and initial_scene_path is not None:
        shell.launch_realtime_subprocess(initial_scene_path)
    elif args.launch_realtime:
        sys.stderr.write(
            "warning: --launch-realtime requested but no --scene was loaded.\n"
        )

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
        alethea_root: Optional[Path] = None,
        sender_trust: Any = None,
        session_trust: Any = None,
    ):
        self.engine = engine
        self.sm = session_manager
        self.inbox = inbox
        self.root = Path(root)
        self.alethea_root = Path(alethea_root) if alethea_root else None
        self.out = out
        self.err = err
        self.in_ = in_
        self.active_session_id: Optional[str] = None
        self.current_user: Optional[str] = None
        self.running = False
        self.file_watcher: Optional[FileWatcher] = None
        self.sender_trust = sender_trust
        self.session_trust = session_trust
        # Set by main() after engine.load_scene; /realtime defaults to these.
        self.last_scene_root: Optional[str] = None
        self.last_scene_path: Optional[Path] = None
        self._last_inbox_scan = 0.0
        self._seen_inbox_paths: set = set()
        self._lock = threading.Lock()
        # Seed inbox baseline so existing messages don't all flood on first scan.
        for msg in self.inbox.list_all():
            self._seen_inbox_paths.add(str(msg.path))
        # Prompt redraw helpers.
        self._current_input = ""

    # ----- default workflow-management session (SPEC-002, SPEC-003) -----

    def _default_session_marker_path(self) -> Path:
        """File that records the persistent ID of the default workflow-management session."""
        return Path(self.sm.state_dir) / "default_workflow_mgmt.txt"

    def ensure_default_workflow_mgmt_session(self) -> Optional[str]:
        """
        Ensure a workflow-management session exists and is set as the active
        chat target. Spawns one with the design-specification seed prompt if
        no persistent ID is recorded; otherwise sets the recorded session as
        active without re-spawning (the SessionManager auto-reactivates on
        next send).

        Returns the active session id, or None if spawn failed.
        """
        marker = self._default_session_marker_path()
        existing_id: Optional[str] = None
        if marker.exists():
            try:
                existing_id = marker.read_text(encoding="utf-8").strip() or None
            except Exception:
                existing_id = None

        if existing_id:
            rec = self.sm.get(existing_id)
            if rec is not None and rec.status != "archived":
                self.active_session_id = existing_id
                self._println(
                    f"[shell] default workflow-management session ready: "
                    f"{rec.display_name} ({existing_id[:8]}). Bare text routes here."
                )
                return existing_id
            # Marker exists but session is gone or archived; fall through to fresh spawn.

        seed = _build_workflow_mgmt_seed(
            apeiron_root=self.root,
            alethea_root=self.alethea_root,
        )
        try:
            rec = self.sm.spawn(
                session_type="workflow-management",
                display_name="workflow-mgmt-default",
                cwd=self.root,
                seed_message=seed,
            )
        except SessionError as exc:
            self._println(
                f"[shell] could not auto-spawn the default workflow-management "
                f"session ({exc}). The shell still works; spawn manually with "
                f"`/spawn workflow-management <name>` once `claude` is on PATH."
            )
            return None

        self.active_session_id = rec.id
        try:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(rec.id, encoding="utf-8")
        except Exception:
            pass
        self._println(
            f"[shell] auto-spawned default workflow-management session "
            f"{rec.display_name} ({rec.id[:8]}). Bare text routes here from now on."
        )
        return rec.id

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
            self._list_inbox(unread_only=True, surface="main")
            return
        if argv[0] == "all":
            self._list_inbox(unread_only=False, surface="main")
            return
        if argv[0] == "quarantine":
            self._list_inbox(unread_only=False, surface="quarantine")
            return
        if argv[0] == "raw":
            self._list_inbox(unread_only=False, surface="raw")
            return
        if argv[0] == "trust":
            if len(argv) < 2:
                self._println("[shell] /inbox trust <sender>")
                return
            sender = argv[1]
            if self.sender_trust is None:
                self._println("[shell] no sender-trust configured; cannot trust.")
                return
            self.sender_trust.add(sender)
            self._println(f"[shell] sender {sender!r} promoted to trusted.")
            return
        if argv[0] == "delete":
            if len(argv) < 2:
                self._println("[shell] /inbox delete <filename-substring>")
                return
            needle = argv[1]
            removed = 0
            for msg in self.inbox.list_quarantine():
                if needle in msg.path.name:
                    quarantine_delete(msg)
                    removed += 1
            self._println(f"[shell] deleted {removed} quarantined message(s).")
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

    def launch_realtime_subprocess(self, scene_path: Path) -> Optional[int]:
        """Spawn ``python -m tools.realtime <scene>`` as a separate process.

        Used by the ``--launch-realtime`` flag for one-click GUI launch
        (SPEC-001). Returns the subprocess pid on success, ``None`` on
        failure. The subprocess has its own engine instance; file/state
        coordination is via the shared filesystem (scenes/, state/,
        Alethea-cc/nodes/).

        This is intentionally fire-and-forget: the shell doesn't wait for
        the window to close, and closing the window doesn't affect the
        shell. The maintainer can spawn additional windows via
        ``/realtime`` from the shell prompt — that one blocks; this one
        doesn't.
        """
        import subprocess as _sp

        try:
            proc = _sp.Popen(
                [sys.executable, "-m", "tools.realtime", str(scene_path)],
                cwd=str(self.root),
                creationflags=getattr(_sp, "CREATE_NEW_PROCESS_GROUP", 0),
            )
        except Exception as exc:
            self._println(
                f"[shell] --launch-realtime: subprocess spawn failed: {exc}"
            )
            return None
        self._println(
            f"[shell] --launch-realtime: opened realtime window (pid {proc.pid}) "
            f"with scene {scene_path.name}. Close the window or quit the shell "
            f"to stop it."
        )
        return proc.pid

    def cmd_realtime(self, argv: List[str]) -> None:
        """Open the current (or named) scene in an interactive Tk window.

        Forms:
            /realtime                       — workflow_view scene at 800x600
            /realtime <scene-or-path>       — load and open the named scene
            /realtime <scene> <w> <h>       — explicit window size

        Blocks the shell until the window closes. The engine is shared with
        the shell, so file-watcher hot-reloads in the shell are reflected in
        the realtime window's next frame.
        """
        scene_arg = argv[0] if argv else None
        try:
            width = int(argv[1]) if len(argv) > 1 else 800
            height = int(argv[2]) if len(argv) > 2 else 600
        except ValueError:
            self._println("[shell] /realtime: width and height must be integers")
            return

        if scene_arg is None:
            scene_path = self.last_scene_path or (self.root / "scenes" / "workflow_view.json")
            scene_root = self.last_scene_root
        else:
            scene_path = (self.root / "scenes" / scene_arg) if not Path(scene_arg).is_absolute() else Path(scene_arg)
            if not scene_path.suffix:
                scene_path = scene_path.with_suffix(".json")
            scene_root = None

        if not scene_path.exists():
            self._println(f"[shell] /realtime: scene not found: {scene_path}")
            return

        try:
            if scene_root is None:
                scene_root = self.engine.load_scene(scene_path)
                self.last_scene_path = scene_path
                self.last_scene_root = scene_root
        except Exception as exc:
            self._println(f"[shell] /realtime: load_scene failed: {exc}")
            return

        try:
            scene_data = json.loads(scene_path.read_text(encoding="utf-8"))
        except Exception as exc:
            self._println(f"[shell] /realtime: could not read scene json: {exc}")
            return

        try:
            from engine import View, look_at
            from engine.realtime import RealtimeDriver, available_backends, make_backend
            import numpy as np
        except Exception as exc:
            self._println(f"[shell] /realtime: import failed: {exc}")
            return

        backends = available_backends()
        if not backends:
            self._println("[shell] /realtime: no windowing backend available (need tkinter or pygame)")
            return

        view_meta = scene_data.get("view", {}) or {}
        position = np.asarray(view_meta.get("position", [3.0, 2.0, 5.0]), dtype=np.float64)
        if "orientation" in view_meta:
            orientation = np.asarray(view_meta["orientation"], dtype=np.float64).reshape(3, 3)
        else:
            target = np.asarray(view_meta.get("look_at", [0.0, 0.0, 0.0]), dtype=np.float64)
            orientation = look_at(position, target)
        view = View(
            position=position,
            orientation=orientation,
            scale=float(view_meta.get("scale", 1.0)),
            width=int(view_meta.get("width", width)),
            height=int(view_meta.get("height", height)),
            fov_y_radians=float(view_meta.get("fov_y_radians", np.pi / 4)),
        )

        try:
            self.engine.precompute()
        except Exception as exc:
            self._println(f"[shell] /realtime: precompute warning: {exc}")

        driver = RealtimeDriver(
            engine=self.engine,
            root_id=scene_root,
            view=view,
            frame_budget_s=1.0 / 60.0,
        )
        backend = make_backend()
        try:
            backend.open(width=width, height=height, title=f"Apeiron — {scene_path.name}")
        except Exception as exc:
            self._println(f"[shell] /realtime: window open failed: {exc}")
            return
        self._println(
            f"[shell] /realtime open: scene={scene_path.name} root={scene_root} "
            f"backend={type(backend).__name__}. Close the window to return."
        )
        try:
            rendered = driver.run(backend)
            self._println(f"[shell] /realtime closed; rendered {rendered} frame(s).")
        except Exception as exc:
            self._println(f"[shell] /realtime: driver crashed: {exc}")

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

    def _list_inbox(self, unread_only: bool = False, surface: str = "main") -> None:
        if surface == "quarantine":
            msgs = self.inbox.list_quarantine(unread_only=unread_only)
            label = "quarantine"
        elif surface == "raw":
            msgs = self.inbox.list_all(unread_only=unread_only)
            label = "raw"
        else:
            msgs = self.inbox.list_main(unread_only=unread_only)
            label = "main"
        if not msgs:
            self._println(f"[shell] {label} inbox is empty.")
            return
        for m in msgs:
            self._show_inbox(m)
            if surface == "quarantine":
                self._show_scan(m)

    def _show_inbox(self, msg: InboxMessage) -> None:
        mark = " " if msg.read else "*"
        self._println(
            f" {mark} {time.strftime('%H:%M:%S', time.localtime(msg.ts))} "
            f"to={msg.to:24s} from={msg.sender:24s} kind={msg.kind:12s} "
            f"{msg.summary} :: {msg.path.name}"
        )

    def _show_scan(self, msg: InboxMessage) -> None:
        """Annotate a quarantined message with its scan findings (SPEC-058)."""
        report = scan_message(msg)
        self._println(
            f"   scan: severity={report.overall_severity} "
            f"anomaly={report.anomaly_score:.2f} findings={len(report.findings)}"
        )
        for f in report.findings:
            excerpt = f.excerpt.replace("\n", " ")[:80]
            self._println(
                f"     - [{f.severity}] {f.category}: {f.detail}"
                + (f" :: {excerpt}" if excerpt else "")
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
        """Print high-signal events; suppress the noisy fine-grained ones.

        High-signal (always printed): communication, spawned, turn_complete,
        session_idle, session_error, silent_too_long. These mark life-cycle
        events and turns the maintainer cares about.

        Suppressed by default: tool_use, tool_result, activity, archived,
        and the catchall — these can fire hundreds of times per session
        (the default workflow-management session emits dozens of
        ``Read`` / ``Bash`` / ``Grep`` calls between turns, and printing
        each one floods the terminal). Set ``APEIRON_VERBOSE_SESSIONS=1``
        in the environment to see them. The raw JSONL log at
        ``state/workflow/raw_logs/<session_id>.jsonl`` always carries the
        full trace regardless of this filter.
        """
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
        if not os.environ.get("APEIRON_VERBOSE_SESSIONS"):
            return
        if ev.kind == "tool_use":
            self._println(f"[session/{label}] tool_use {ev.payload.get('name')}")
            return
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
            if self.inbox.is_sender_trusted(msg.sender):
                self._println(
                    f"[inbox] new to={msg.to} from={msg.sender} kind={msg.kind} :: {msg.summary}"
                )
            else:
                self._println(
                    f"[quarantine] new to={msg.to} from={msg.sender} kind={msg.kind} :: {msg.summary} "
                    f"(/inbox quarantine to review)"
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


def _detect_alethea_root(apeiron_root: Path) -> Optional[Path]:
    """
    Locate the Alethea checkout (sibling of Apeiron on the maintainer's
    machine). The workflow-management session reads
    `<alethea>/specifications/README.md`, `<alethea>/skills/design-specification.md`,
    and `<alethea>/session_types/workflow_management.md` at startup.

    Resolution:
    1. ALETHEA_ROOT env var
    2. Sibling of the Apeiron root named "Alethea"
    3. Standard maintainer location at C:/Users/Liam/Desktop/Alethea
    4. Walk parents for an "Alethea/CLAUDE.md" pair
    """
    explicit = os.environ.get("ALETHEA_ROOT")
    if explicit and Path(explicit).exists():
        return Path(explicit)

    sibling = apeiron_root.parent / "Alethea"
    if (sibling / "CLAUDE.md").exists():
        return sibling

    canonical = Path("C:/Users/Liam/Desktop/Alethea")
    if (canonical / "CLAUDE.md").exists():
        return canonical

    for parent in [apeiron_root, *apeiron_root.parents]:
        candidate = parent / "Alethea"
        if (candidate / "CLAUDE.md").exists():
            return candidate

    return None


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


def _build_workflow_mgmt_seed(apeiron_root: Path, alethea_root: Optional[Path]) -> str:
    """
    Seed message for the always-on workflow-management session (SPEC-002 / SPEC-003).

    The session is the default chat recipient for the workflow shell. It receives
    every bare-text message the maintainer types and is responsible for:

      - Classifying intent: feature description, action request, regression flag,
        completion query, or conversational.
      - Drafting SPEC-NNN entries (intake-from-chat) when feature descriptions
        arrive, per the design-specification skill.
      - Routing implementation work to wish-granting / parallel-development
        worker sessions via /spawn or the inbox, per SPEC-020.
      - Maintaining the canonical SPECIFICATIONS document.

    The seed primes the session with absolute paths to the documents it must
    read at startup, so it doesn't have to discover them on its own.
    """
    apeiron = apeiron_root.as_posix()
    alethea = alethea_root.as_posix() if alethea_root else "(not detected — ask the maintainer)"
    return (
        "You are the always-on workflow-management session for the Alethea / "
        "Apeiron workflow surface. The maintainer's chat shell routes bare-text "
        "messages to you by default — you are the single default recipient. "
        "Other sessions are your colleagues; you dispatch work to them and "
        "report their results back to the maintainer.\n\n"
        "## Repos on this machine\n"
        f"- Apeiron (this session's cwd, the engine + node-types + this shell): {apeiron}\n"
        f"- Alethea (session-types, skills, mistakes, specifications): {alethea}\n\n"
        "## Read these at startup, in full\n"
        f"1. {alethea}/specifications/README.md — the canonical SPECIFICATIONS index. "
        "Every SPEC-NNN entry is a contract the system has committed to fulfilling. "
        "You maintain this document as part of your job.\n"
        f"2. {alethea}/skills/design-specification.md — the procedure for "
        "maintaining the SPECIFICATIONS document. Includes the intake-from-chat "
        "pattern (how to detect feature descriptions and propose SPEC entries "
        "without the maintainer saying 'this is a wish').\n"
        f"3. {alethea}/session_types/workflow_management.md — your own session-type "
        "discipline. Per-turn workflow-fit check is mandatory. End-of-session "
        "learning audit is mandatory.\n"
        f"4. {alethea}/CLAUDE.md — the Alethea auto-load chain. Item 9 surfaces "
        "the specifications index; items 3-4 surface mistakes + discipline. "
        "Follow the auto-load discipline as if you'd booted via this chain.\n"
        f"5. {alethea}/mistakes/global.md — the mistakes record. Mistake #001 "
        "(communication body shape) and mistake #005 (cockpit framing) are "
        "load-bearing for your work; you compose responses past their checks.\n"
        f"6. {apeiron}/tools/workflow/README.md — the workflow shell you sit "
        "inside. Knowing the shell's slash commands lets you instruct the "
        "maintainer on how to drive other sessions when needed.\n\n"
        "## Your behavior\n"
        "**On every maintainer message:**\n"
        "1. Classify the intent. Five primary kinds:\n"
        "   - *feature description* — apply the design-specification skill's intake "
        "procedure. Draft a SPEC-NNN entry inline; confirm with the maintainer; "
        "on confirmation, edit specifications/README.md to add the entry.\n"
        "   - *action request* — execute directly if bounded and in your scope, "
        "or dispatch a worker session via `/spawn` (via the shell, you may "
        "instruct the maintainer to run the command, or you may write the work "
        "yourself if it's a file edit / a small piece of code).\n"
        "   - *regression flag* — find the SPEC entry whose acceptance criteria "
        "no longer hold, move it from `satisfied` back to `pending` or "
        "`in-progress` with a note describing the regression.\n"
        "   - *completion query* — read the relevant SPEC entries, run the "
        "acceptance criteria mentally or actually, report the status.\n"
        "   - *conversational* — respond conversationally without spec action.\n"
        "2. Respond at the system-level shift (see Alethea mistake #001). The "
        "maintainer sees your Communication block; technical detail lives in "
        "extended thinking or in the handoff document for your work.\n"
        "3. Update the SPECIFICATIONS document whenever a spec's status moves.\n\n"
        "**Cross-session coordination.** You are one of potentially many sessions "
        "running on the maintainer's machine. Use the file-based inbox at "
        f"{alethea}/Alethea-cc/nodes/ (or the local fallback at "
        f"{apeiron}/state/workflow/inbox/) to send messages to other sessions. "
        "When a wish-granting session is needed for a SPEC entry, dispatch it "
        "via inbox + /spawn instruction, name the SPEC ID in the seed message, "
        "and report progress back to the maintainer.\n\n"
        "**Soft WIP limit (per design-specification skill).** No more than 3 specs "
        "in `in-progress` at once across the portfolio. If a new feature would "
        "exceed the limit, tell the maintainer the queue is at capacity and "
        "offer to bump priorities or wait.\n\n"
        "**Begin** by reading the six documents listed above, then reply with "
        "exactly: `Ready. Default chat recipient is online. Describe a feature "
        "or send a request; I will record / route / respond as appropriate.`"
    )


if __name__ == "__main__":
    raise SystemExit(main())
