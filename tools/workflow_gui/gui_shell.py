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
from dataclasses import dataclass, field
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
from tools.workflow_gui.widget_lock import WidgetLock


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
# Panel positioning model (SPEC-007).
# ---------------------------------------------------------------------------


# Snap-grid resolution in pixels. Every panel move/resize through the
# text-API + drag handlers rounds to this grid so panels align cleanly
# along visible columns. 12 px is the design-doc value (the cockpit
# original used 8; bumped for Tk's coarser place-drag granularity).
SNAP_GRID_PX = 12


def snap_to_grid(value: int, grid: int = SNAP_GRID_PX) -> int:
    """Round ``value`` to the nearest ``grid`` multiple. Public for tests.

    Negative values round toward 0 (not toward -infinity) so a panel
    dragged slightly past the top-left edge clamps to (0, 0) rather
    than (-grid, -grid).
    """
    if grid <= 0:
        return int(value)
    return int(round(value / grid) * grid)


@dataclass
class PanelHandle:
    """Per-panel position + lock state (SPEC-007 + SPEC-075).

    One handle per visible panel in the panel host. The handle is the
    source of truth for `(x, y, w, h, archived)`. The lock flag, as of
    SPEC-075, is NOT stored on the handle directly — it delegates to a
    ``WidgetLock`` registry (one per ``GuiShell``) so panel-level locks
    and per-icon / per-button locks share a single source of truth.

    The ``locked`` attribute remains a property for backward compat:
    every SPEC-007 read path (drag handlers, panel_state, archive cycle)
    continues to use ``handle.locked`` without knowing about WidgetLock.
    Writes through ``handle.locked = True`` route into the registry.

    The registry reference is set by ``GuiShell._ensure_panel_handle``
    immediately after construction; tests that build a PanelHandle in
    isolation (no shell) can also set ``_lock_registry`` directly or
    leave it None, in which case ``locked`` falls back to a private
    per-handle bool. This keeps PanelHandle usable as a plain dataclass
    in unit tests that don't need the shared registry semantic.

    Two panels of the same view (paste-as-duplicate from SPEC-073) can
    have independent handles — the dict key is the panel's node_id,
    not the view name. With the WidgetLock registry, the panel's
    lock state is keyed by the same id, so two paste-duplicate panels
    lock independently as before.
    """

    view_name: str
    """The view the panel renders (the registry name, not the widget name)."""

    x: int = 0
    y: int = 0
    w: int = 480
    h: int = 320
    archived: bool = False
    # SPEC-075: the lock registry the handle delegates to. Set by
    # GuiShell._ensure_panel_handle after construction; remains None
    # for unit tests that build a PanelHandle in isolation. The
    # property below masks the private fallback flag when a registry
    # is wired up.
    _lock_registry: Optional[WidgetLock] = None
    _panel_id: Optional[str] = None
    # Fallback bool for the no-registry case (unit tests that build
    # PanelHandle without a GuiShell). When the registry is set, the
    # property below ignores this field entirely.
    _fallback_locked: bool = False

    @property
    def locked(self) -> bool:
        """SPEC-075 delegating accessor: read from the WidgetLock
        registry when one is attached, fall back to the per-handle bool
        when constructed in isolation.
        """
        if self._lock_registry is not None and self._panel_id is not None:
            return self._lock_registry.is_widget_locked(self._panel_id)
        return self._fallback_locked

    @locked.setter
    def locked(self, value: bool) -> None:
        """SPEC-075 delegating mutator: write to the WidgetLock registry
        when one is attached. The registry's widget_kind for panel
        handles is ``"panel"`` so list-locked-widgets can group panels
        distinctly from icons/buttons/regions.
        """
        if self._lock_registry is not None and self._panel_id is not None:
            if value:
                self._lock_registry.lock_widget(
                    self._panel_id,
                    position=(self.x, self.y),
                    widget_kind="panel",
                )
            else:
                self._lock_registry.unlock_widget(self._panel_id)
        else:
            self._fallback_locked = bool(value)


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
        self._panel_host: Any = None
        self._sidebar_frame: Any = None
        self._chat_entry: Any = None
        self._sidebar_buttons: Dict[str, Any] = {}

        # SPEC-007 panel positioning model. `_panel_handles` holds one
        # PanelHandle per visible panel, keyed by panel node id (which
        # for the v1 single-panel-per-tab case is the tab name). The
        # central pane uses `place()` to position panels at the handle's
        # (x, y, w, h). `_panel_widgets` tracks the live Tk Frame so the
        # drag / resize / lock handlers can re-place it from the handle.
        # `_panel_drag` is the per-drag-gesture state (anchor coords +
        # original handle x/y) so motion events can compute deltas.
        self._panel_handles: Dict[str, PanelHandle] = {}
        self._panel_widgets: Dict[str, Any] = {}
        self._panel_drag: Optional[Dict[str, Any]] = None
        # SPEC-075: per-widget lock registry. Panel-level locks delegate
        # through here (PanelHandle.locked is a property that consults
        # this registry). Per-icon / per-button locks live here too —
        # there's one source of truth for "is this widget locked?".
        # Widget construction sites register their lockable widgets so
        # ``list-locked-widgets`` can group panel / button / icon kinds.
        self.widget_lock: WidgetLock = WidgetLock()
        # SPEC-075: per-widget Tk widget map so drag handlers and the
        # context menu can locate the live widget by its widget_id.
        # Keyed by the same id used in the registry; values are the
        # Tk widget references registered at build time.
        self._lockable_widgets: Dict[str, Any] = {}
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

        # SPEC-066 Browser tab state. ``_browser_frame`` is the live
        # tkinterweb HtmlFrame when a web view is active; cleared on
        # tab switch so callers (browser-open verb, current-url query)
        # can detect inactive state without poking at destroyed
        # widgets.
        self._browser_frame: Any = None
        self._browser_url_var: Any = None

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
            if spec.kind == "web":
                # SPEC-066: web views render an HtmlFrame directly into
                # the central pane (handled in _render_active_tab). The
                # list-of-items surface is empty by design — the browser
                # widget is the central pane, not a list.
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
            if (
                source_id.startswith("_text:")
                or source_id.startswith("_custom:")
                or source_id.startswith("_web:")
            ):
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

        # SPEC-007 panel host. A child frame of the central pane that
        # uses `place()` for absolute (x, y, w, h) positioning of panel
        # widgets. The host itself fills the central pane; panels are
        # placed inside via PanelHandle records. The previous Arc K
        # layout packed/gridded widgets directly into _central_frame;
        # SPEC-007 routes everything through the host so move/resize/
        # snap-to-grid have a single coordinate space to operate in.
        self._panel_host = tk.Frame(self._central_frame, bg="#2a2d34")
        self._panel_host.place(x=0, y=0, relwidth=1.0, relheight=1.0)

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
            # SPEC-008 right-click context menu on sidebar buttons.
            btn.bind("<Button-3>",
                     lambda e, n=name: self._show_context_menu(e, "sidebar", n))
            btn.bind("<Button-2>",
                     lambda e, n=name: self._show_context_menu(e, "sidebar", n))
            # SPEC-075 + SPEC-072: Ctrl-right-click opens the per-widget
            # Lock/Unlock menu on sidebar buttons. The widget_id is the
            # tab name prefixed so it can't collide with panel ids.
            wid = f"sidebar:{name}"
            self.register_lockable_widget(wid, btn, widget_kind="button")
            btn.bind("<Control-Button-3>",
                     lambda e, w=wid: self._show_widget_context_menu(
                         e, w, "button"))
            btn.bind("<Control-Button-2>",
                     lambda e, w=wid: self._show_widget_context_menu(
                         e, w, "button"))
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

        Bug-fix 2026-05-20 (stress-test): archiving the last visible
        view used to fall back to DEFAULT_TAB ("Tasks") even when
        Tasks was already archived. Now if no visible alternative
        exists, active_tab is set to None — the GUI shows an empty
        central pane rather than a dangling pointer.
        """
        # Don't let the active tab vanish without a fallback selection.
        if tab_name == self.active_tab:
            # Pick a visible alternative; only fall back to DEFAULT_TAB
            # if DEFAULT_TAB is still visible. Otherwise leave
            # active_tab as None so the central pane clears.
            visible_alternatives = [
                n for n in self.view_registry.names() if n != tab_name
            ]
            if visible_alternatives:
                # Prefer DEFAULT_TAB when it's visible, else first.
                fallback = (
                    DEFAULT_TAB
                    if DEFAULT_TAB in visible_alternatives
                    else visible_alternatives[0]
                )
                self.select_tab(fallback)
            else:
                # No visible alternative — clear active tab cleanly.
                self.active_tab = None
                self._expanded_item_id = None
                if self.tk_root is not None and self._central_frame is not None:
                    for child in self._central_frame.winfo_children():
                        try:
                            child.destroy()
                        except Exception:
                            pass
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
        # Clear panel host. SPEC-007: panels are placed inside
        # _panel_host with absolute coordinates so move/resize/snap
        # have a single coordinate space. Destroying the children
        # cleanly preserves the host itself.
        host = self._panel_host if self._panel_host is not None else self._central_frame
        for child in host.winfo_children():
            try:
                child.destroy()
            except Exception:
                pass
        self._panel_widgets.clear()
        # SPEC-066: clear stale browser handles so a tab switch
        # away from Browser doesn't leave dangling references to
        # destroyed widgets.
        self._browser_frame = None
        self._browser_url_var = None
        if self.active_tab == "3D":
            self._activate_3d()
            return
        # SPEC-066: web views own the central pane via an embedded
        # tkinterweb HtmlFrame; the list-panel path doesn't fit (no
        # items list to render). The shell instantiates the frame
        # itself so the embedding lifecycle (URL load, refresh,
        # teardown on tab switch) lives in one place.
        spec = self.view_registry.get(self.active_tab)
        if spec is not None and spec.kind == "web":
            self._activate_web(spec)
            return
        # Refresh source caches on tab activation so the GUI reflects
        # external file edits + new inbox messages.
        try:
            self.engine.precompute()
        except Exception as exc:
            self.engine.errors.append(f"gui_shell precompute: {exc}")
        items = self.items_for_tab(self.active_tab)
        self._render_list_panel(items)

    def _ensure_panel_handle(self, panel_id: str) -> PanelHandle:
        """Return the PanelHandle for ``panel_id``, creating it at the
        default position if absent. SPEC-007 invariant: every visible
        panel has a handle; handle creation is implicit on first render.

        SPEC-075: every new handle is wired to the shell's WidgetLock
        registry so ``handle.locked`` delegates through there. Pre-
        registers the panel at ``widget_kind="panel"`` so
        ``list-locked-widgets`` surfaces the panel even before it's
        locked. The registration is monotonic: re-ensuring an existing
        panel doesn't disturb the registry.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None:
            # Default position: stagger by the number of existing
            # handles so multiple panels don't stack at (0, 0).
            offset = len(self._panel_handles) * SNAP_GRID_PX * 2
            handle = PanelHandle(
                view_name=panel_id,
                x=snap_to_grid(offset),
                y=snap_to_grid(offset),
                w=480,
                h=320,
                _lock_registry=self.widget_lock,
                _panel_id=panel_id,
            )
            self._panel_handles[panel_id] = handle
            # Pre-register so list-locked-widgets can disambiguate
            # panels from per-icon entries even when no lock has fired.
            self.widget_lock.register(panel_id, widget_kind="panel")
        else:
            # Defensive wiring for handles that may have been built via
            # an older code path (or in tests that pre-create handles).
            if handle._lock_registry is None:
                handle._lock_registry = self.widget_lock
                handle._panel_id = panel_id
                # Preserve any locked state from the per-handle fallback
                # bool into the registry so the source of truth catches up.
                if handle._fallback_locked:
                    self.widget_lock.lock_widget(
                        panel_id,
                        position=(handle.x, handle.y),
                        widget_kind="panel",
                    )
                    handle._fallback_locked = False
        return handle

    def _render_list_panel(self, items: List[Dict[str, Any]]) -> None:
        """Build a Tk list panel for the given items, placed inside the
        SPEC-007 panel host at the panel handle's (x, y, w, h).

        v1 single-panel-per-tab behaviour: the active tab name is used
        as the panel id. Future versions (multi-panel, paste-as-
        duplicate from SPEC-073) will key by node id so two panels of
        the same view can coexist with independent handles.
        """
        import tkinter as tk
        from tkinter import ttk

        # Resolve the panel id (v1: tab name) + the handle.
        panel_id = self.active_tab or "panel"
        handle = self._ensure_panel_handle(panel_id)

        # The panel frame is a `place`-positioned child of the panel
        # host. Drag handlers on the header reposition this frame by
        # mutating handle.x/y then re-placing.
        host = self._panel_host if self._panel_host is not None else self._central_frame
        panel_frame = tk.Frame(host, bg="#2a2d34", highlightthickness=1,
                               highlightbackground="#3b4254")
        panel_frame.place(x=handle.x, y=handle.y, width=handle.w, height=handle.h)
        self._panel_widgets[panel_id] = panel_frame

        # SPEC-007 v2 resize grip — a small square at the SE corner of
        # the panel that drag-resizes by mutating handle.w/h. The grip
        # uses place() with rel-anchors so it stays glued to the SE
        # corner regardless of the panel's current (w, h).
        grip = tk.Frame(panel_frame, bg="#3b4254", cursor="bottom_right_corner",
                        width=14, height=14)
        grip.place(relx=1.0, rely=1.0, anchor="se")
        grip.bind("<ButtonPress-1>",
                  lambda e, pid=panel_id: self._on_panel_resize_start(e, pid))
        grip.bind("<B1-Motion>",
                  lambda e, pid=panel_id: self._on_panel_resize_motion(e, pid))
        grip.bind("<ButtonRelease-1>",
                  lambda e, pid=panel_id: self._on_panel_resize_release(e, pid))

        header = tk.Frame(panel_frame, bg="#2a2d34", cursor="fleur")
        header.pack(fill="x", padx=12, pady=(12, 0))

        title = tk.Label(
            header,
            text=self.active_tab,
            bg="#2a2d34",
            fg="#e8e8ec",
            font=("Helvetica", 14, "bold"),
            anchor="w",
            cursor="fleur",
        )
        title.pack(side="left")

        count = tk.Label(
            header,
            text=f"{len(items)} item(s)",
            bg="#2a2d34",
            fg="#8d92a3",
            font=("Helvetica", 10),
            anchor="e",
            cursor="fleur",
        )
        count.pack(side="right")

        # SPEC-007 drag-to-move: pressing the left mouse button on the
        # header (or any of its children) starts a drag; B1-Motion
        # repositions the panel via place(); ButtonRelease commits the
        # final snapped position. The handlers operate on the panel
        # node id captured in the lambda so a single binding covers
        # any panel in the host.
        for w in (header, title, count):
            w.bind("<ButtonPress-1>",
                   lambda e, pid=panel_id: self._on_panel_drag_start(e, pid))
            w.bind("<B1-Motion>",
                   lambda e, pid=panel_id: self._on_panel_drag_motion(e, pid))
            w.bind("<ButtonRelease-1>",
                   lambda e, pid=panel_id: self._on_panel_drag_release(e, pid))
            # SPEC-008 right-click context menu. Bind both Button-3
            # (Windows/Linux) and Button-2 (Mac default) so the menu
            # opens regardless of platform / input device.
            w.bind("<Button-3>",
                   lambda e, pid=panel_id: self._show_context_menu(e, "panel", pid))
            w.bind("<Button-2>",
                   lambda e, pid=panel_id: self._show_context_menu(e, "panel", pid))
            # SPEC-075 + SPEC-072: Ctrl-right-click surfaces the
            # per-widget Lock / Unlock menu directly so the maintainer
            # doesn't have to navigate through the larger SPEC-008
            # menu when they only want to toggle a lock. Composes
            # with SPEC-008's right-click: Ctrl-Button-3 is the
            # per-widget gesture; bare Button-3 is the surface menu.
            w.bind("<Control-Button-3>",
                   lambda e, pid=panel_id: self._show_widget_context_menu(
                       e, pid, "panel"))
            w.bind("<Control-Button-2>",
                   lambda e, pid=panel_id: self._show_widget_context_menu(
                       e, pid, "panel"))

        # SPEC-075: register the panel frame as a lockable widget too
        # so list-locked-widgets reflects panel-level locks (the
        # PanelHandle's locked flag is the source of truth, but the
        # registry surface needs the entry to enumerate it).
        self.register_lockable_widget(panel_id, panel_frame, widget_kind="panel")

        # Action button strip (initially empty; populated when an item
        # is selected).
        action_bar = tk.Frame(panel_frame, bg="#2a2d34")
        action_bar.pack(fill="x", padx=12, pady=(6, 0))

        # Tree + scrollbar in a sub-frame so they share a row.
        list_frame = tk.Frame(panel_frame, bg="#2a2d34")
        list_frame.pack(fill="both", expand=True, padx=12, pady=12)

        style = ttk.Style(panel_frame)
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
        body_frame = tk.Frame(panel_frame, bg="#1c1f26")
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

    # ----- SPEC-007 movable / resizable / snap / lock -----

    def move_panel(self, panel_id: str, x: int, y: int) -> Dict[str, Any]:
        """Move a panel to (x, y), snapped to the 12-px grid.

        Idempotent for already-positioned panels: the snap-grid math
        round-trips through ``move_panel`` (calling twice with the
        same args is a no-op once the grid has clamped). Locked panels
        refuse the move and return the current (un-moved) state.
        Returns the resulting handle dict for assertion.
        """
        handle = self._ensure_panel_handle(panel_id)
        if handle.locked:
            return self.panel_state(panel_id)
        snapped_x = snap_to_grid(int(x))
        snapped_y = snap_to_grid(int(y))
        handle.x = snapped_x
        handle.y = snapped_y
        # Re-place the live widget if it exists. The widget is None
        # when the panel hasn't been rendered yet (e.g. headless tests
        # that only exercise the handle layer); skip silently.
        widget = self._panel_widgets.get(panel_id)
        if widget is not None:
            try:
                widget.place(x=handle.x, y=handle.y,
                             width=handle.w, height=handle.h)
            except Exception as exc:
                self.engine.errors.append(
                    f"gui_shell move_panel place: {exc}"
                )
        return self.panel_state(panel_id)

    def resize_panel(self, panel_id: str, w: int, h: int) -> Dict[str, Any]:
        """Resize a panel to (w, h), snapped to the 12-px grid.

        Locked panels refuse the resize. Width and height are clamped
        to a 48 px minimum so a snap-to-zero doesn't make the panel
        unreachable.
        """
        handle = self._ensure_panel_handle(panel_id)
        if handle.locked:
            return self.panel_state(panel_id)
        snapped_w = max(48, snap_to_grid(int(w)))
        snapped_h = max(48, snap_to_grid(int(h)))
        handle.w = snapped_w
        handle.h = snapped_h
        widget = self._panel_widgets.get(panel_id)
        if widget is not None:
            try:
                widget.place(x=handle.x, y=handle.y,
                             width=handle.w, height=handle.h)
            except Exception as exc:
                self.engine.errors.append(
                    f"gui_shell resize_panel place: {exc}"
                )
        return self.panel_state(panel_id)

    def lock_panel(self, panel_id: str) -> bool:
        """Lock a panel — drag/resize handlers and ``move_panel`` /
        ``resize_panel`` early-return without modifying the handle.
        Returns True if locked; False if no such panel handle.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None:
            return False
        handle.locked = True
        return True

    def unlock_panel(self, panel_id: str) -> bool:
        """Unlock a panel. Returns True if unlocked; False if absent."""
        handle = self._panel_handles.get(panel_id)
        if handle is None:
            return False
        handle.locked = False
        return True

    def is_locked(self, panel_id: str) -> bool:
        """Return True if the panel handle exists and is locked."""
        handle = self._panel_handles.get(panel_id)
        return bool(handle and handle.locked)

    # ----- SPEC-075 per-widget lock API -----

    def lock_widget(
        self,
        widget_id: str,
        *,
        widget_kind: str = "",
    ) -> bool:
        """Lock any widget by id. The widget can be a panel, a button,
        an icon, a frame, or any other registered affordance. Returns
        True. Lazily registers an entry in the WidgetLock registry if
        absent so the first lock call is also the registration.

        SPEC-075 acceptance: any visible widget can be locked. When the
        widget_id matches a panel handle, the lock automatically routes
        through the PanelHandle's delegating property so SPEC-007's
        existing drag/resize handlers (which check ``handle.locked``)
        see the change too.

        For non-panel widgets, the registry alone holds the lock state;
        drag handlers for those widgets consult ``is_widget_locked``
        before mutating position. The widget's frozen position is
        recorded from its registered Tk geometry if a widget has been
        registered via ``register_lockable_widget``.
        """
        # If this widget corresponds to a panel handle, route through
        # the panel API so the SPEC-007 invariants (returns True on
        # existing handle, archive interactions) remain consistent.
        if widget_id in self._panel_handles:
            return self.lock_panel(widget_id)
        # Otherwise: register or lock-update via the registry.
        position: Optional[Tuple[int, int]] = None
        live_widget = self._lockable_widgets.get(widget_id)
        if live_widget is not None:
            try:
                # winfo_x / winfo_y are the live screen coordinates the
                # geometry manager has placed the widget at. Captured at
                # lock time as the frozen-position snapshot for v2
                # layout-resistance.
                position = (
                    int(live_widget.winfo_x()),
                    int(live_widget.winfo_y()),
                )
            except Exception:
                position = None
        self.widget_lock.lock_widget(
            widget_id, position=position, widget_kind=widget_kind
        )
        return True

    def unlock_widget(self, widget_id: str) -> bool:
        """Unlock any widget by id. Returns True if an entry existed
        (panel or non-panel) and was unlocked. Returns False if no
        entry exists in either the panel-handle table or the registry.
        """
        if widget_id in self._panel_handles:
            return self.unlock_panel(widget_id)
        return self.widget_lock.unlock_widget(widget_id)

    def is_widget_locked(self, widget_id: str) -> bool:
        """Return True if the widget is currently locked.

        Routes through the registry as the single source of truth. For
        panel widgets, the PanelHandle.locked property already consults
        the registry, so a single registry read covers both panel and
        non-panel cases.
        """
        return self.widget_lock.is_widget_locked(widget_id)

    def widget_lock_state(self, widget_id: str) -> Dict[str, Any]:
        """Return the per-widget lock entry as a plain dict for the
        text-API ``widget-lock-state`` verb. Empty dict when no entry
        exists yet. Mirrors the SPEC-007 ``panel_state`` convention.
        """
        return self.widget_lock.widget_state(widget_id)

    def list_locked_widgets(self) -> List[Dict[str, Any]]:
        """Return the registry's currently-locked entries (panel /
        button / icon / region kinds) as a list of dicts sorted by
        widget_id. Used by the text-API verb of the same name and by
        the ready-check probe to verify the registry CRUD round-trips.
        """
        return self.widget_lock.list_locked_widgets()

    def register_lockable_widget(
        self,
        widget_id: str,
        widget: Any,
        *,
        widget_kind: str = "",
    ) -> None:
        """Register a Tk widget as lockable. Called from the widget
        construction sites in ``build_ui`` / ``_render_list_panel``
        / ``_build_sidebar`` so the context menu and drag handlers
        can resolve widget_id → Tk widget at lock time.

        Idempotent. Re-registering the same id overwrites the widget
        reference (the most recent construction wins, matching what the
        rest of the shell already does for ``_panel_widgets``).
        """
        self._lockable_widgets[widget_id] = widget
        self.widget_lock.register(widget_id, widget_kind=widget_kind)

    def panel_state(self, panel_id: str) -> Dict[str, Any]:
        """Return the panel handle as a plain dict for assertion + the
        text-API ``panel-state`` verb. Returns an empty dict when the
        panel doesn't have a handle yet.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None:
            return {}
        return {
            "panel_id": panel_id,
            "view_name": handle.view_name,
            "x": handle.x,
            "y": handle.y,
            "w": handle.w,
            "h": handle.h,
            "locked": handle.locked,
            "archived": handle.archived,
        }

    def archive_panel(self, panel_id: str) -> bool:
        """Archive a panel — hide it from the host while preserving the
        handle so ``restore_panel`` brings it back at the prior (x, y,
        w, h). Returns True on success.

        Composes with SPEC-067: archiving a panel that backs a view
        also archives the view so the sidebar tab disappears. The
        underlying ViewRegistry is the source of truth for which views
        are visible; the PanelHandle's ``archived`` flag tracks the
        per-instance position state so a restore-from-Archive view can
        place the panel back exactly where it was.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None:
            return False
        handle.archived = True
        # Hide the live widget if it exists. The widget stays in
        # _panel_widgets so a subsequent restore can re-place it
        # without rebuilding the tree.
        widget = self._panel_widgets.get(panel_id)
        if widget is not None:
            try:
                widget.place_forget()
            except Exception:
                pass
        # Compose with ViewRegistry: archive the corresponding view
        # so the sidebar tab also disappears. SPEC-008 names this
        # composition explicitly.
        if self.view_registry.get(handle.view_name) is not None:
            self._archive_tab(handle.view_name)
        return True

    def restore_panel(self, panel_id: str) -> bool:
        """Restore a previously-archived panel to its prior position.

        The handle's (x, y, w, h, locked) are preserved through the
        archive cycle so a panel that was locked stays locked when
        restored.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None:
            return False
        handle.archived = False
        # Re-activate the view (SPEC-067) so the sidebar tab reappears.
        if self.view_registry.is_archived(handle.view_name):
            self.restore_view(handle.view_name)
        # Re-place the live widget at the saved coordinates.
        widget = self._panel_widgets.get(panel_id)
        if widget is not None:
            try:
                widget.place(x=handle.x, y=handle.y,
                             width=handle.w, height=handle.h)
            except Exception as exc:
                self.engine.errors.append(
                    f"gui_shell restore_panel place: {exc}"
                )
        return True

    # ----- right-click context menu (v3) -----

    def _show_context_menu(
        self,
        event: Any,
        target_kind: str,
        target_id: str,
    ) -> Optional[Any]:
        """Post a context menu at the cursor for a panel / sidebar /
        treeview-row target. SPEC-008.

        Items (in design-doc order):
        1. Archive — calls archive_panel(target) for panel targets;
           _archive_tab(target) for sidebar targets.
        2. Restore — only enabled if the target is currently archived.
        3. Copy module — calls copy_module_to_clipboard(target).
        4. Paste module — calls paste_module_from_clipboard().
        5. Lock / Unlock — toggle pair; label swaps based on is_locked.
        6. Properties — opens a small read-only Toplevel showing the
           panel handle dict.

        Returns the constructed Menu widget (for tests) or None if
        construction failed. The text-API test driver calls the
        underlying methods directly; this method is what the user-
        facing right-click actually invokes.
        """
        try:
            import tkinter as tk
        except Exception:
            return None
        if self.tk_root is None:
            return None
        menu = tk.Menu(self.tk_root, tearoff=0)

        # 1. Archive.
        if target_kind == "panel":
            menu.add_command(
                label="Archive panel",
                command=lambda: self.archive_panel(target_id),
            )
        elif target_kind == "sidebar":
            menu.add_command(
                label="Archive view",
                command=lambda: self._archive_tab(target_id),
            )
        else:
            menu.add_command(label="Archive", state="disabled")

        # 2. Restore — enabled only for archived targets.
        is_archived = False
        if target_kind == "panel":
            handle = self._panel_handles.get(target_id)
            is_archived = bool(handle and handle.archived)
        elif target_kind == "sidebar":
            is_archived = self.view_registry.is_archived(target_id)
        if is_archived:
            if target_kind == "panel":
                menu.add_command(
                    label="Restore panel",
                    command=lambda: self.restore_panel(target_id),
                )
            else:
                menu.add_command(
                    label="Restore view",
                    command=lambda: self.restore_view(target_id),
                )
        else:
            menu.add_command(label="Restore", state="disabled")

        # 3. Copy / 4. Paste — SPEC-073 wiring.
        menu.add_separator()
        menu.add_command(
            label="Copy module",
            command=lambda: self.copy_module_to_clipboard(target_id),
        )
        menu.add_command(
            label="Paste module",
            command=lambda: self.paste_module_from_clipboard(),
        )

        # 5. Lock / Unlock — only on panel targets.
        if target_kind == "panel":
            menu.add_separator()
            if self.is_locked(target_id):
                menu.add_command(
                    label="Unlock panel",
                    command=lambda: self.unlock_panel(target_id),
                )
            else:
                menu.add_command(
                    label="Lock panel",
                    command=lambda: self.lock_panel(target_id),
                )

        # 6. Properties — read-only Toplevel.
        menu.add_separator()
        menu.add_command(
            label="Properties",
            command=lambda: self._show_panel_properties(target_kind, target_id),
        )

        # Post the menu at the cursor. Wrapped in try/except so a
        # missing geometry from a synthesized event doesn't crash.
        try:
            menu.tk_popup(int(event.x_root), int(event.y_root))
        except Exception:
            pass
        finally:
            try:
                menu.grab_release()
            except Exception:
                pass
        return menu

    # ----- SPEC-075 Ctrl-right-click per-widget context menu -----

    def _show_widget_context_menu(
        self,
        event: Any,
        widget_id: str,
        widget_kind: str = "",
    ) -> Optional[Any]:
        """Post a Ctrl-right-click context menu for a non-panel
        lockable widget. SPEC-075 + SPEC-072 composition: the menu
        only opens when Ctrl is held at the moment of the right-click
        (the SPEC-072 modification-gate), keeping the default cursor
        state in consumption mode.

        The menu has two items: Lock / Unlock (toggle pair based on
        current state). Future iterations can add Properties, Reset
        position, etc.; v1 ships the minimum needed for SPEC-075's
        acceptance criterion.
        """
        if not self.ctrl_held:
            # Gate by Ctrl-held per SPEC-072. Non-Ctrl right-clicks on
            # lockable widgets fall through to whatever the widget's
            # default right-click handler is (e.g. context menus on
            # sidebar tabs already wired by _build_sidebar).
            return None
        try:
            import tkinter as tk
        except Exception:
            return None
        if self.tk_root is None:
            return None
        menu = tk.Menu(self.tk_root, tearoff=0)
        if self.is_widget_locked(widget_id):
            menu.add_command(
                label="Unlock",
                command=lambda: self.unlock_widget(widget_id),
            )
        else:
            menu.add_command(
                label="Lock",
                command=lambda: self.lock_widget(
                    widget_id, widget_kind=widget_kind
                ),
            )
        try:
            menu.tk_popup(int(event.x_root), int(event.y_root))
        except Exception:
            pass
        finally:
            try:
                menu.grab_release()
            except Exception:
                pass
        return menu

    def widget_context_menu_items(
        self,
        widget_id: str,
        widget_kind: str = "",
    ) -> List[str]:
        """Return the labels the Ctrl-right-click menu would surface
        for ``widget_id``. Public for tests: drives the menu without
        needing a real Tk popup. Returns the toggle label appropriate
        to the widget's current lock state.

        SPEC-075 acceptance: the menu offers exactly Lock / Unlock as
        a toggle pair (the spec's What-behavior list). Future iterations
        can extend; the v1 shape is two items.
        """
        if self.is_widget_locked(widget_id):
            return ["Unlock"]
        return ["Lock"]

    def context_menu_items(self, target_kind: str, target_id: str) -> List[str]:
        """Return the labels that the right-click menu would surface
        for ``(target_kind, target_id)``. Public for tests: the verbs
        gui_test_driver exposes drive the menu's actions, but tests
        also need to assert which items the menu offers (e.g. that
        "Unlock panel" appears when the target is locked).

        Each entry is one of: ``"Archive panel"``, ``"Archive view"``,
        ``"Restore panel"``, ``"Restore view"``, ``"Restore"`` (disabled
        placeholder), ``"Copy module"``, ``"Paste module"``,
        ``"Lock panel"``, ``"Unlock panel"``, ``"Properties"``.
        """
        items: List[str] = []
        # 1. Archive.
        if target_kind == "panel":
            items.append("Archive panel")
        elif target_kind == "sidebar":
            items.append("Archive view")
        else:
            items.append("Archive")
        # 2. Restore (enabled label vs disabled placeholder).
        is_archived = False
        if target_kind == "panel":
            handle = self._panel_handles.get(target_id)
            is_archived = bool(handle and handle.archived)
        elif target_kind == "sidebar":
            is_archived = self.view_registry.is_archived(target_id)
        if is_archived:
            items.append(
                "Restore panel" if target_kind == "panel" else "Restore view"
            )
        else:
            items.append("Restore")
        # 3 + 4. Copy + Paste.
        items.append("Copy module")
        items.append("Paste module")
        # 5. Lock / Unlock — panel only.
        if target_kind == "panel":
            items.append(
                "Unlock panel" if self.is_locked(target_id) else "Lock panel"
            )
        # 6. Properties.
        items.append("Properties")
        return items

    def _show_panel_properties(self, target_kind: str, target_id: str) -> Optional[Any]:
        """Open a small read-only Toplevel showing the panel handle.

        v1 read-only — the user can copy values out but can't edit.
        Returns the Toplevel for tests; None on construction failure
        or when called without a Tk root.
        """
        try:
            import tkinter as tk
        except Exception:
            return None
        if self.tk_root is None:
            return None
        win = tk.Toplevel(self.tk_root)
        win.title(f"Properties — {target_id}")
        win.geometry("320x220")
        win.configure(bg="#1c1f26")
        text = tk.Text(
            win, bg="#15171c", fg="#e8e8ec",
            font=("Helvetica", 10), relief="flat",
            wrap="word",
        )
        if target_kind == "panel":
            state = self.panel_state(target_id)
            content = "\n".join(f"{k}: {v}" for k, v in state.items())
        else:
            spec = self.view_registry.get(target_id)
            content = (
                f"name: {target_id}\n"
                f"kind: {getattr(spec, 'kind', '(unknown)')}\n"
                f"archived: {self.view_registry.is_archived(target_id)}"
            )
        text.insert("1.0", content or "(no state)")
        text.configure(state="disabled")
        text.pack(fill="both", expand=True, padx=12, pady=12)
        return win

    # ----- drag gesture handlers -----

    def _on_panel_drag_start(self, event: Any, panel_id: str) -> None:
        """Anchor a drag gesture on initial mouse press over a panel
        header. Stores the cursor origin + the current handle (x, y)
        so motion events compute deltas against the gesture anchor
        rather than the previous motion event.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None or handle.locked:
            self._panel_drag = None
            return
        try:
            anchor_x = int(event.x_root)
            anchor_y = int(event.y_root)
        except Exception:
            return
        self._panel_drag = {
            "kind": "move",
            "panel_id": panel_id,
            "anchor_x_root": anchor_x,
            "anchor_y_root": anchor_y,
            "origin_x": handle.x,
            "origin_y": handle.y,
        }

    def _on_panel_drag_motion(self, event: Any, panel_id: str) -> None:
        """Apply a drag delta to the panel's place() coordinates.

        Each motion event re-places the widget at the snapped delta
        from the gesture anchor; the handle is updated continuously
        so a release commits the final position.
        """
        if self._panel_drag is None or self._panel_drag.get("panel_id") != panel_id:
            return
        # In v2 the move + resize handlers share _panel_drag; tag the
        # gesture kind so the motion branches don't cross-process each
        # other's anchors.
        if self._panel_drag.get("kind", "move") != "move":
            return
        handle = self._panel_handles.get(panel_id)
        if handle is None or handle.locked:
            return
        try:
            cur_x = int(event.x_root)
            cur_y = int(event.y_root)
        except Exception:
            return
        delta_x = cur_x - self._panel_drag["anchor_x_root"]
        delta_y = cur_y - self._panel_drag["anchor_y_root"]
        new_x = snap_to_grid(self._panel_drag["origin_x"] + delta_x)
        new_y = snap_to_grid(self._panel_drag["origin_y"] + delta_y)
        handle.x = max(0, new_x)
        handle.y = max(0, new_y)
        widget = self._panel_widgets.get(panel_id)
        if widget is not None:
            try:
                widget.place(x=handle.x, y=handle.y,
                             width=handle.w, height=handle.h)
            except Exception:
                pass

    def _on_panel_drag_release(self, event: Any, panel_id: str) -> None:
        """Commit the drag — clears the gesture state. The handle
        already holds the final snapped position from the last motion
        event; no further mutation is required at release time.

        On release, snap-to-peer-edges runs (SPEC-007 v2). The cheap
        per-motion snap-to-grid keeps the panel grid-aligned during
        the gesture; the release pass also pulls the panel to align
        with peer panels' edges if they're within snap distance.
        """
        if self._panel_drag is not None and self._panel_drag.get("panel_id") == panel_id:
            self._apply_peer_snap(panel_id)
        self._panel_drag = None

    # ----- resize gesture handlers (v2) -----

    def _on_panel_resize_start(self, event: Any, panel_id: str) -> None:
        """Anchor a resize gesture on initial mouse press at the SE
        corner grip. Stores the cursor origin + the current handle
        (w, h) so motion events compute deltas against the gesture
        anchor.
        """
        handle = self._panel_handles.get(panel_id)
        if handle is None or handle.locked:
            self._panel_drag = None
            return
        try:
            anchor_x = int(event.x_root)
            anchor_y = int(event.y_root)
        except Exception:
            return
        # Re-use _panel_drag for both gesture kinds; the "kind" tag
        # distinguishes move from resize so a single release branch
        # can dispatch correctly.
        self._panel_drag = {
            "kind": "resize",
            "panel_id": panel_id,
            "anchor_x_root": anchor_x,
            "anchor_y_root": anchor_y,
            "origin_w": handle.w,
            "origin_h": handle.h,
        }

    def _on_panel_resize_motion(self, event: Any, panel_id: str) -> None:
        """Apply a resize delta to the panel's place() dimensions.

        Each motion event re-places the widget at the snapped delta
        from the gesture anchor; the handle is updated continuously
        so a release commits the final dimensions. Width and height
        clamp to a 48 px minimum.
        """
        if self._panel_drag is None or self._panel_drag.get("panel_id") != panel_id:
            return
        if self._panel_drag.get("kind") != "resize":
            return
        handle = self._panel_handles.get(panel_id)
        if handle is None or handle.locked:
            return
        try:
            cur_x = int(event.x_root)
            cur_y = int(event.y_root)
        except Exception:
            return
        delta_x = cur_x - self._panel_drag["anchor_x_root"]
        delta_y = cur_y - self._panel_drag["anchor_y_root"]
        new_w = snap_to_grid(self._panel_drag["origin_w"] + delta_x)
        new_h = snap_to_grid(self._panel_drag["origin_h"] + delta_y)
        handle.w = max(48, new_w)
        handle.h = max(48, new_h)
        widget = self._panel_widgets.get(panel_id)
        if widget is not None:
            try:
                widget.place(x=handle.x, y=handle.y,
                             width=handle.w, height=handle.h)
            except Exception:
                pass

    def _on_panel_resize_release(self, event: Any, panel_id: str) -> None:
        """Commit the resize — clears the gesture state. Like the
        move-release, this fires the peer-snap pass so the panel's
        new dimensions can also align to peer edges if close enough.
        """
        if self._panel_drag is not None and self._panel_drag.get("panel_id") == panel_id:
            self._apply_peer_snap(panel_id)
        self._panel_drag = None

    # ----- snap-to-edges (v2) -----

    def _compute_snap(
        self,
        panel: PanelHandle,
        peers: List[PanelHandle],
        snap_distance: int = SNAP_GRID_PX,
    ) -> Tuple[int, int]:
        """Compute the snapped (x, y) for ``panel`` given its peers.

        Snap math: for every peer P, four candidate alignments per
        axis. On the x-axis, P's left edge can snap against the
        panel's left or right edge (= P.x or P.x - panel.w), and
        P's right edge similarly (= P.x + P.w or P.x + P.w - panel.w).
        Each candidate is tested against the panel's current x; the
        candidate with the smallest delta (and delta <= snap_distance)
        wins. y-axis math is symmetric. x and y resolve independently
        — a panel can snap on one axis without snapping on the other.

        Public (under-prefixed but documented) for tests of the
        snap-math without driving the full drag gesture.
        """
        best_x = panel.x
        best_dx = snap_distance + 1
        best_y = panel.y
        best_dy = snap_distance + 1

        for peer in peers:
            if peer is panel:
                continue
            if peer.archived:
                continue
            # x-axis candidates: align this panel's left/right edge
            # to the peer's left/right edge.
            candidates_x = [
                peer.x,                          # left-left
                peer.x - panel.w,                # right-left
                peer.x + peer.w,                 # left-right
                peer.x + peer.w - panel.w,       # right-right
            ]
            for cand in candidates_x:
                dx = abs(cand - panel.x)
                if dx < best_dx:
                    best_dx = dx
                    best_x = cand
            # y-axis candidates.
            candidates_y = [
                peer.y,
                peer.y - panel.h,
                peer.y + peer.h,
                peer.y + peer.h - panel.h,
            ]
            for cand in candidates_y:
                dy = abs(cand - panel.y)
                if dy < best_dy:
                    best_dy = dy
                    best_y = cand

        # Resolve: keep best only if within snap distance. Independent
        # axes — one can snap without the other.
        snapped_x = best_x if best_dx <= snap_distance else panel.x
        snapped_y = best_y if best_dy <= snap_distance else panel.y
        # Clamp to >= 0 so the snap doesn't drag the panel offscreen.
        return max(0, snapped_x), max(0, snapped_y)

    def _apply_peer_snap(self, panel_id: str) -> None:
        """Run snap-to-edges against the panel's peers and commit the
        snapped position via move_panel (which re-places the widget).

        Called on drag/resize release so the per-motion grid-only
        snap stays cheap; the more expensive peer-edge scan only
        fires on commit.
        """
        target = self._panel_handles.get(panel_id)
        if target is None or target.locked:
            return
        peers = [
            handle for pid, handle in self._panel_handles.items()
            if pid != panel_id and not handle.archived
        ]
        if not peers:
            return
        snapped_x, snapped_y = self._compute_snap(target, peers)
        if snapped_x != target.x or snapped_y != target.y:
            # Bypass move_panel's snap-to-grid (we already have the
            # peer-snapped coordinates which may not be grid-aligned
            # if the peer's edges weren't). Directly update + re-place.
            target.x = snapped_x
            target.y = snapped_y
            widget = self._panel_widgets.get(panel_id)
            if widget is not None:
                try:
                    widget.place(x=target.x, y=target.y,
                                 width=target.w, height=target.h)
                except Exception:
                    pass

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

    # ----- web tab (SPEC-066) -----

    def _activate_web(self, spec: ViewSpec) -> None:
        """Pack a tkinterweb HtmlFrame into the central pane.

        Layout: a 1-row URL entry + Go/Refresh buttons at the top,
        the HtmlFrame filling the rest. Mirrors how _activate_3d
        embeds the realtime canvas — same teardown discipline (the
        widget is destroyed on tab switch because the panel host's
        children are cleared in _render_active_tab before this method
        runs).

        Degrades gracefully when tkinterweb isn't importable: a
        Label explains the missing dep and points at the install
        command. The shell stays usable; only the Browser tab is
        unavailable.
        """
        import tkinter as tk

        host = self._panel_host if self._panel_host is not None else self._central_frame

        # Probe import + instantiation before building the URL bar.
        try:
            from tkinterweb import HtmlFrame
        except Exception as exc:
            placeholder = tk.Label(
                host,
                text=(
                    "Browser unavailable: tkinterweb is not installed.\n"
                    "Install with: pip install \"tkinterweb>=4.25.2,<5\"\n"
                    f"({exc})"
                ),
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                justify="left",
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            return

        # URL bar.
        bar = tk.Frame(host, bg="#1c1f26")
        bar.pack(fill="x")

        initial_url = spec.url or ""
        url_var = tk.StringVar(value=initial_url)
        self._browser_url_var = url_var

        entry = tk.Entry(
            bar,
            textvariable=url_var,
            bg="#2a2d34",
            fg="#e8e8ec",
            insertbackground="#e8e8ec",
            relief="flat",
            font=("Helvetica", 10),
        )
        entry.pack(side="left", fill="x", expand=True, padx=(12, 4), pady=8)

        # HtmlFrame fills the rest of the central pane.
        try:
            frame = HtmlFrame(host, messages_enabled=False)
        except Exception as exc:
            placeholder = tk.Label(
                host,
                text=f"HtmlFrame instantiation failed: {exc}",
                bg="#2a2d34",
                fg="#c8ccd6",
                font=("Helvetica", 11),
                pady=24,
            )
            placeholder.pack(fill="both", expand=True)
            self._browser_frame = None
            return

        self._browser_frame = frame

        def _load_current() -> None:
            url = url_var.get().strip()
            try:
                if spec.html_string and url == initial_url:
                    # First load + inline HTML override beats URL.
                    frame.load_html(spec.html_string)
                elif url:
                    frame.load_url(url)
            except Exception as exc:
                self.engine.errors.append(
                    f"gui_shell browser load {url!r}: {exc}"
                )

        def _on_submit(_event=None) -> None:
            _load_current()

        def _on_refresh() -> None:
            _load_current()

        entry.bind("<Return>", _on_submit)

        go_btn = tk.Button(
            bar,
            text="Go",
            command=_on_submit,
            bg="#3b4254",
            fg="#e8e8ec",
            relief="flat",
            font=("Helvetica", 10, "bold"),
            padx=10,
            pady=2,
        )
        go_btn.pack(side="left", padx=(0, 4), pady=8)

        refresh_btn = tk.Button(
            bar,
            text="Refresh",
            command=_on_refresh,
            bg="#3b4254",
            fg="#e8e8ec",
            relief="flat",
            font=("Helvetica", 10),
            padx=10,
            pady=2,
        )
        refresh_btn.pack(side="left", padx=(0, 12), pady=8)

        frame.pack(fill="both", expand=True)

        # Trigger the initial load. Inline HTML wins over URL — the
        # explicit override beats the network fetch.
        if spec.html_string:
            try:
                frame.load_html(spec.html_string)
            except Exception as exc:
                self.engine.errors.append(
                    f"gui_shell browser load_html: {exc}"
                )
        elif initial_url:
            try:
                frame.load_url(initial_url)
            except Exception as exc:
                self.engine.errors.append(
                    f"gui_shell browser load_url {initial_url!r}: {exc}"
                )

    def browser_open(self, url: str) -> bool:
        """Programmatic URL load against the active Browser view.

        Returns True on success, False when the Browser tab isn't
        active or the HtmlFrame isn't constructed. Composes with the
        text-API ``browser-open`` verb so headless tests can drive a
        live HtmlFrame from text without keystroke synthesis.
        """
        frame = getattr(self, "_browser_frame", None)
        if frame is None:
            return False
        try:
            frame.load_url(url)
            if getattr(self, "_browser_url_var", None) is not None:
                self._browser_url_var.set(url)
        except Exception as exc:
            self.engine.errors.append(
                f"browser_open {url!r}: {exc}"
            )
            return False
        return True

    def browser_load_html(self, html: str) -> bool:
        """Programmatic HTML render against the active Browser view.

        Companion to ``browser_open`` for the inline-HTML path.
        """
        frame = getattr(self, "_browser_frame", None)
        if frame is None:
            return False
        try:
            frame.load_html(html)
        except Exception as exc:
            self.engine.errors.append(
                f"browser_load_html: {exc}"
            )
            return False
        return True

    def browser_current_url(self) -> Optional[str]:
        """Return the URL currently displayed in the Browser tab, or
        None when no Browser frame is active.
        """
        frame = getattr(self, "_browser_frame", None)
        if frame is None:
            return None
        url = getattr(frame, "current_url", None)
        if url is None:
            return None
        s = str(url).strip()
        return s or None

    # ----- actions + chat -----

    def _on_action(self, action: str, item: Dict[str, Any]) -> None:
        """Dispatch a per-item action.

        ``expand`` and ``collapse`` are local UI state — the central
        pane's body display toggles. ``target`` (SPEC-068) sets the
        clicked session as the active chat target. Every other
        action dispatches through ``engine.actions.dispatch_action``
        against the tab's renderer node-id, so trust mutations /
        file edits / etc. flow through the same code path the 3D
        surface uses.
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
        if action == "target":
            # SPEC-068 — clicking a row in the Chat or Sessions view
            # makes that session the active chat target. The session
            # id is in item['id'] for both view shapes.
            self.set_active_session(iid)
            return
        if action == "restore":
            # SPEC-008 — restore action on a row in the Archive view.
            # The item's meta carries (target_kind, target_id) so the
            # dispatch can route to the right restore method.
            meta = item.get("meta") or {}
            target_kind = meta.get("target_kind")
            target_id = meta.get("target_id")
            if target_kind == "view" and target_id:
                self.restore_view(target_id)
            elif target_kind == "panel" and target_id:
                self.restore_panel(target_id)
            # Refresh the Archive view so the restored row drops out.
            if self.tk_root is not None:
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

    # ----- SPEC-073 copy/paste-as-text -----

    def copy_module_to_clipboard(self, node_id: str) -> str:
        """Copy a node (and its sub-tree) to the system clipboard as
        JSON text. Returns the JSON string (also useful for tests
        that don't have a Tk root attached).

        SPEC-073: modules ARE text; Ctrl+C on a panel serializes its
        scene-JSON to the clipboard. Composes with SPEC-072 (Ctrl is
        the gate). Raises ``KeyError`` if ``node_id`` isn't spawned.
        """
        from tools.module_clipboard import serialize_module

        text = serialize_module(self.engine, node_id, include_subtree=True)
        if self.tk_root is not None:
            try:
                self.tk_root.clipboard_clear()
                self.tk_root.clipboard_append(text)
            except Exception as exc:
                self.engine.errors.append(f"gui_shell clipboard write: {exc}")
        return text

    def paste_module_from_clipboard(self, text: Optional[str] = None) -> List[str]:
        """Paste a module from the system clipboard (or from ``text``
        if supplied — useful for tests + the text-API).

        Returns the new node ids. Auto-renames on id collision so
        pasting the same Tasks panel twice produces
        ``task_panel_2``, ``task_panel_3``, etc. Raises
        ``ValueError`` on a malformed payload.
        """
        from tools.module_clipboard import paste_text_to_engine

        payload = text
        if payload is None and self.tk_root is not None:
            try:
                payload = self.tk_root.clipboard_get()
            except Exception as exc:
                raise ValueError(f"clipboard read failed: {exc}") from exc
        if payload is None:
            raise ValueError("no payload and no Tk root to read clipboard from")
        new_ids = paste_text_to_engine(self.engine, payload)
        # Refresh source caches so the central pane reflects any new
        # source nodes immediately.
        try:
            self.engine.precompute()
        except Exception as exc:
            self.engine.errors.append(f"gui_shell paste precompute: {exc}")
        if self.tk_root is not None and self.active_tab is not None:
            self._render_active_tab()
        return new_ids

    # ----- SPEC-068 chat routing -----

    def set_active_session(self, sid_or_name: str) -> Optional[str]:
        """Set the active chat target. Accepts an id OR a display_name.

        SPEC-068: clicking a row in the Chat or Sessions sidebar
        selects that session as the active target. Reactivates the
        session if it's archived so subsequent bare-text messages
        flow to it without a separate resume step. Returns the
        resolved session id, or None if no match.
        """
        sid = self._resolve_session_id(sid_or_name)
        if sid is None:
            return None
        self.active_session_id = sid
        # Reactivate if archived/idle so the next message lands cleanly.
        try:
            rec = self.sm.get(sid)
            if rec is not None and rec.status in ("archived", "idle"):
                self.sm.reactivate(sid)
        except Exception as exc:
            self.engine.errors.append(f"gui_shell reactivate: {exc}")
        # Re-render so the Chat view shows the new (active) marker.
        if self.tk_root is not None and self.active_tab in ("Chat", "Sessions"):
            self._render_active_tab()
        return sid

    def _resolve_session_id(self, sid_or_name: str) -> Optional[str]:
        """Look up a session by exact id, then by display_name, then
        by id-prefix (so the maintainer can type the first 8 chars
        of a UUID and have it resolve). Returns None if no match.

        Bug-fix 2026-05-20 (stress-test): the id-prefix branch now
        detects ambiguity. If two sessions share the supplied prefix,
        returns None (rather than silently picking the first listed).
        The caller surfaces the ambiguity to the maintainer via the
        existing "no session matched" error path.
        """
        if not sid_or_name:
            return None
        # Exact id match.
        try:
            rec = self.sm.get(sid_or_name)
        except Exception:
            rec = None
        if rec is not None:
            return rec.id
        # display_name match.
        try:
            for rec in self.sm.list():
                if rec.display_name == sid_or_name:
                    return rec.id
            # id-prefix match (≥4 chars to avoid false hits).
            if len(sid_or_name) >= 4:
                prefix_matches = [
                    rec.id for rec in self.sm.list()
                    if rec.id.startswith(sid_or_name)
                ]
                if len(prefix_matches) == 1:
                    return prefix_matches[0]
                if len(prefix_matches) > 1:
                    # Ambiguous prefix — log and return None so the
                    # caller surfaces the failure rather than silently
                    # picking the wrong session.
                    self.engine.errors.append(
                        f"_resolve_session_id: ambiguous prefix "
                        f"{sid_or_name!r}; matches {prefix_matches}"
                    )
                    return None
        except Exception:
            pass
        return None

    def route_chat(self, text: str) -> Dict[str, Any]:
        """Route a chat-submit body. Public for tests + the text-API.

        SPEC-068 acceptance:
        - Bare text → active session.
        - ``@<name> text`` → that session, reactivating if archived.
        - ``/all text`` → broadcast to every active session.
        - Empty / whitespace-only → no-op.

        Returns a dict describing the routing decision::

            {"routed": True, "target": <sid|"all"|None>,
             "delivered_to": [<sid>, ...],
             "message": <body_sent>,
             "reason": <human-readable note>}
        """
        text = (text or "").strip()
        if not text:
            return {
                "routed": False,
                "target": None,
                "delivered_to": [],
                "message": "",
                "reason": "empty body",
            }

        # /all broadcast (matches "/all body" or bare "/all").
        if text == "/all" or text.startswith("/all "):
            body = text[len("/all"):].strip()
            if not body:
                return {
                    "routed": False,
                    "target": "all",
                    "delivered_to": [],
                    "message": "",
                    "reason": "/all with empty body",
                }
            delivered: List[str] = []
            errors: List[str] = []
            try:
                records = list(self.sm.list())
            except Exception as exc:
                return {
                    "routed": False,
                    "target": "all",
                    "delivered_to": [],
                    "message": body,
                    "reason": f"sm.list failed: {exc}",
                }
            for rec in records:
                if rec.status == "archived":
                    continue  # skip archived in broadcast
                try:
                    self.sm.send(rec.id, body)
                    delivered.append(rec.id)
                except Exception as exc:
                    errors.append(f"{rec.id}: {exc}")
            return {
                "routed": True,
                "target": "all",
                "delivered_to": delivered,
                "message": body,
                "reason": (
                    f"broadcast to {len(delivered)} session(s)"
                    + (f"; errors: {errors}" if errors else "")
                ),
            }

        # @<name-or-id> routing.
        if text.startswith("@"):
            head, _, body = text[1:].partition(" ")
            head = head.strip()
            body = body.strip()
            if not head or not body:
                return {
                    "routed": False,
                    "target": head or None,
                    "delivered_to": [],
                    "message": body,
                    "reason": "@-prefix requires `@<name> <body>`",
                }
            sid = self._resolve_session_id(head)
            if sid is None:
                return {
                    "routed": False,
                    "target": head,
                    "delivered_to": [],
                    "message": body,
                    "reason": f"no session matched name/id {head!r}",
                }
            # Reactivate if archived.
            try:
                rec = self.sm.get(sid)
                if rec is not None and rec.status in ("archived", "idle"):
                    self.sm.reactivate(sid)
            except Exception as exc:
                self.engine.errors.append(f"gui_shell reactivate {sid}: {exc}")
            try:
                self.sm.send(sid, body)
            except Exception as exc:
                return {
                    "routed": False,
                    "target": sid,
                    "delivered_to": [],
                    "message": body,
                    "reason": f"send failed: {exc}",
                }
            return {
                "routed": True,
                "target": sid,
                "delivered_to": [sid],
                "message": body,
                "reason": f"routed via @-prefix to {sid}",
            }

        # Bare text → active session (SPEC-002).
        if self.active_session_id is None:
            return {
                "routed": False,
                "target": None,
                "delivered_to": [],
                "message": text,
                "reason": "no active session — open Chat tab to pick one",
            }
        try:
            self.sm.send(self.active_session_id, text)
        except Exception as exc:
            return {
                "routed": False,
                "target": self.active_session_id,
                "delivered_to": [],
                "message": text,
                "reason": f"send failed: {exc}",
            }
        return {
            "routed": True,
            "target": self.active_session_id,
            "delivered_to": [self.active_session_id],
            "message": text,
            "reason": f"routed to active session {self.active_session_id}",
        }

    def _on_chat_submit(self) -> None:
        if self._chat_entry is None:
            return
        text = self._chat_entry.get().strip()
        if not text:
            return
        self._chat_entry.delete(0, "end")
        result = self.route_chat(text)
        if not result.get("routed"):
            # Surface a hint by writing back into the chat input.
            reason = result.get("reason", "send failed")
            self._chat_entry.insert(0, f"({reason})")
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
