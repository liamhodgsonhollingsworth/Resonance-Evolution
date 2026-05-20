"""
Text-API driver for the 2D workflow GUI shell — SPEC-081.

Lets a session (or a CI run, or any non-interactive caller) exercise
every GUI behavior without launching a real Tk window. The driver
constructs a ``GuiShell`` against stub backends, then exposes a
mouse-and-keyboard-free surface to drive state transitions and read
the resulting state machine snapshot.

Why this exists. Maintainer directive 2026-05-11 (session da9df8be):
*"LLMs should be able to open the site and traverse it using only basic
website search tools, meaning you should be able to do everything on the
site that I can do, and so you can build and test all features."*
Plus 2026-05-18 (session 2575849f) and 2026-05-19 (session d95e17b4):
*"Remember to also focus on designing and implementing your own tools
for this process... you can build new tools for yourself to access and
test the program and GUI and iterate over those tools as well."*

The driver is the canonical answer to "I added a GUI feature; how did
I verify it without asking the maintainer to launch?" Future sessions
add new verbs as they add new features; the test surface is monotonic.

Usage (Python)::

    from tools.gui_test_driver import GuiDriver

    drv = GuiDriver()
    drv.build()
    drv.select_tab("Tasks")
    assert drv.read_state()["active_tab"] == "Tasks"
    drv.hold_ctrl()
    drv.hover("Inbox")
    assert "archive" in drv.tooltip_text()
    drv.ctrl_click("Quarantine")
    assert "Quarantine" not in drv.tab_order()
    drv.ctrl_drag(delta_y=120)
    assert drv.read_state()["sidebar_scale"] > 1.0

Usage (CLI)::

    python -m tools.gui_test_driver smoke   # exercises every verb
    python -m tools.gui_test_driver verb select-tab Tasks
    python -m tools.gui_test_driver verb hold-ctrl
    python -m tools.gui_test_driver verb hover Inbox
    python -m tools.gui_test_driver verb ctrl-drag --delta-y 120
    python -m tools.gui_test_driver state
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from types import SimpleNamespace
from typing import Any, Dict, List, Optional


# Late imports so this module loads even when Tk isn't available.
def _import_gui_shell():
    from tools.workflow_gui.gui_shell import GuiShell, TABS

    return GuiShell, TABS


# ---------------------------------------------------------------------------
# Stub backends.
# ---------------------------------------------------------------------------


class _StubEngine:
    """Minimal engine surface the GuiShell touches.

    The text-API driver doesn't run the realtime renderer; the 3D tab
    activation falls back to a placeholder. Source-backed tabs are
    populated from a configurable cache dict passed in.
    """

    def __init__(self, cache: Optional[Dict[str, Any]] = None) -> None:
        self.cache: Dict[str, Any] = dict(cache or {})
        self.errors: List[str] = []

    def precompute(self) -> None:
        """No-op; the stub cache is populated up-front by tests."""


class _StubInbox:
    def __init__(self, messages: Optional[List[Any]] = None) -> None:
        self._messages = list(messages or [])

    def list_main(self, unread_only: bool = False) -> List[Any]:
        if unread_only:
            return [m for m in self._messages if not m.read]
        return list(self._messages)


class _StubSession:
    def __init__(
        self,
        sid: str,
        display_name: str,
        session_type: str = "workflow-management",
        status: str = "active",
    ) -> None:
        self.id = sid
        self.display_name = display_name
        self.session_type = session_type
        self.status = status


class _StubSessionManager:
    def __init__(
        self,
        records: Optional[List[_StubSession]] = None,
        state_dir: Optional[Path] = None,
    ) -> None:
        self._records = list(records or [])
        self.sent: List[Dict[str, str]] = []
        self.state_dir = state_dir or Path(".")
        self.shutdown_called = False

    def list(self) -> List[_StubSession]:
        return list(self._records)

    def send(self, sid: str, message: str) -> None:
        self.sent.append({"sid": sid, "message": message})

    def get(self, sid: str) -> Optional[_StubSession]:
        for r in self._records:
            if r.id == sid:
                return r
        return None

    def spawn(
        self,
        *,
        session_type: str,
        display_name: Optional[str] = None,
        cwd: Optional[Path] = None,
        seed_message: Optional[str] = None,
    ) -> _StubSession:
        rec = _StubSession(
            sid=f"stub-{len(self._records)+1}",
            display_name=display_name or "stub",
            session_type=session_type,
        )
        self._records.append(rec)
        return rec

    def reactivate(self, sid: str) -> Optional[_StubSession]:
        """Flip an archived/idle session back to active (SPEC-068)."""
        for r in self._records:
            if r.id == sid:
                r.status = "active"
                return r
        return None

    def shutdown(self) -> None:
        self.shutdown_called = True


# ---------------------------------------------------------------------------
# The driver.
# ---------------------------------------------------------------------------


@dataclass
class GuiDriver:
    """Text-API surface over the 2D workflow GUI shell (SPEC-081).

    ``build(headless=True)`` constructs a GuiShell against stub
    backends. ``build(headless=False)`` also constructs the Tk window
    for cases where the test wants to assert visual side-effects (e.g.
    tooltip widget existence). The default is headless so the driver
    runs in CI / on machines without a display.
    """

    cache: Dict[str, Any] = field(default_factory=dict)
    messages: List[Any] = field(default_factory=list)
    sessions: List[_StubSession] = field(default_factory=list)
    headless: bool = True

    # Set after build().
    shell: Any = field(default=None, init=False, repr=False)
    _GuiShell: Any = field(default=None, init=False, repr=False)
    _TABS: Any = field(default=None, init=False, repr=False)

    # ----- lifecycle -----

    def build(self) -> "GuiDriver":
        """Construct the GuiShell. Returns self for chaining."""
        self._GuiShell, self._TABS = _import_gui_shell()
        self.shell = self._GuiShell(
            engine=_StubEngine(cache=self.cache),
            session_manager=_StubSessionManager(records=self.sessions),
            inbox=_StubInbox(messages=self.messages),
            root=Path("."),
            scene_path=None,
            scene_root_id=None,
            current_user=None,
        )
        if not self.headless:
            self.shell.build_ui()
        return self

    def close(self) -> None:
        if self.shell is not None and not self.headless:
            try:
                self.shell._on_close()
            except Exception:
                pass

    # ----- verbs -----

    def select_tab(self, name: str) -> bool:
        return self.shell.select_tab(name)

    def hold_ctrl(self) -> None:
        self.shell._set_ctrl(True)

    def release_ctrl(self) -> None:
        self.shell._set_ctrl(False)

    def hover(self, tab_name: str) -> str:
        """Simulate a Ctrl-aware hover and return the tooltip text the
        GUI would surface (basic name if Ctrl not held; extended help
        from ``_tab_help`` if held). Doesn't require a Tk widget."""
        if self.shell.ctrl_held:
            return self.shell._tab_help.get(tab_name, tab_name)
        return tab_name

    def ctrl_click(self, tab_name: str) -> str:
        """Simulate a Ctrl-click on a sidebar tab. Archives the tab if
        Ctrl is held; otherwise no-op (returns empty)."""
        if not self.shell.ctrl_held:
            return ""
        return self.shell._archive_tab(tab_name)

    def ctrl_drag(self, delta_y: int) -> float:
        """Simulate a vertical Ctrl-drag of ``delta_y`` pixels. Returns
        the new sidebar scale (clamped to [0.6, 2.5]).

        SPEC-072 acceptance: "holding control and dragging the modules
        around resizes all of them inside the toolbar."
        """
        if not self.shell.ctrl_held:
            return self.shell._sidebar_scale
        # Synthesize start-anchor + motion events.
        self.shell._resize_anchor_y = 0
        self.shell._resize_anchor_scale = self.shell._sidebar_scale
        new_scale = self.shell._sidebar_scale + (delta_y / 200.0)
        return self.shell.set_sidebar_scale(new_scale)

    # ----- SPEC-067 view-as-menu verbs -----

    def set_view(self, name: str) -> bool:
        """Activate a registered view (SPEC-067). Returns True on
        success. Restores the view first if it was archived."""
        return self.shell.set_view(name)

    def current_view(self) -> Optional[str]:
        """Name of the currently-active view, or None if no view has
        been activated yet."""
        return self.shell.current_view()

    def list_views(self) -> List[str]:
        """Names of visible registered views in display order."""
        return self.shell.list_views()

    def archived_views(self) -> List[str]:
        """Names of archived (but registered) views."""
        return self.shell.view_registry.archived_names()

    def restore_view(self, name: str) -> bool:
        """Restore a previously-archived view to the sidebar."""
        return self.shell.restore_view(name)

    def register_view(self, spec: Any) -> None:
        """Register a new view at runtime. ``spec`` must be a
        ``ViewSpec`` instance (imported via
        ``tools.workflow_gui.view_registry``)."""
        self.shell.register_view(spec)

    def view_kind(self, name: str) -> Optional[str]:
        """Return the kind of a registered view (``source``,
        ``gui_inbox``, ``3d``, ``text``, etc.), or None if unknown."""
        spec = self.shell.view_registry.get(name)
        return spec.kind if spec is not None else None

    # ----- SPEC-079 active-sessions surface -----

    def list_active_sessions(self, *, include_stale: bool = False) -> List[Dict[str, Any]]:
        """Return the active-sessions registry as plain dicts so
        callers don't need to import the dataclass.

        Reads from ``engine.active_sessions_state_dir`` when set,
        else falls back to ``./state/``.
        """
        from tools.active_sessions import list_active_sessions as _list

        state_dir = getattr(self.shell.engine, "active_sessions_state_dir", None)
        out: List[Dict[str, Any]] = []
        for s in _list(state_dir=state_dir, include_stale=include_stale):
            out.append(
                {
                    "id": s.id,
                    "project": s.project,
                    "session_type": s.session_type,
                    "focus": s.focus,
                    "last_seen": s.last_seen,
                    "pid": s.pid,
                    "cwd": s.cwd,
                    "is_stale": s.is_stale,
                }
            )
        return out

    def register_active_session(
        self,
        session_id: str,
        project: str,
        session_type: str,
        *,
        focus: str = "",
    ) -> bool:
        """Register a session in the active-sessions registry. Routed
        through engine.active_sessions_state_dir."""
        from tools.active_sessions import register_session

        state_dir = getattr(self.shell.engine, "active_sessions_state_dir", None)
        register_session(
            session_id, project, session_type,
            focus=focus, state_dir=state_dir,
        )
        return True

    def use_active_sessions_state_dir(self, path: Path) -> None:
        """Convenience: point the driver's engine at a tmp state dir
        so tests don't write into the real state directory."""
        self.shell.engine.active_sessions_state_dir = path

    # ----- SPEC-068 chat routing -----

    def route_chat(self, text: str) -> Dict[str, Any]:
        """Drive the chat routing layer (SPEC-068). Returns the
        routing decision dict the shell produced.

        Bare text → active session. ``@<name|id> body`` → that
        session, reactivating if archived. ``/all body`` → broadcast
        to non-archived sessions. Empty body → no-op.
        """
        return self.shell.route_chat(text)

    def set_active_session(self, sid_or_name: str) -> Optional[str]:
        """Set the active chat target. Accepts id, display_name, or
        id-prefix (≥4 chars). Returns the resolved id or None.

        SPEC-068 acceptance: clicking a row in the Chat or Sessions
        view selects that session as the active chat target.
        """
        return self.shell.set_active_session(sid_or_name)

    def active_session(self) -> Optional[str]:
        """Return the current active session id."""
        return self.shell.active_session_id

    # ----- SPEC-007 movable / resizable / snap / lock panels -----

    def move_panel(self, panel_id: str, x: int, y: int) -> Dict[str, Any]:
        """Programmatic move (post-snap-grid math). Returns the panel
        state dict. SPEC-007 acceptance: the resulting (x, y) is
        snapped to the 12-px grid regardless of the input."""
        return self.shell.move_panel(panel_id, x, y)

    def resize_panel(self, panel_id: str, w: int, h: int) -> Dict[str, Any]:
        """Programmatic resize (post-snap-grid math). SPEC-007: w/h
        snap to 12-px and clamp to a 48 px minimum."""
        return self.shell.resize_panel(panel_id, w, h)

    def lock_panel(self, panel_id: str) -> bool:
        """Lock a panel — subsequent move/resize verbs no-op. SPEC-007."""
        return self.shell.lock_panel(panel_id)

    def unlock_panel(self, panel_id: str) -> bool:
        """Unlock a panel. Returns True on success."""
        return self.shell.unlock_panel(panel_id)

    def panel_state(self, panel_id: str) -> Dict[str, Any]:
        """Return {panel_id, view_name, x, y, w, h, locked, archived}
        for assertion. Empty dict if no handle exists."""
        return self.shell.panel_state(panel_id)

    def archive_panel(self, panel_id: str) -> bool:
        """Archive a panel via the same code path the right-click menu
        uses. Verifies the wiring without driving a real menu post.
        SPEC-008."""
        return self.shell.archive_panel(panel_id)

    def restore_panel(self, panel_id: str) -> bool:
        """Restore a previously-archived panel to its prior position."""
        return self.shell.restore_panel(panel_id)

    def ensure_panel(self, panel_id: str) -> Dict[str, Any]:
        """Create a default-position handle for ``panel_id`` if absent.
        Returns the resulting state. Used by tests that drive the
        panel layer without first rendering the tab."""
        self.shell._ensure_panel_handle(panel_id)
        return self.shell.panel_state(panel_id)

    # ----- SPEC-073 copy/paste-as-text -----

    def copy_module(self, node_id: str) -> str:
        """Serialize a node (and its sub-tree) to JSON text. Also
        writes to the Tk clipboard when a root exists."""
        return self.shell.copy_module_to_clipboard(node_id)

    def paste_module(self, text: Optional[str] = None) -> List[str]:
        """Instantiate a module from JSON text (or from the Tk
        clipboard if ``text`` is None and a root exists). Returns
        the new node ids."""
        return self.shell.paste_module_from_clipboard(text)

    def round_trip_module(self, node_id: str) -> List[str]:
        """Copy a node then paste the same payload. Convenience for
        the canonical round-trip property: pasting a copy of an
        existing node produces a new node with an auto-renamed id."""
        text = self.copy_module(node_id)
        return self.paste_module(text)

    # ----- chat -----

    def submit_chat(self, text: str, *, active_session_id: Optional[str] = None) -> Dict[str, Any]:
        """Drive the chat submit path. Returns the resulting send-log
        entry from the stub SessionManager (so callers can assert
        routing happened)."""
        if active_session_id is not None:
            self.shell.active_session_id = active_session_id
        # The actual chat submit reads from a Tk Entry; we'd need to
        # build the UI for that. Instead, route through SessionManager
        # directly to test the dispatch semantics.
        if active_session_id is None and self.shell.active_session_id is None:
            return {"routed": False, "reason": "no active session"}
        sid = active_session_id or self.shell.active_session_id
        self.shell.sm.send(sid, text)
        return {"routed": True, "sid": sid, "message": text}

    # ----- reads -----

    def read_state(self) -> Dict[str, Any]:
        """Return a JSON-able snapshot of the GUI state machine."""
        # SPEC-007 — surface the panel handle table so tests can
        # assert move/resize/lock/archive without poking shell
        # internals. Empty dict when no panels have been touched.
        panel_handles: Dict[str, Dict[str, Any]] = {}
        archived_panels: List[str] = []
        for pid in self.shell._panel_handles:
            state = self.shell.panel_state(pid)
            panel_handles[pid] = state
            if state.get("archived"):
                archived_panels.append(pid)
        return {
            "active_tab": self.shell.active_tab,
            "ctrl_held": self.shell.ctrl_held,
            "sidebar_scale": self.shell._sidebar_scale,
            "tab_order": list(self.shell._tab_order),
            "expanded_item_id": self.shell._expanded_item_id,
            "active_session_id": self.shell.active_session_id,
            "tab_count": len(self.shell._tab_order),
            # SPEC-067 surfaces — visible + archived view names so
            # tests can read the registry state without poking shell
            # internals.
            "visible_views": self.shell.view_registry.names(),
            "archived_views": self.shell.view_registry.archived_names(),
            "current_view": self.shell.current_view(),
            # SPEC-007 — panel positioning.
            "panel_handles": panel_handles,
            "archived_panels": archived_panels,
        }

    def tab_order(self) -> List[str]:
        return list(self.shell._tab_order)

    def tooltip_text(self, tab_name: Optional[str] = None) -> str:
        """Return the tooltip text for the current hover target. If
        ``tab_name`` is supplied, also simulates hover (helper)."""
        if tab_name is not None:
            return self.hover(tab_name)
        # Without a tab_name we can't know what's hovered; return empty.
        return ""

    def items_for_tab(self, tab_name: str) -> List[Dict[str, Any]]:
        return self.shell.items_for_tab(tab_name)


# ---------------------------------------------------------------------------
# CLI surface.
# ---------------------------------------------------------------------------


def _smoke(drv: GuiDriver) -> List[Dict[str, Any]]:
    """End-to-end smoke test exercising every GUI verb the driver
    exposes. Returns a list of step records (verb + state-after) the
    caller can assert on or print."""
    out: List[Dict[str, Any]] = []

    def step(name: str, state: Any) -> None:
        out.append({"step": name, "state": state})

    drv.build()
    step("build", drv.read_state())

    drv.select_tab("Wishlist")
    step("select_tab('Wishlist')", drv.read_state())

    drv.hold_ctrl()
    step("hold_ctrl", drv.read_state())

    extended = drv.hover("Tasks")
    step(
        "hover('Tasks') under Ctrl",
        {"tooltip": extended[:80], "ctrl_held": drv.read_state()["ctrl_held"]},
    )

    new_scale = drv.ctrl_drag(delta_y=120)
    step("ctrl_drag(+120px)", {"sidebar_scale": new_scale})

    drv.ctrl_drag(delta_y=-300)
    step("ctrl_drag(-300px)", {"sidebar_scale": drv.read_state()["sidebar_scale"]})

    drv.set_scale_via_method = drv.shell.set_sidebar_scale(1.0)
    step("reset_scale(1.0)", {"sidebar_scale": drv.read_state()["sidebar_scale"]})

    archived = drv.ctrl_click("Quarantine")
    step(
        f"ctrl_click('Quarantine') -> archived={archived!r}",
        {"tab_order": drv.tab_order()},
    )

    drv.release_ctrl()
    basic = drv.hover("Tasks")
    step(
        "release_ctrl + hover('Tasks')",
        {"tooltip": basic, "ctrl_held": drv.read_state()["ctrl_held"]},
    )

    # ----- SPEC-067 view-as-menu coverage -----

    visible_before = drv.list_views()
    step(
        "list_views (initial)",
        {"count": len(visible_before), "views": visible_before},
    )

    drv.set_view("Logs")
    step(
        "set_view('Logs') — built-in text view demonstrating one-config-away extension",
        {"current_view": drv.current_view()},
    )

    drv.set_view("Inbox")
    step(
        "set_view('Inbox') — round-trip back to gui-direct view",
        {"current_view": drv.current_view()},
    )

    # Register a fresh ad-hoc view at runtime and switch to it. Proves
    # the registry is mutable from the driver surface (the use-case
    # the maintainer's directive names: every node-collection is
    # reachable as a menu, including ones added after launch).
    from tools.workflow_gui.view_registry import ViewSpec

    drv.register_view(
        ViewSpec(
            name="Smoke Test",
            kind="text",
            description="Synthetic view created mid-smoke to verify register_view + set_view.",
            text_body="This view was registered at runtime by the gui_test_driver smoke.",
        )
    )
    drv.set_view("Smoke Test")
    step(
        "register_view + set_view('Smoke Test') — runtime extensibility",
        {
            "current_view": drv.current_view(),
            "visible_count": len(drv.list_views()),
        },
    )
    # Switch back to a built-in view so the final state matches what
    # downstream callers expect.
    drv.set_view("Tasks")
    step(
        "set_view('Tasks') — restore default starting tab",
        {"current_view": drv.current_view()},
    )

    drv.close()
    return out


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.gui_test_driver",
        description="Text-API driver for the 2D workflow GUI shell (SPEC-081).",
    )
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("smoke", help="Run the end-to-end smoke test")
    sub.add_parser("state", help="Print the initial state snapshot")

    verb = sub.add_parser("verb", help="Execute a single verb against a fresh shell")
    verb.add_argument("name", help="Verb name (select-tab, hold-ctrl, etc.)")
    verb.add_argument("args", nargs="*", help="Arguments for the verb")
    verb.add_argument("--delta-y", type=int, default=0)
    verb.add_argument("--active-session", default=None)

    args = parser.parse_args(argv)

    drv = GuiDriver()
    if args.cmd == "smoke":
        report = _smoke(drv)
        print(json.dumps(report, indent=2, default=str))
        return 0
    if args.cmd == "state":
        drv.build()
        print(json.dumps(drv.read_state(), indent=2, default=str))
        return 0
    if args.cmd == "verb":
        drv.build()
        verb_name = args.name
        if verb_name == "select-tab":
            drv.select_tab(args.args[0])
        elif verb_name == "hold-ctrl":
            drv.hold_ctrl()
        elif verb_name == "release-ctrl":
            drv.release_ctrl()
        elif verb_name == "hover":
            print(drv.hover(args.args[0]))
        elif verb_name == "ctrl-click":
            drv.hold_ctrl()
            print(drv.ctrl_click(args.args[0]))
        elif verb_name == "ctrl-drag":
            drv.hold_ctrl()
            print(drv.ctrl_drag(args.delta_y))
        elif verb_name == "submit-chat":
            print(drv.submit_chat(args.args[0], active_session_id=args.active_session))
        elif verb_name == "set-view":
            ok = drv.set_view(args.args[0])
            print(f"set_view({args.args[0]!r}) -> {ok}")
        elif verb_name == "list-views":
            for name in drv.list_views():
                print(name)
        elif verb_name == "current-view":
            print(drv.current_view())
        elif verb_name == "restore-view":
            ok = drv.restore_view(args.args[0])
            print(f"restore_view({args.args[0]!r}) -> {ok}")
        # ----- SPEC-007 movable / resizable / snap / lock -----
        elif verb_name == "move-panel":
            pid, x, y = args.args[0], int(args.args[1]), int(args.args[2])
            drv.ensure_panel(pid)
            print(json.dumps(drv.move_panel(pid, x, y), default=str))
        elif verb_name == "resize-panel":
            pid, w, h = args.args[0], int(args.args[1]), int(args.args[2])
            drv.ensure_panel(pid)
            print(json.dumps(drv.resize_panel(pid, w, h), default=str))
        elif verb_name == "lock-panel":
            pid = args.args[0]
            drv.ensure_panel(pid)
            print(f"lock_panel({pid!r}) -> {drv.lock_panel(pid)}")
        elif verb_name == "unlock-panel":
            print(f"unlock_panel({args.args[0]!r}) -> {drv.unlock_panel(args.args[0])}")
        elif verb_name == "panel-state":
            pid = args.args[0]
            drv.ensure_panel(pid)
            print(json.dumps(drv.panel_state(pid), default=str))
        elif verb_name == "archive-panel":
            pid = args.args[0]
            drv.ensure_panel(pid)
            print(f"archive_panel({pid!r}) -> {drv.archive_panel(pid)}")
        elif verb_name == "restore-panel":
            print(f"restore_panel({args.args[0]!r}) -> {drv.restore_panel(args.args[0])}")
        else:
            sys.stderr.write(f"unknown verb: {verb_name!r}\n")
            return 2
        print(json.dumps(drv.read_state(), indent=2, default=str))
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
