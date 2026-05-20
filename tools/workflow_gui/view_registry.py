"""
View registry — SPEC-067 (view-as-menu navigation).

Every "alternative collection of nodes" the maintainer can navigate to
in the workflow surface is a *view*. The registry holds the declarative
spec for each view (display name, data shape, hover description); the
GUI shell renders those specs as sidebar tabs; the text-API ``set-view``
command swaps the active one.

Why this module exists. The first 2D GUI shell (SPEC-065) hardcoded a
TABS list of 8 entries. Every new surface — Logs, Settings, Browser
(SPEC-066), Image / Logo editor (SPEC-071), Active Sessions
(SPEC-079), etc. — would have meant another row in that list and
another conditional in ``select_tab``. The architectural commitment is
broader: *"the software should treat every single alternative collection
of nodes as a menu that can be reached from within the software"*
(maintainer directive 2026-05-20). The registry generalizes the
hardcoded tab list so adding a new view is one config row.

ViewSpec carries everything the GUI shell needs to render a tab plus
everything the text-API needs to swap to it. Backward compatibility
with the old TABS-tuple shape is preserved via ``ViewRegistry.as_tabs``
which materializes the registry into the ``(name, source_id, panel_id)``
tuples ``gui_shell._tabs`` consumed in Arc K.

Kinds
-----

A view's ``kind`` determines how the central pane renders it:

- ``"source"`` — read items from ``engine.cache[source_id]``; render as
  the standard ListRenderer panel. Per-item actions dispatch through
  ``engine.actions.dispatch_action(panel_id, ...)``.
- ``"gui_inbox"`` — render the workflow shell's main inbox (data lives
  in the GUI layer, not the engine cache).
- ``"gui_chat"`` — render the SessionManager's active sessions.
- ``"3d"`` — activate the embedded realtime renderer.
- ``"text"`` — render a fixed text/markdown body (Logs, Help, About).
- ``"custom"`` — caller-supplied renderer callback. Reserved for future
  one-off views (image editor, browser embed); not used in v1.

Adding a new view
-----------------

Two paths:

1. Append a ``ViewSpec(...)`` to ``default_view_registry()``. Single
   file edit; the sidebar grows a new tab on next launch.

2. Programmatic at startup. Construct a custom ``ViewRegistry``, pass
   it as ``GuiShell(view_registry=...)``. Plugins / extensions register
   views without touching shell code.

Both paths preserve the SPEC-067 acceptance criterion: *every view is
reachable from every other view via the same primitive.*
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# View specification.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class ViewSpec:
    """Declarative spec for one view.

    Frozen so ``ViewRegistry`` can share spec instances across callers
    without surprise mutation. To "edit" a view, register a fresh spec
    over the existing entry — the registry replaces the prior spec
    while preserving its position in the display order.
    """

    name: str
    """Display name shown as the sidebar tab label. Unique per registry."""

    kind: str
    """One of: ``source``, ``gui_inbox``, ``gui_chat``, ``3d``, ``text``,
    ``custom``. Controls how the central pane renders this view."""

    source_id: Optional[str] = None
    """For ``source`` kind: the engine source node-id whose
    ``engine.cache[source_id]['items']`` list backs the panel."""

    panel_id: Optional[str] = None
    """For ``source`` kind: the renderer node-id that handles per-item
    actions via ``engine.actions.dispatch_action``."""

    description: str = ""
    """Long-form description shown as the Ctrl-hover help tooltip
    (SPEC-074). Empty string ⇒ tooltip falls back to ``name``."""

    scene_root: Optional[str] = None
    """For ``3d`` kind: the scene root node-id the realtime renderer
    walks. ``None`` ⇒ the shell falls back to the active scene's root
    set at launch time."""

    text_body: str = ""
    """For ``text`` kind: a fixed body rendered in the central pane.
    Markdown-ish (rendered as plain text in v1; SPEC-069's visual
    contract polish can upgrade to rich-text later)."""

    custom_renderer: Optional[Callable[..., None]] = None
    """For ``custom`` kind: a callback taking ``(shell, central_frame)``
    that owns rendering the central pane. Reserved; not used in v1."""

    items_provider: Optional[Callable[..., List[Dict[str, Any]]]] = None
    """For ``dynamic`` kind: a callback taking ``(engine)`` that
    returns the items list rendered as the standard list panel.
    Lets the registry surface live data (active sessions, file
    watcher recent events, server status, ...) without subclassing
    the shell."""


# ---------------------------------------------------------------------------
# Registry.
# ---------------------------------------------------------------------------


class ViewRegistry:
    """Ordered map of view names to ``ViewSpec`` with archive/restore.

    Insertion order is the display order. Archiving a view hides it
    from ``list_views`` and ``as_tabs`` but preserves the spec so a
    later ``restore`` can bring it back at its original position
    (relative to the still-visible views) without re-declaring the
    spec.

    The registry is the GUI-shell's source of truth for the sidebar.
    The shell attaches the registry to ``engine.view_registry`` so the
    text-API ``set-view`` command can consult the same data without
    importing GUI modules.
    """

    def __init__(self) -> None:
        self._specs: Dict[str, ViewSpec] = {}
        self._order: List[str] = []
        self._archived: List[str] = []

    # ----- registration -----

    def register(self, spec: ViewSpec) -> None:
        """Register or replace a view spec. Replace preserves order.

        Raises ``ValueError`` if ``spec.kind`` is not one of the
        recognized kinds — catches typos at construction time rather
        than mysteriously rendering nothing in the central pane.
        """
        VALID_KINDS = {"source", "gui_inbox", "gui_chat", "3d", "text", "custom", "dynamic"}
        if spec.kind not in VALID_KINDS:
            raise ValueError(
                f"ViewSpec.kind must be one of {sorted(VALID_KINDS)}; "
                f"got {spec.kind!r} for view {spec.name!r}"
            )
        if spec.name not in self._specs:
            self._order.append(spec.name)
        self._specs[spec.name] = spec

    def unregister(self, name: str) -> bool:
        """Remove a view from the registry entirely.

        Returns True if the name existed. Use this when a view should
        permanently disappear (vs. ``archive`` which is recoverable).
        """
        if name not in self._specs:
            return False
        del self._specs[name]
        if name in self._order:
            self._order.remove(name)
        if name in self._archived:
            self._archived.remove(name)
        return True

    # ----- reads -----

    def get(self, name: str) -> Optional[ViewSpec]:
        """Return the spec for ``name`` if registered (visible OR archived)."""
        return self._specs.get(name)

    def names(self) -> List[str]:
        """Display order of visible views (archived views excluded)."""
        return [n for n in self._order if n not in self._archived]

    def archived_names(self) -> List[str]:
        """Names of archived views in archive order."""
        return list(self._archived)

    def list_views(self) -> List[ViewSpec]:
        """Specs of all visible views in display order."""
        return [self._specs[n] for n in self.names()]

    def all_views(self) -> List[ViewSpec]:
        """Specs of every registered view (visible + archived) in
        registration order. Useful for "manage views" surfaces that
        need to show archived items too."""
        return [self._specs[n] for n in self._order]

    def __len__(self) -> int:
        return len(self.names())

    def __contains__(self, name: object) -> bool:
        return isinstance(name, str) and name in self._specs

    # ----- archive / restore -----

    def archive(self, name: str) -> bool:
        """Hide a view from ``list_views``. Returns True if archived.

        No-op (returns False) if the view doesn't exist or is already
        archived. Preserves the spec; ``restore(name)`` brings it back.
        """
        if name not in self._specs or name in self._archived:
            return False
        self._archived.append(name)
        return True

    def restore(self, name: str) -> bool:
        """Restore a previously-archived view. Returns True on success."""
        if name not in self._archived:
            return False
        self._archived.remove(name)
        return True

    def is_archived(self, name: str) -> bool:
        return name in self._archived

    # ----- backward-compat shim -----

    def as_tabs(self) -> List[Tuple[str, str, Optional[str]]]:
        """Materialize the registry into the legacy
        ``(name, source_id, panel_id)`` tuples ``gui_shell._tabs``
        consumed in Arc K. Non-source kinds use sentinel markers
        (``_inbox``, ``_chat``, ``_3d``, ``_text:<view>``,
        ``_custom:<view>``) so the existing rendering switch in
        ``items_for_tab`` continues to work without refactoring every
        consumer in one pass.
        """
        out: List[Tuple[str, str, Optional[str]]] = []
        for spec in self.list_views():
            if spec.kind == "source":
                out.append((spec.name, spec.source_id or "", spec.panel_id))
            elif spec.kind == "gui_inbox":
                out.append((spec.name, "_inbox", None))
            elif spec.kind == "gui_chat":
                out.append((spec.name, "_chat", None))
            elif spec.kind == "3d":
                out.append((spec.name, "_3d", None))
            elif spec.kind == "text":
                out.append((spec.name, f"_text:{spec.name}", None))
            elif spec.kind == "custom":
                out.append((spec.name, f"_custom:{spec.name}", None))
            elif spec.kind == "dynamic":
                out.append((spec.name, f"_dynamic:{spec.name}", None))
        return out

    def help_map(self) -> Dict[str, str]:
        """Map view-name to Ctrl-hover help text (SPEC-074)."""
        return {
            spec.name: spec.description or spec.name
            for spec in self.list_views()
        }


# ---------------------------------------------------------------------------
# Default registry — the Arc K sidebar contents, plus Logs (built-in
# demonstration of one-config-away view extension).
# ---------------------------------------------------------------------------


def default_view_registry() -> ViewRegistry:
    """The default sidebar contents.

    Identical to Arc K's TABS catalog plus a Logs view backed by
    ``engine.errors`` to demonstrate that adding a view through the
    registry is one config row.
    """
    reg = ViewRegistry()
    for spec in (
        ViewSpec(
            name="Tasks",
            kind="source",
            source_id="tasks_source",
            panel_id="task_panel",
            description=(
                "Tasks panel — read from tasks.md via FileSource. "
                "Ctrl+click archives; Ctrl+drag resizes all toolbar modules together."
            ),
        ),
        ViewSpec(
            name="Ideas",
            kind="source",
            source_id="ideas_source",
            panel_id="idea_panel",
            description=(
                "Ideas panel — Alethea ideas via MCPSource. "
                "Ctrl+click archives; Ctrl+drag resizes all toolbar modules together."
            ),
        ),
        ViewSpec(
            name="Wishlist",
            kind="source",
            source_id="wishes_source",
            panel_id="wish_panel",
            description=(
                "Wishlist panel — wishlist.md via FileSource. "
                "Ctrl+click archives; Ctrl+drag resizes all toolbar modules."
            ),
        ),
        ViewSpec(
            name="Inbox",
            kind="gui_inbox",
            description=(
                "Main inbox messages from trusted senders. "
                "Ctrl+click archives; Ctrl+drag resizes all toolbar modules."
            ),
        ),
        ViewSpec(
            name="Chat",
            kind="gui_chat",
            description=(
                "Active Claude Code sessions; click a row to set as active chat target. "
                "Ctrl+drag resizes all toolbar modules."
            ),
        ),
        ViewSpec(
            name="Quarantine",
            kind="source",
            source_id="quarantine_source",
            panel_id="quarantine_panel",
            description=(
                "Untrusted messages awaiting promote/delete. "
                "Ctrl+click archives; Ctrl+drag resizes all toolbar modules."
            ),
        ),
        ViewSpec(
            name="Trusted Senders",
            kind="source",
            source_id="trusted_senders_source",
            panel_id="trusted_senders_panel",
            description=(
                "Trusted-sender set with revoke/delete actions. "
                "Ctrl+drag resizes all toolbar modules."
            ),
        ),
        ViewSpec(
            name="3D",
            kind="3d",
            description=(
                "Realtime renderer embedded into the central pane. "
                "Ctrl+drag resizes all toolbar modules; Esc inside the 3D view toggles WorkflowView mode."
            ),
        ),
        ViewSpec(
            name="Logs",
            kind="text",
            description=(
                "Engine errors + recent file-watcher events. Read-only diagnostics. "
                "Demonstrates SPEC-067: a new view is one ViewSpec row."
            ),
            text_body="",  # populated dynamically at render time
        ),
        ViewSpec(
            name="Sessions",
            kind="dynamic",
            description=(
                "All active Claude Code sessions on this machine (SPEC-079). "
                "Heartbeat-backed registry; entries older than 10 min are hidden."
            ),
            items_provider=_active_sessions_items_provider,
        ),
    ):
        reg.register(spec)
    return reg


def _active_sessions_items_provider(engine: Any) -> List[Dict[str, Any]]:
    """Items provider for the SPEC-079 Sessions view.

    Imported lazily so the registry doesn't pull in active_sessions at
    import time (and so a test stubbing the registry doesn't need to
    stub the active-sessions module too).
    """
    try:
        from tools.active_sessions import list_active_sessions
    except Exception as exc:
        return [
            {
                "id": "sessions-import-error",
                "title": f"(failed to import tools.active_sessions: {exc})",
                "body": str(exc),
                "status": "alert",
                "actions": ["expand"],
            }
        ]
    # Discover state dir from the engine if it carries one (the
    # production shell attaches it), else fall back to ./state.
    state_dir = getattr(engine, "active_sessions_state_dir", None)
    sessions = list_active_sessions(state_dir=state_dir)
    if not sessions:
        return [
            {
                "id": "sessions-empty",
                "title": "(no active sessions registered)",
                "body": (
                    "Sessions register themselves at startup via "
                    "tools.active_sessions.register_session(). Empty "
                    "list means no session has heart-beat in the past "
                    "10 minutes."
                ),
                "status": "ok",
                "actions": ["expand"],
            }
        ]
    out: List[Dict[str, Any]] = []
    for s in sessions:
        out.append(
            {
                "id": s.id,
                "title": (
                    f"{s.session_type}  project={s.project}  "
                    f"focus={s.focus or '(none)'}"
                ),
                "body": (
                    f"id={s.id}\n"
                    f"project={s.project}\n"
                    f"session_type={s.session_type}\n"
                    f"focus={s.focus}\n"
                    f"last_seen={s.last_seen}\n"
                    f"started_at={s.started_at}\n"
                    f"pid={s.pid}\n"
                    f"cwd={s.cwd}"
                ),
                "status": "alert" if s.is_stale else "in_progress",
                "actions": ["expand"],
                "meta": {"session_id": s.id, "project": s.project},
            }
        )
    return out


__all__ = [
    "ViewSpec",
    "ViewRegistry",
    "default_view_registry",
]
