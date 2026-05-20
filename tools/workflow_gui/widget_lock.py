"""
WidgetLock — generic per-affordance lock registry (SPEC-075).

SPEC-007 introduced a panel-level lock — a boolean on each PanelHandle
that prevented drag and resize. SPEC-075 generalizes that lock to ANY
visible affordance: icons, buttons, individual frames, screen regions.
A maintainer who wants the Send button pinned to a corner while the
rest of the chat bar reflows freely names that exact pattern.

The implementation is a registry of widget-ids to lock-state. The
registry is the single source of truth; ``PanelHandle.locked`` delegates
through a property so panel-level lock state ALSO lives here. One
``WidgetLock`` instance lives on the ``GuiShell`` and is consulted by
every drag handler, every right-click context menu, and every text-API
verb that needs to know whether a widget is locked.

Why a registry instead of a flag per widget. Two reasons:

1. SPEC-075 commits to "anything visible can be locked." The set of
   lockable widgets is open-ended (icons, buttons, frames, screen
   regions, even text spans in the future); a registry handles new
   widget types without each one needing its own lock attribute.

2. SPEC-007's PanelHandle-as-source-of-truth design caused subtle
   duplication when other surfaces (sidebar buttons, future toolbar
   items) needed lock state. The registry centralizes that — a single
   ``is_widget_locked(widget_id)`` answers for ANY widget kind.

The class is deliberately small: a dict + helpers. The frozen-position
field is reserved for the v2 layout-resistance feature (locked widgets
that survive a parent reflow); v1 ships with the lock flag alone so the
text-API verbs round-trip end-to-end while the layout-side composition
lands in a follow-up.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple


@dataclass
class LockEntry:
    """Per-widget lock state.

    ``locked`` is the live flag the drag handlers and context menu read.
    ``frozen_position`` (x, y) is the cached screen coordinate at the
    moment of locking — reserved for the v2 layout-resistance feature
    where a locked widget anchors itself even as its parent reflows.
    v1 records the snapshot but doesn't yet act on it; tests assert the
    snapshot is captured so the v2 path lands without a registry change.
    """

    widget_id: str
    locked: bool = False
    frozen_position: Optional[Tuple[int, int]] = None
    # Optional widget-kind tag so the text-API ``list-locked-widgets``
    # verb can group by kind (panel / button / icon / region). Default
    # is empty string for backward-compat with the panel-only callers.
    widget_kind: str = ""


class WidgetLock:
    """Per-widget lock registry (SPEC-075).

    One instance lives on the ``GuiShell``. Drag handlers consult
    ``is_widget_locked(widget_id)`` before mutating position; the
    right-click context menu reads + writes via ``lock_widget`` /
    ``unlock_widget``. The text-API exposes the same surface so
    headless callers can verify the registry without a Tk window.

    The registry is INSERT-ON-FIRST-USE: calling ``lock_widget`` on
    an unseen id creates a LockEntry rather than failing. This mirrors
    SPEC-007's ``_ensure_panel_handle`` semantic — the act of locking
    is itself the registration.
    """

    def __init__(self) -> None:
        self._entries: Dict[str, LockEntry] = {}

    # ----- core API -----

    def lock_widget(
        self,
        widget_id: str,
        *,
        position: Optional[Tuple[int, int]] = None,
        widget_kind: str = "",
    ) -> bool:
        """Lock the widget. Returns True. Creates a registry entry if
        absent. ``position``, when supplied, is recorded as the
        frozen-position snapshot for v2 layout-resistance. ``widget_kind``
        is a free-form tag (``"panel"``, ``"button"``, ``"icon"``, etc.)
        used by ``list_locked_widgets`` for grouping.
        """
        entry = self._entries.get(widget_id)
        if entry is None:
            entry = LockEntry(widget_id=widget_id)
            self._entries[widget_id] = entry
        entry.locked = True
        if position is not None:
            entry.frozen_position = (int(position[0]), int(position[1]))
        if widget_kind:
            entry.widget_kind = widget_kind
        return True

    def unlock_widget(self, widget_id: str) -> bool:
        """Unlock the widget. Returns True if an entry existed and was
        unlocked; False if no entry exists.

        Idempotent: unlocking an already-unlocked widget returns True.
        Unlocking does NOT remove the entry — the frozen-position
        snapshot stays so a subsequent re-lock can restore it. The
        registry is monotonic in entries; only the ``locked`` flag
        flips.
        """
        entry = self._entries.get(widget_id)
        if entry is None:
            return False
        entry.locked = False
        return True

    def is_widget_locked(self, widget_id: str) -> bool:
        """Return True if a registry entry exists AND is locked.

        Unknown widgets are treated as unlocked — the default state for
        widgets that haven't yet been touched by a lock operation. This
        means drag handlers that consult this method default to
        permissive (drag allowed) when the widget hasn't been
        registered, matching the SPEC-007 behavior pre-WidgetLock.
        """
        entry = self._entries.get(widget_id)
        return bool(entry and entry.locked)

    def widget_state(self, widget_id: str) -> Dict[str, object]:
        """Return the lock entry as a plain dict for the text-API
        ``widget-lock-state`` verb. Returns an empty dict when no entry
        exists yet (matches the SPEC-007 ``panel_state`` convention).
        """
        entry = self._entries.get(widget_id)
        if entry is None:
            return {}
        return {
            "widget_id": entry.widget_id,
            "locked": entry.locked,
            "frozen_position": entry.frozen_position,
            "widget_kind": entry.widget_kind,
        }

    def list_locked_widgets(self) -> List[Dict[str, object]]:
        """Return the registry's currently-locked entries as a list of
        plain dicts, sorted by widget_id for deterministic test
        assertions. Unlocked entries (including those that have been
        unlocked but retain a frozen-position snapshot) are omitted.
        """
        out: List[Dict[str, object]] = []
        for widget_id in sorted(self._entries):
            entry = self._entries[widget_id]
            if not entry.locked:
                continue
            out.append(
                {
                    "widget_id": entry.widget_id,
                    "locked": entry.locked,
                    "frozen_position": entry.frozen_position,
                    "widget_kind": entry.widget_kind,
                }
            )
        return out

    def all_widgets(self) -> List[Dict[str, object]]:
        """Return every registry entry (locked and unlocked) for
        diagnostics + tests. Like ``list_locked_widgets`` but includes
        unlocked entries that retain frozen-position snapshots.
        """
        out: List[Dict[str, object]] = []
        for widget_id in sorted(self._entries):
            entry = self._entries[widget_id]
            out.append(
                {
                    "widget_id": entry.widget_id,
                    "locked": entry.locked,
                    "frozen_position": entry.frozen_position,
                    "widget_kind": entry.widget_kind,
                }
            )
        return out

    # ----- registry maintenance -----

    def register(
        self,
        widget_id: str,
        *,
        widget_kind: str = "",
    ) -> LockEntry:
        """Pre-register a widget without locking it. Useful for the
        widget-construction code paths in ``gui_shell.py`` that want to
        announce a lockable widget at build time so list-locked-widgets
        can return a complete unlocked-also view if asked. Returns the
        entry (existing or newly created).
        """
        entry = self._entries.get(widget_id)
        if entry is None:
            entry = LockEntry(widget_id=widget_id, widget_kind=widget_kind)
            self._entries[widget_id] = entry
        elif widget_kind and not entry.widget_kind:
            entry.widget_kind = widget_kind
        return entry

    def __contains__(self, widget_id: str) -> bool:
        return widget_id in self._entries

    def __len__(self) -> int:
        return len(self._entries)
