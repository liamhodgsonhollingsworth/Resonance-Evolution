"""
2D Tk GUI workflow shell — SPEC-065.

Native productivity-app layout: a vertical sidebar of tabs on the left,
a scrollable list (or embedded 3D renderer) in the central pane, and a
chat input at the bottom. Switching to the 3D tab activates the
realtime renderer inside the central pane via the embedded ``TkBackend``
mode; switching to any 2D tab tears the 3D loop down so no compute
runs on hidden surfaces.

The GUI shell consumes the same engine + SessionManager + Inbox + trust
primitives the terminal REPL (``tools.workflow``) uses. The two surfaces
are interchangeable consumers of the same underlying data layer —
swapping renderers without re-architecting the rest is the visualizer-
as-toggle commitment that SPEC-061 named and SPEC-065 makes concrete
for the workflow surface.

Tabs come in three shapes:

- **Source-backed tabs** (Tasks, Ideas, Wishlist, Quarantine, Trusted
  Senders) read items from ``engine.cache[<source_id>]``. The same
  FileSource / QuarantineSource / TrustedSendersSource nodes feed the
  3D ListRenderer panels and these 2D Tk lists. Hot-reload via the
  file-watcher is uniform.
- **GUI-direct tabs** (Inbox, Chat) render data the GUI shell holds
  directly — main-inbox messages from ``Inbox.list_main`` and session
  records from ``SessionManager.list``. These don't go through the
  engine cache; their data lives in the workflow shell layer.
- **3D tab** activates an embedded realtime renderer painting into the
  central pane. The driver loop is pumped via Tk's ``after`` rather
  than its own ``while`` loop so the GUI shell's mainloop stays
  responsive.

Per-item action buttons dispatch through ``engine.actions.dispatch_action``
on tabs that map to a renderer node-id, keeping the action layer
unified across 2D and 3D surfaces. Expand/collapse, by contrast, is
local UI state on the 2D widget — the engine is not consulted for
view-state changes that don't mutate underlying data.

Run from the Apeiron repo root::

    python -m tools.workflow_gui

Flags mirror the terminal shell: ``--scene``, ``--state-dir``,
``--no-watch``, ``--root``, ``--no-default-session``, ``--alethea-root``,
``--skip-auth``, ``--accounts-path``.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

from engine.core import Engine
from engine.file_watcher import FileWatcher

from tools.workflow.auth import DEFAULT_ACCOUNTS_PATH
from tools.workflow.inbox import Inbox, InboxMessage
from tools.workflow.session_manager import SessionError, SessionManager
from tools.workflow.trust import (
    render_trust_set,
    sender_trust_set,
    session_trust_set,
)
from tools.workflow_gui.view_registry import (
    ViewRegistry,
    ViewSpec,
    default_view_registry,
)


# ---------------------------------------------------------------------------
# Tab catalog.
# ---------------------------------------------------------------------------


# Legacy tab tuple shape: ``(name, source_id_or_marker, panel_id_or_None)``.
# A ``None`` panel id means the tab has no engine-level actions; expand /
# action buttons fall back to local UI state only.
#
# As of SPEC-067 the canonical source of truth is the ``ViewRegistry`` at
# ``tools.workflow_gui.view_registry``. ``TABS`` is materialized from
# ``default_view_registry()`` so legacy consumers (tests, the ready-check
# probe) keep working without seeing the registry abstraction. New code
# should consult ``shell.view_registry`` directly.
TABS: List[Tuple[str, str, Optional[str]]] = default_view_registry().as_tabs()

DEFAULT_TAB = "Tasks"


# ---------------------------------------------------------------------------
# Data providers.
# ---------------------------------------------------------------------------


def items_from_engine_cache(engine: Engine, source_id: str) -> List[Dict[str, Any]]:
    """Return the items list for a source node-id from the engine cache.

    Returns an empty list if the source isn't loaded or the cache entry
    isn't in the expected shape. Public for tests.
    """
    if not source_id:
        return []
    entry = engine.cache.get(source_id, {})
    if not isinstance(entry, dict):
        return []
    items = entry.get("items")
    if not isinstance(items, list):
        return []
    return list(items)


def items_from_inbox(inbox: Inbox) -> List[Dict[str, Any]]:
    """Return main-inbox messages as item dicts. Public for tests."""
    out: List[Dict[str, Any]] = []
    for msg in inbox.list_main(unread_only=False):
        read_mark = "" if msg.read else " *"
        ts = time.strftime("%H:%M:%S", time.localtime(msg.ts))
        out.append(
            {
                "id": str(msg.path.name),
                "title": f"{ts}  from={msg.sender}  {msg.summary}{read_mark}",
                "body": (msg.body or "").strip(),
                "status": "ok" if msg.read else "pending",
                "meta": {
                    "sender": msg.sender,
                    "to": msg.to,
                    "kind": msg.kind,
                    "path": str(msg.path),
                },
                "actions": ["expand"],
            }
        )
    return out


def items_from_sessions(
    sm: SessionManager, active_id: Optional[str]
) -> List[Dict[str, Any]]:
    """Return session records as item dicts. Public for tests."""
    out: List[Dict[str, Any]] = []
    for rec in sm.list():
        active_mark = " (active)" if rec.id == active_id else ""
        out.append(
            {
                "id": rec.id,
                "title": f"{rec.display_name} [{rec.session_type}]{active_mark}",
                "body": f"id={rec.id}\nstatus={rec.status}\ntype={rec.session_type}",
                "status": _session_status_to_panel_status(rec.status),
                "meta": {"display_name": rec.display_name, "status": rec.status},
                "actions": ["expand", "target"],
            }
        )
    return out


def _session_status_to_panel_status(status: str) -> str:
    """Map SessionManager status strings to ListRenderer status keys."""
    return {
        "idle": "ok",
        "active": "in_progress",
        "archived": "cancelled",
        "error": "alert",
    }.get(status, "pending")


def items_from_text_view(spec: Any, engine: Engine) -> List[Dict[str, Any]]:
    """Build the items list for a SPEC-067 ``text`` view.

    For the built-in ``Logs`` view, returns one row per engine error;
    for any other text view, returns a single synthetic row containing
    the spec's ``text_body``. Public for tests.
    """
    if getattr(spec, "name", "") == "Logs":
        # Special: stream engine errors as one row each.
        out: List[Dict[str, Any]] = []
        for idx, err in enumerate(list(engine.errors)[-200:]):
            first = err.splitlines()[0] if err else ""
            out.append(
                {
                    "id": f"log-{idx}",
                    "title": first[:120] if first else "(empty)",
                    "body": err,
                    "status": "alert",
                    "actions": ["expand"],
                }
            )
        if not out:
            out.append(
                {
                    "id": "log-empty",
                    "title": "(no errors recorded — engine is healthy)",
                    "body": (
                        "Logs view reads from engine.errors. This view "
                        "is the SPEC-067 demonstration that adding a new "
                        "view is one ViewSpec config row."
                    ),
                    "status": "ok",
                    "actions": ["expand"],
                }
            )
        return out
    # Generic text view: one item carrying the configured body.
    body = getattr(spec, "text_body", "") or ""
    return [
        {
            "id": f"text-{getattr(spec, 'name', 'view')}",
            "title": getattr(spec, "name", "view"),
            "body": body or "(empty)",
            "status": "ok",
            "actions": ["expand"],
        }
    ]


# ---------------------------------------------------------------------------
# The shell.
# ---------------------------------------------------------------------------


class GuiShell:
    """The 2D Tk workflow shell.

    Composes engine + SessionManager + Inbox + trust primitives with a
    native Tk window. Construction is split from ``build_ui`` so tests
    can instantiate the shell without a display and exercise the data
    providers + tab state machine in isolation.
    """

    def __init__(
        self,
        *,
        engine: Engine,
        session_manager: SessionManager,
        inbox: Inbox,
        root: Path,
        scene_path: Optional[Path],
        scene_root_id: Optional[str],
        current_user: Optional[str] = None,
        view_registry: Optional[ViewRegistry] = None,
    ) -> None:
        self.engine = engine
        self.sm = session_manager
        self.inbox = inbox
        self.root = Path(root)
        self.scene_path = Path(scene_path) if scene_path else None
        self.scene_root_id = scene_root_id
        self.current_user = current_user

        # SPEC-067: the registry is the canonical source of truth for
        # which views the sidebar shows. Constructing a custom registry
        # at the call site lets plugins / tests add views without
        # touching shell code. Default is ``default_view_registry()``.
        self.view_registry: ViewRegistry = (
            view_registry if view_registry is not None else default_view_registry()
        )
        # Engine-side handle so the text-API ``set-view`` command + any
        # non-GUI caller can consult the registry without importing
        # GUI modules. Idempotent: re-attaching the same registry is a
        # no-op.
        setattr(self.engine, "view_registry", self.view_registry)
        setattr(self.engine, "gui_shell", self)

        # GUI state — set when ``build_ui`` is called.
        self.tk_root: Any = None
        self._central_frame: Any = None
        self._sidebar_frame: Any = None
        self._chat_entry: Any = None
        self._sidebar_buttons: Dict[str, Any] = {}
        # ``_tabs`` is the legacy materialized form ``items_for_tab``
        # iterates over. Re-materialized whenever the registry changes
        # so the rendering switch keeps working without dictionary
        # lookups on every render.
        self._tabs: List[Tuple[str, str, Optional[str]]] = self.view_registry.as_tabs()

        # Tab state machine.
        self.active_tab: Optional[str] = None
        self._expanded_item_id: Optional[str] = None

        # 3D tab state.
        self._driver: Any = None
        self._backend: Any = None
        self._frame_pump_active: bool = False
        self._frame_pump_after_id: Any = None
        self._frame_budget_ms: int = 33  # ~30 FPS

        # Chat routing.
        self.active_session_id: Optional[str] = None

        # File watcher (set externally; the shell holds a reference for
        # shutdown).
        self.file_watcher: Optional[FileWatcher] = None

        # Hold-Ctrl edit-mode state (SPEC-072). When True, hovering a tab
        # shows extended help instead of basic name; Ctrl-clicking a tab
        # archives it (SPEC-008); Ctrl-dragging RESIZES all modules in
        # the toolbar (SPEC-072 verbatim: "holding control and dragging
        # the modules around resizes all of them inside the toolbar").
        self.ctrl_held: bool = False
        self._tooltip_window: Any = None
        self._tooltip_after_id: Any = None
        # ``_tab_help`` materializes the registry's per-view description
        # field for fast lookup during Ctrl-hover. SPEC-074
        # standard-icons-by-default + hover-name + Ctrl-hover-help.
        self._tab_help: Dict[str, str] = self.view_registry.help_map()
        # ``_tab_order`` mirrors the registry's display order. Updated
        # whenever a view is archived / restored so the existing sidebar
        # rendering paths keep treating it as the truth.
        self._tab_order: List[str] = self.view_registry.names()
        # Sidebar resize state (SPEC-072 Ctrl-drag = resize toolbar
        # modules). _base_font_size and _base_pady are the at-rest
        # values; _sidebar_scale is the live multiplier mutated on
        # Ctrl-drag. Scale clamps to [0.6, 2.5] so the toolbar never
        # vanishes or eats the central pane.
        self._base_font_size: int = 11
        self._base_pady: int = 8
        self._sidebar_scale: float = 1.0
        self._resize_anchor_y: Optional[int] = None
        self._resize_anchor_scale: float = 1.0

    # ----- data providers (testable without UI) -----

    def items_for_tab(self, tab_name: str) -> List[Dict[str, Any]]:
        """Return the items list for the named tab. Public for tests.

        For the SPEC-067 ``text`` kind, returns a synthetic single-row
        item carrying the rendered text body so the standard list-panel
        renderer surfaces it without a special case in the central
        pane. The ``Logs`` view in the default registry uses this to
        render ``engine.errors`` as a read-only diagnostics tab.
        """
        # Source-of-truth lookup: prefer the registry spec; fall back
        # to the legacy _tabs marker for tabs that haven't migrated.
        spec = self.view_registry.get(tab_name)
        if spec is not None:
            if spec.kind == "source":
                return items_from_engine_cache(self.engine, spec.source_id or "")
            if spec.kind == "gui_inbox":
                return items_from_inbox(self.inbox)
            if spec.kind == "gui_chat":
                return items_from_sessions(self.sm, self.active_session_id)
            if spec.kind == "3d":
                return []
            if spec.kind == "text":
                return items_from_text_view(spec, self.engine)
            if spec.kind == "dynamic":
                # SPEC-067 + caller-supplied items provider. The
                # provider is responsible for returning a list of
                # item dicts; exceptions surface as a one-row alert
                # so the GUI never crashes on a bad provider.
                provider = getattr(spec, "items_provider", None)
                if provider is None:
                    return []
                try:
                    return list(provider(self.engine))
                except Exception as exc:
                    self.engine.errors.append(
                        f"gui_shell dynamic view {spec.name!r}: {exc}"
                    )
                    return [
                        {
                            "id": f"dynamic-error-{spec.name}",
                            "title": f"(provider raised: {exc})",
                            "body": str(exc),
                            "status": "alert",
                            "actions": ["expand"],
                        }
                    ]
            if spec.kind == "custom":
                return []
        # Legacy fallback (for tabs registered through the old TABS
        # mechanism that aren't in the registry).
        for name, source_id, _ in self._tabs:
            if name != tab_name:
                continue
            if source_id == "_inbox":
                return items_from_inbox(self.inbox)
            if source_id == "_chat":
                return items_from_sessions(self.sm, self.active_session_id)
            if source_id == "_3d":
                return []
            if source_id.startswith("_text:") or source_id.startswith("_custom:"):
                return []
            return items_from_engine_cache(self.engine, source_id)
        return []

    def panel_id_for_tab(self, tab_name: str) -> Optional[str]:
        """Return the panel renderer node-id for a tab, if any."""
        for name, _, panel_id in self._tabs:
            if name == tab_name:
                return panel_id
        return None

    # ----- tab state machine (testable without UI) -----

    def can_switch_to(self, tab_name: str) -> bool:
        """A tab switch is always allowed; the shell tears down 3D
        compute before activating the new tab. Public for tests of the
        guard logic; production calls go through ``select_tab``.
        """
        return any(name == tab_name for name, _, _ in self._tabs)

    def select_tab(self, tab_name: str) -> bool:
        """Switch to the named tab. Returns True on success.

        Tears down the 3D driver loop if it was active and the new tab
        is not the 3D tab. No-ops if the tab name is unknown.
        """
        if not self.can_switch_to(tab_name):
            return False
        if self._driver is not None and tab_name != "3D":
            self._teardown_3d()
        self.active_tab = tab_name
        self._expanded_item_id = None
        if self.tk_root is not None:
            self._render_active_tab()
        return True

    # ----- UI construction -----

    def build_ui(self) -> None:
        """Construct the Tk window. Idempotent: a second call replaces
        the prior root window with a fresh one (useful for tests).
        """
        import tkinter as tk
        from tkinter import ttk

        if self.tk_root is not None:
            try:
                self.tk_root.destroy()
            except Exception:
                pass

        self.tk_root = tk.Tk()
        self.tk_root.title("Apeiron — Workflow")
        self.tk_root.geometry("1100x700")

        # Three regions: sidebar (left), central (top-right), chat (bottom).
        # We use a grid layout on the toplevel; sidebar spans both rows.
        self.tk_root.grid_columnconfigure(0, weight=0, minsize=200)
        self.tk_root.grid_columnconfigure(1, weight=1)
        self.tk_root.grid_rowconfigure(0, weight=1)
        self.tk_root.grid_rowconfigure(1, weight=0)

        # Sidebar.
        self._sidebar_frame = tk.Frame(self.tk_root, bg="#1c1f26")
        self._sidebar_frame.grid(row=0, column=0, rowspan=2, sticky="nsew")
        self._build_sidebar()

        # Central pane.
        self._central_frame = tk.Frame(self.tk_root, bg="#2a2d34")
        self._central_frame.grid(row=0, column=1, sticky="nsew")

        # Chat input bar at the bottom of the right column.
        chat_bar = tk.Frame(self.tk_root, bg="#15171c", height=64)
        chat_bar.grid(row=1, column=1, sticky="ew")
        chat_bar.grid_propagate(False)
        chat_bar.grid_columnconfigure(0, weight=1)

        self._chat_entry = tk.Entry(
            chat_bar,
            bg="#2a2d34",
            fg="#e8e8ec",
            insertbackground="#e8e8ec",
            relief="flat",
            font=("Helvetica", 11),
        )
        self._chat_entry.grid(row=0, column=0, sticky="ew", padx=(12, 8), pady=14)
        self._chat_entry.bind("<Return>", lambda _e: self._on_chat_submit())

        send_btn = tk.Button(
            chat_bar,
            text="Send",
            command=self._on_chat_submit,
            bg="#3b4254",
            fg="#e8e8ec",
            relief="flat",
            font=("Helvetica", 10, "bold"),
            padx=14,
            pady=4,
        )
        send_btn.grid(row=0, column=1, padx=(0, 12), pady=14)

        # Default tab.
        self.select_tab(DEFAULT_TAB)

        # Hold-Ctrl edit-mode key bindings (SPEC-072).
        self.tk_root.bind_all("<Control-KeyPress>", self._on_ctrl_press)
        self.tk_root.bind_all("<KeyRelease-Control_L>", self._on_ctrl_release)
        self.tk_root.bind_all("<KeyRelease-Control_R>", self._on_ctrl_release)
        # When the window loses focus, drop ctrl state so a Ctrl-down
        # outside the window doesn't leave the GUI stuck in edit mode.
        self.tk_root.bind("<FocusOut>", lambda _e: self._set_ctrl(False))

        # Graceful shutdown protocol.
        self.tk_root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_sidebar(self) -> None:
        import tkinter as tk

        # Title header.
        header = tk.Label(
            self._sidebar_frame,
            text="Apeiron",
            bg="#1c1f26",
            fg="#e8e8ec",
            font=("Helvetica", 14, "bold"),
            pady=12,
        )
        header.pack(fill="x")

        if self.current_user:
            user_label = tk.Label(
                self._sidebar_frame,
                text=f"signed in: {self.current_user}",
                bg="#1c1f26",
                fg="#8d92a3",
                font=("Helvetica", 9),
                pady=2,
            )
            user_label.pack(fill="x")

        # Separator.
        sep = tk.Frame(self._sidebar_frame, bg="#2a2d34", height=1)
        sep.pack(fill="x", pady=(8, 4))

        # Tab buttons.
        for name, _, _ in self._tabs:
            btn = tk.Button(
                self._sidebar_frame,
                text=name,
                anchor="w",
                bg="#1c1f26",
                fg="#c8ccd6",
                activebackground="#2a2d34",
                activeforeground="#ffffff",
                relief="flat",
                font=("Helvetica", 11),
                padx=18,
                pady=8,
                command=lambda n=name: self.select_tab(n),
            )
            btn.pack(fill="x")
            self._sidebar_buttons[name] = btn

            # SPEC-074 + SPEC-072: hover-name (always) and Ctrl-hover help
            # (extended). Tooltip lifecycle is keyed to the button widget
            # so multiple buttons don't fight over the same Toplevel.
            btn.bind("<Enter>", lambda _e, n=name, b=btn: self._on_tab_hover(n, b))
            btn.bind("<Leave>", lambda _e: self._hide_tooltip())
            # SPEC-072 + SPEC-008: Ctrl-click archives the tab (sidebar
            # tab is hidden until restored from an archived-tabs list).
            btn.bind("<Control-Button-1>", lambda _e, n=name: self._archive_tab(n))
            # SPEC-072 verbatim ("holding control and dragging the
            # modules around resizes all of them inside the toolbar"):
            # Ctrl-button-press anchors the resize; Ctrl-drag scales all
            # toolbar modules together; release commits.
            btn.bind("<Control-ButtonPress-1>", lambda e: self._on_toolbar_resize_start(e))
            btn.bind("<Control-B1-Motion>", lambda e: self._on_toolbar_resize_drag(e))

    def _highlight_active_tab(self) -> None:
        for name, btn in self._sidebar_buttons.items():
            if name == self.active_tab:
                btn.configure(bg="#3b4254", fg="#ffffff")
            else:
                btn.configure(bg="#1c1f26", fg="#c8ccd6")

    # ----- hold-Ctrl edit mode (SPEC-072, SPEC-074) -----

    def _set_ctrl(self, held: bool) -> None:
        """Update the Ctrl-held flag and refresh visual cues. Public for
        tests of the hold-Ctrl state machine."""
        if held == self.ctrl_held:
            return
        self.ctrl_held = held
        # When releasing Ctrl, hide any extended tooltip.
        if not held:
            self._hide_tooltip()

    def _on_ctrl_press(self, _event: Any) -> None:
        self._set_ctrl(True)

    def _on_ctrl_release(self, _event: Any) -> None:
        self._set_ctrl(False)

    def _on_tab_hover(self, tab_name: str, widget: Any) -> None:
        """Show a tooltip for the hovered tab. Basic mode shows just
        the tab name; Ctrl-hover shows the extended help text from
        ``_tab_help`` (SPEC-074 hover-name + Ctrl-hover-help, SPEC-072
        Ctrl is the gate for richer info).
        """
        text = tab_name
        if self.ctrl_held:
            extended = self._tab_help.get(tab_name)
            if extended:
                text = extended
        self._show_tooltip(widget, text)

    def _show_tooltip(self, anchor_widget: Any, text: str) -> None:
        import tkinter as tk

        self._hide_tooltip()
        if not text or self.tk_root is None:
            return
        try:
            x = anchor_widget.winfo_rootx() + anchor_widget.winfo_width() + 8
            y = anchor_widget.winfo_rooty() + 4
        except Exception:
            return
        tip = tk.Toplevel(self.tk_root)
        tip.wm_overrideredirect(True)
        tip.wm_geometry(f"+{x}+{y}")
        label = tk.Label(
            tip,
            text=text,
            bg="#15171c",
            fg="#e8e8ec",
            font=("Helvetica", 9),
            wraplength=320,
            justify="left",
            padx=8,
            pady=4,
            borderwidth=1,
            relief="solid",
        )
        label.pack()
        self._tooltip_window = tip

    def _hide_tooltip(self) -> None:
        if self._tooltip_window is not None:
            try:
                self._tooltip_window.destroy()
            except Exception:
                pass
            self._tooltip_window = None

    def _archive_tab(self, tab_name: str) -> str:
        """Archive a tab — hide it from the sidebar. SPEC-008 + SPEC-072.

        Delegates to ``ViewRegistry.archive`` so the registry remains
        the source of truth. The spec is preserved in the registry so
        ``restore_view(name)`` can bring it back without re-declaring.
        Returns the tab name for tests.
        """
        # Don't let the active tab vanish without a fallback selection.
        if tab_name == self.active_tab:
            fallback = next(
                (n for n in self.view_registry.names() if n != tab_name),
                DEFAULT_TAB,
            )
            self.select_tab(fallback)
        # Archive in the registry; rebuild the legacy mirrors.
        self.view_registry.archive(tab_name)
        self._tabs = self.view_registry.as_tabs()
        self._tab_order = self.view_registry.names()
        btn = self._sidebar_buttons.get(tab_name)
        if btn is not None:
            try:
                btn.pack_forget()
            except Exception:
                pass
        return tab_name

    # ----- SPEC-067 view-as-menu surface -----

    def set_view(self, name: str) -> bool:
        """Activate the named view. SPEC-067 primitive.

        Sugar over ``select_tab`` that the text-API ``set-view``
        command and the gui_test_driver call. Returns True on success.
        If the named view is archived, restores it first so the
        switch always succeeds when the view is registered (visible
        or hidden).
        """
        if not self.view_registry.get(name):
            return False
        if self.view_registry.is_archived(name):
            self.restore_view(name)
        return self.select_tab(name)

    def current_view(self) -> Optional[str]:
        """Return the active view name. SPEC-067 read primitive."""
        return self.active_tab

    def list_views(self) -> List[str]:
        """Names of visible views in display order. SPEC-067 read."""
        return self.view_registry.names()

    def restore_view(self, name: str) -> bool:
        """Restore a previously-archived view. Returns True on success.

        Rebuilds the sidebar so the restored button reappears. If the
        Tk root exists, re-runs ``_build_sidebar`` to add the missing
        button widget; otherwise just updates the registry + mirrors.
        """
        if not self.view_registry.restore(name):
            return False
        self._tabs = self.view_registry.as_tabs()
        self._tab_order = self.view_registry.names()
        # Rebuild the sidebar so the restored view's button reappears
        # at its registry-canonical position.
        if self.tk_root is not None and self._sidebar_frame is not None:
            try:
                self._rebuild_sidebar()
            except Exception as exc:
                self.engine.errors.append(f"gui_shell restore_view rebuild: {exc}")
        return True

    def register_view(self, spec: ViewSpec) -> None:
        """Register a new view at runtime. SPEC-067 extensibility.

        Plugins / extensions / the maintainer's future code can add
        views without subclassing the shell. The sidebar rebuilds so
        the new tab appears immediately.
        """
        self.view_registry.register(spec)
        # Also re-attach the help description for the new view.
        self._tabs = self.view_registry.as_tabs()
        self._tab_order = self.view_registry.names()
        self._tab_help = self.view_registry.help_map()
        if self.tk_root is not None and self._sidebar_frame is not None:
            try:
                self._rebuild_sidebar()
            except Exception as exc:
                self.engine.errors.append(f"gui_shell register_view rebuild: {exc}")

    def _rebuild_sidebar(self) -> None:
        """Tear down + rebuild the sidebar from the current registry.

        Used after ``restore_view`` / ``register_view`` so a view
        change propagates to the displayed buttons without restarting
        the shell. The active tab is preserved when possible.
        """
        if self._sidebar_frame is None:
            return
        for child in list(self._sidebar_frame.winfo_children()):
            try:
                child.destroy()
            except Exception:
                pass
        self._sidebar_buttons.clear()
        self._build_sidebar()
        if self.active_tab is not None and self.active_tab in self._tab_order:
            self._highlight_active_tab()

    def _on_toolbar_resize_start(self, event: Any) -> None:
        """Anchor the Ctrl-drag resize gesture on initial press.

        SPEC-072 verbatim: *holding control and dragging the modules
        around resizes all of them inside the toolbar*. The anchor
        captures the start y position + the current scale so subsequent
        motion events can compute a delta relative to the gesture
        origin rather than the previous motion event (which would
        compound errors).
        """
        if not self.ctrl_held:
            return
        try:
            self._resize_anchor_y = int(event.y_root)
        except Exception:
            self._resize_anchor_y = None
            return
        self._resize_anchor_scale = self._sidebar_scale

    def _on_toolbar_resize_drag(self, event: Any) -> None:
        """Apply Ctrl-drag delta as a uniform scale on all toolbar modules.

        Scale formula: ``new_scale = anchor_scale + delta_y / 200``.
        Positive y delta (drag down) grows the modules; negative shrinks.
        Clamped to [0.6, 2.5] so the toolbar can't vanish or eat the
        central pane.
        """
        if not self.ctrl_held or self._resize_anchor_y is None:
            return
        try:
            current_y = int(event.y_root)
        except Exception:
            return
        delta_y = current_y - self._resize_anchor_y
        new_scale = self._resize_anchor_scale + (delta_y / 200.0)
        self.set_sidebar_scale(new_scale)

    def set_sidebar_scale(self, scale: float) -> float:
        """Set the toolbar scale and re-render every sidebar button.

        SPEC-072 acceptance: every module in the toolbar resizes
        together; one drag changes all of them uniformly. Returns the
        clamped scale (caller can compare to its input to detect
        clamp). Public for tests + the text-API driver.
        """
        clamped = max(0.6, min(2.5, float(scale)))
        if abs(clamped - self._sidebar_scale) < 1e-6:
            return clamped
        self._sidebar_scale = clamped
        self._apply_sidebar_scale()
        return clamped

    def _apply_sidebar_scale(self) -> None:
        """Re-render sidebar buttons at the current scale factor.

        Font size and vertical padding both scale; horizontal padding
        held at the base value so the sidebar width stays approximately
        constant unless the maintainer explicitly resizes the column.
        """
        new_font_size = max(7, int(round(self._base_font_size * self._sidebar_scale)))
        new_pady = max(2, int(round(self._base_pady * self._sidebar_scale)))
        font = ("Helvetica", new_font_size)
        for btn in self._sidebar_buttons.values():
            try:
                btn.configure(font=font, pady=new_pady)
            except Exception:
                pass

    # ----- per-tab rendering -----

    def _render_active_tab(self) -> None:
        if self.active_tab is None or self._central_frame is None:
            return
        self._highlight_active_tab()
        # Clear central pane.
        for child in self._central_frame.winfo_children():
            try:
                child.destroy()
            except Exception:
                pass
        if self.active_tab == "3D":
            self._activate_3d()
            return
        # Refresh source caches on tab activation so the GUI reflects
        # external file edits + new inbox messages.
        try:
            self.engine.precompute()
        except Exception as exc:
            self.engine.errors.append(f"gui_shell precompute: {exc}")
        items = self.items_for_tab(self.active_tab)
        self._render_list_panel(items)

    def _render_list_panel(self, items: List[Dict[str, Any]]) -> None:
        """Build a Tk list panel for the given items in the central frame."""
        import tkinter as tk
        from tkinter import ttk

        header = tk.Frame(self._central_frame, bg="#2a2d34")
        header.pack(fill="x", padx=12, pady=(12, 0))

        title = tk.Label(
            header,
            text=self.active_tab,
            bg="#2a2d34",
            fg="#e8e8ec",
            font=("Helvetica", 14, "bold"),
            anchor="w",
        )
        title.pack(side="left")

        count = tk.Label(
            header,
            text=f"{len(items)} item(s)",
            bg="#2a2d34",
            fg="#8d92a3",
            font=("Helvetica", 10),
            anchor="e",
        )
        count.pack(side="right")

        # Action button strip (initially empty; populated when an item
        # is selected).
        action_bar = tk.Frame(self._central_frame, bg="#2a2d34")
        action_bar.pack(fill="x", padx=12, pady=(6, 0))

        # Tree + scrollbar in a sub-frame so they share a row.
        list_frame = tk.Frame(self._central_frame, bg="#2a2d34")
        list_frame.pack(fill="both", expand=True, padx=12, pady=12)

        style = ttk.Style(self._central_frame)
        try:
            style.theme_use("clam")
        except Exception:
            pass
        style.configure(
            "Apeiron.Treeview",
            background="#22252b",
            foreground="#e8e8ec",
            fieldbackground="#22252b",
            rowheight=24,
            font=("Helvetica", 10),
            borderwidth=0,
        )
        style.configure(
            "Apeiron.Treeview.Heading",
            background="#1c1f26",
            foreground="#c8ccd6",
            font=("Helvetica", 10, "bold"),
        )
        style.map(
            "Apeiron.Treeview",
            background=[("selected", "#3b4254")],
            foreground=[("selected", "#ffffff")],
        )

        tree = ttk.Treeview(
            list_frame,
            columns=("status", "title"),
            show="headings",
            style="Apeiron.Treeview",
        )
        tree.heading("status", text="St.")
        tree.heading("title", text="Item")
        tree.column("status", width=60, anchor="w", stretch=False)
        tree.column("title", anchor="w")

        scroll = ttk.Scrollbar(list_frame, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=scroll.set)
        tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        # Body display below the list (collapsed by default).
        body_frame = tk.Frame(self._central_frame, bg="#1c1f26")
        # Packed/unpacked dynamically on expand.

        from node_types.list_renderer import DEFAULT_STATUS_GLYPHS

        for item in items:
            status = item.get("status")
            glyph = DEFAULT_STATUS_GLYPHS.get(status, "•") if status is not None else "•"
            iid = item.get("id") or item.get("title", "")
            tree.insert(
                "",
                "end",
                iid=str(iid),
                values=(glyph, item.get("title", "")),
            )

        def render_actions_for(item: Dict[str, Any]) -> None:
            for child in action_bar.winfo_children():
                try:
                    child.destroy()
                except Exception:
                    pass
            actions = item.get("actions") or ["expand"]
            for act in actions:
                btn = tk.Button(
                    action_bar,
                    text=act,
                    bg="#3b4254",
                    fg="#e8e8ec",
                    activebackground="#4d566d",
                    activeforeground="#ffffff",
                    relief="flat",
                    font=("Helvetica", 9),
                    padx=10,
                    pady=2,
                    command=lambda a=act, it=item: self._on_action(a, it),
                )
                btn.pack(side="left", padx=(0, 6))

        def on_select(_event: Any) -> None:
            sel = tree.selection()
            if not sel:
                return
            iid = sel[0]
            for it in items:
                if str(it.get("id")) == iid:
                    render_actions_for(it)
                    if self._expanded_item_id == iid:
                        self._show_body(body_frame, it)
                    break

        def on_double_click(_event: Any) -> None:
            sel = tree.selection()
            if not sel:
                return
            iid = sel[0]
            if self._expanded_item_id == iid:
                self._expanded_item_id = None
                body_frame.pack_forget()
                return
            self._expanded_item_id = iid
            for it in items:
                if str(it.get("id")) == iid:
                    self._show_body(body_frame, it)
                    break

        tree.bind("<<TreeviewSelect>>", on_select)
        tree.bind("<Double-Button-1>", on_double_click)

        # Re-pack the body frame at the bottom; hidden until expand.
        body_frame.pack(fill="x", padx=12, pady=(0, 12))
        body_frame.pack_forget()

    def _show_body(self, body_frame: Any, item: Dict[str, Any]) -> None:
        import tkinter as tk

        for child in body_frame.winfo_children():
            try:
                child.destroy()
            except Exception:
                pass

        title = tk.Label(
            body_frame,
            text=item.get("title", ""),
            bg="#1c1f26",
            fg="#e8e8ec",
            font=("Helvetica", 11, "bold"),
            anchor="w",
            padx=12,
            pady=6,
        )
        title.pack(fill="x")

        body_text = item.get("body") or "(no body)"
        text = tk.Text(
            body_frame,
            bg="#15171c",
            fg="#c8ccd6",
            font=("Helvetica", 10),
            wrap="word",
            relief="flat",
            height=8,
        )
        text.insert("1.0", body_text)
        text.configure(state="disabled")
        text.pack(fill="x", padx=12, pady=(0, 12))

        body_frame.pack(fill="x", padx=12, pady=(0, 12))

    # ----- 3D tab -----

    def _activate_3d(self) -> None:
        import tkinter as tk

        if self.scene_root_id is None or self.scene_path is None:
            placeholder = tk.Label(
                self._central_frame,
                text="3D tab requires a loaded scene. Pass --scene at launch.",
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            return

        try:
            from engine.realtime import RealtimeDriver, make_backend
            from engine.node import View, look_at
            import json
            import numpy as np
        except Exception as exc:
            placeholder = tk.Label(
                self._central_frame,
                text=f"3D unavailable: import failed ({exc})",
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            return

        # Scene view setup mirrors the terminal shell's /realtime cmd.
        try:
            scene_data = json.loads(self.scene_path.read_text(encoding="utf-8"))
        except Exception as exc:
            placeholder = tk.Label(
                self._central_frame,
                text=f"3D scene read failed: {exc}",
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            return

        # Force a layout pass so winfo_width/height return real numbers.
        self._central_frame.update_idletasks()
        width = max(320, self._central_frame.winfo_width())
        height = max(240, self._central_frame.winfo_height())

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
            self.engine.errors.append(f"gui_shell precompute (3D activate): {exc}")

        try:
            self._backend = make_backend()
            self._backend.open(
                width=width,
                height=height,
                title="Apeiron 3D",
                parent=self._central_frame,
            )
        except TypeError:
            # Backend predates the parent kwarg — fall back to a
            # placeholder rather than spawning a separate window.
            placeholder = tk.Label(
                self._central_frame,
                text=(
                    "3D embedding unsupported by current backend. "
                    "Run `python -m tools.realtime` for the standalone 3D window."
                ),
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            self._backend = None
            return
        except Exception as exc:
            placeholder = tk.Label(
                self._central_frame,
                text=f"3D backend open failed: {exc}",
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            self._backend = None
            return

        self._driver = RealtimeDriver(
            engine=self.engine,
            root_id=self.scene_root_id,
            view=view,
            frame_budget_s=0.0,  # cooperate with after() pacing
        )
        self._frame_pump_active = True
        self._schedule_frame_pump()

    def _schedule_frame_pump(self) -> None:
        if not self._frame_pump_active or self.tk_root is None:
            return
        self._frame_pump_after_id = self.tk_root.after(
            self._frame_budget_ms, self._frame_pump
        )

    def _frame_pump(self) -> None:
        if not self._frame_pump_active:
            return
        if self._driver is None or self._backend is None:
            return
        try:
            self._driver.run_one_frame(self._backend)
        except Exception as exc:
            self.engine.errors.append(f"gui_shell 3D frame: {exc}")
            self._teardown_3d()
            return
        if self._driver.should_quit(self._backend):
            self._teardown_3d()
            return
        self._schedule_frame_pump()

    def _teardown_3d(self) -> None:
        self._frame_pump_active = False
        if self._frame_pump_after_id is not None and self.tk_root is not None:
            try:
                self.tk_root.after_cancel(self._frame_pump_after_id)
            except Exception:
                pass
            self._frame_pump_after_id = None
        if self._backend is not None:
            try:
                self._backend.close()
            except Exception:
                pass
            self._backend = None
        self._driver = None

    # ----- actions + chat -----

    def _on_action(self, action: str, item: Dict[str, Any]) -> None:
        """Dispatch a per-item action.

        ``expand`` and ``collapse`` are local UI state — the central
        pane's body display toggles. Every other action dispatches
        through ``engine.actions.dispatch_action`` against the tab's
        renderer node-id, so trust mutations / file edits / etc. flow
        through the same code path the 3D surface uses.
        """
        iid = str(item.get("id"))
        if action == "expand":
            # Trigger a re-render of the tab so the body view appears.
            self._expanded_item_id = iid
            self._render_active_tab()
            return
        if action == "collapse":
            self._expanded_item_id = None
            self._render_active_tab()
            return

        panel_id = self.panel_id_for_tab(self.active_tab or "")
        if not panel_id:
            return
        try:
            from engine.actions import dispatch_action

            dispatch_action(self.engine, panel_id, action, item_id=iid)
        except Exception as exc:
            self.engine.errors.append(f"gui_shell action: {exc}")
            return
        # Refresh the tab after the action so the list reflects the change.
        self._render_active_tab()

    def _on_chat_submit(self) -> None:
        if self._chat_entry is None:
            return
        text = self._chat_entry.get().strip()
        if not text:
            return
        self._chat_entry.delete(0, "end")
        if self.active_session_id is None:
            # No active session — show a hint by writing into the chat
            # input as placeholder text the user can clear.
            self._chat_entry.insert(0, "(no active session — open Chat tab to pick one)")
            return
        try:
            self.sm.send(self.active_session_id, text)
        except SessionError as exc:
            self._chat_entry.insert(0, f"(send failed: {exc})")
            return

    # ----- default session bootstrap -----

    def ensure_default_workflow_mgmt_session(
        self,
        seed_builder: Optional[Callable[[Path, Optional[Path]], str]] = None,
        alethea_root: Optional[Path] = None,
    ) -> Optional[str]:
        """Mirror of the terminal shell's same-named method.

        Records the spawned session id on a marker file so subsequent
        launches resume the same workflow-management session rather
        than spawning a fresh one each time.
        """
        marker = Path(self.sm.state_dir) / "default_workflow_mgmt.txt"
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
                return existing_id

        # Reuse the terminal shell's seed builder to keep the prompt
        # identical across both surfaces.
        from tools.workflow.shell import _build_workflow_mgmt_seed

        seed = (seed_builder or _build_workflow_mgmt_seed)(
            self.root, alethea_root
        )
        try:
            rec = self.sm.spawn(
                session_type="workflow-management",
                display_name="workflow-mgmt-default",
                cwd=self.root,
                seed_message=seed,
            )
        except SessionError:
            return None

        self.active_session_id = rec.id
        try:
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(rec.id, encoding="utf-8")
        except Exception:
            pass
        return rec.id

    # ----- lifecycle -----

    def _on_close(self) -> None:
        self._teardown_3d()
        if self.file_watcher is not None:
            try:
                self.file_watcher.stop()
            except Exception:
                pass
        try:
            self.sm.shutdown()
        except Exception:
            pass
        if self.tk_root is not None:
            try:
                self.tk_root.destroy()
            except Exception:
                pass
            self.tk_root = None

    def mainloop(self) -> None:
        if self.tk_root is None:
            self.build_ui()
        self.tk_root.mainloop()


# ---------------------------------------------------------------------------
# CLI entry — mirrors tools.workflow.shell.main flag-for-flag.
# ---------------------------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.workflow_gui",
        description="Apeiron 2D Tk workflow shell (SPEC-065).",
    )
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
        help="Skip auto-spawn of the default workflow-management session.",
    )
    parser.add_argument(
        "--alethea-root",
        default=None,
        help="Path to Alethea repo root. Defaults to sibling-of-Apeiron heuristic.",
    )
    parser.add_argument(
        "--skip-auth",
        action="store_true",
        help="Skip the login gate (SPEC-056). For testing only.",
    )
    parser.add_argument(
        "--accounts-path",
        default=None,
        help="Override the accounts store path. Defaults to <repo>/state/accounts.json.",
    )
    args = parser.parse_args(argv)

    # The terminal shell already has the boot procedure (login + engine
    # + sm + inbox + trust). Re-use as much of it as possible by
    # delegating to its private detectors.
    from tools.workflow.shell import _detect_alethea_root, _detect_root

    root = Path(args.root) if args.root else _detect_root()
    state_dir = Path(args.state_dir) if args.state_dir else (root / "state" / "workflow")
    alethea_root = Path(args.alethea_root) if args.alethea_root else _detect_alethea_root(root)
    accounts_path = (
        Path(args.accounts_path) if args.accounts_path else (root / DEFAULT_ACCOUNTS_PATH)
    )

    current_user: Optional[str] = None
    if not args.skip_auth:
        try:
            from tools.workflow.login_gate import run_login_gate
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

    scene_arg = args.scene or "workflow_view"
    scene_path = (root / "scenes" / scene_arg) if not Path(scene_arg).is_absolute() else Path(scene_arg)
    if not scene_path.exists() and scene_path.suffix != ".json":
        with_suffix = scene_path.with_suffix(".json")
        if with_suffix.exists():
            scene_path = with_suffix
    scene_root_id: Optional[str] = None
    if scene_path.exists():
        scene_root_id = engine.load_scene(scene_path)
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

    shell = GuiShell(
        engine=engine,
        session_manager=sm,
        inbox=inbox,
        root=root,
        scene_path=scene_path if scene_path.exists() else None,
        scene_root_id=scene_root_id,
        current_user=current_user,
    )

    fw: Optional[FileWatcher] = None
    if not args.no_watch:
        def _on_file_event(kind: str, type_name: str, path: Path) -> None:
            sys.stderr.write(
                f"[fwatch] {kind} {type_name} {path.name}\n"
            )
        fw = FileWatcher(engine, on_event=_on_file_event)
        fw.start()
    shell.file_watcher = fw

    if not args.no_default_session:
        shell.ensure_default_workflow_mgmt_session(alethea_root=alethea_root)

    try:
        shell.mainloop()
    finally:
        if fw is not None:
            fw.stop()
        sm.shutdown()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
