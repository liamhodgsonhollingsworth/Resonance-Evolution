"""PanelPositioner — surface-independent snap/move/resize/lock math.

Lift #6 of the chat_router architectural arc. Before this node, all
panel positioning math lived on ``tools/workflow_gui/gui_shell.py``
(Tk surface only): ``move_panel``, ``resize_panel``, ``_compute_snap``,
``_apply_peer_snap``, plus the ``PanelHandle`` dataclass + ``WidgetLock``
registry. The maintainer's 2026-05-21 directive named the cost — the
Streamlit and (future) HTML / website surfaces could not honor
*"resize windows, which was already developed separately"* without
copying the math.

After this node: any surface dispatches ``move``/``resize``/``snap``
against ``panel_positioner_main`` and reads the resolved coordinates
back. Tk keeps ``widget.place(x, y, w, h)`` as a thin Tk-aware
wrapper; Streamlit reads the same coordinates to drive its own
layout; the HTML surface (planned) and Apeiron's MCP graph-ops
plugin do likewise.

Verbs:
  - ``register``   — declare a new panel (idempotent)
  - ``move``       — relocate; snap-to-grid; locked refuses
  - ``resize``     — w/h with 48-px minimum + grid snap; locked refuses
  - ``lock`` / ``unlock`` — flip the lock flag
  - ``archive`` / ``unarchive`` — archived panels are skipped by snap
  - ``snap_to_peers`` — peer-edge snap; commits new position
  - ``get_state``  — return one panel's record
  - ``list``       — return all panels

State shape (per ``engine.cache["__view_state__"][node.id]``):

    {
      "panels": {
        "<panel_id>": {"x": int, "y": int, "w": int, "h": int,
                       "locked": bool, "archived": bool},
        ...
      },
      "last_move":   {"panel_id": ..., "moved": bool, "x": ..., "y": ...},
      "last_resize": {"panel_id": ..., "resized": bool, "w": ..., "h": ...},
      "last_snap":   {"panel_id": ..., "snapped": bool, "x": ..., "y": ...},
      ...
    }

Snap-to-grid is configurable via build params (``snap_grid_px``,
default 12). Minimum size and peer-snap distance follow the same
convention — every surface gets the same values without duplicating
the constants.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


DEFAULT_SNAP_GRID_PX = 12
DEFAULT_MIN_SIZE_PX = 48


def manifest() -> Manifest:
    return Manifest(
        name="PanelPositioner",
        version="1.0",
        renderer_id="logic",
        inputs={
            "snap_grid_px": "int",
            "min_size_px": "int",
            "peer_snap_distance": "int",
        },
        outputs={},
        description=(
            "Surface-independent snap/move/resize/lock math. Any "
            "surface dispatches positioning verbs against this node "
            "and reads the resolved coordinates back."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    snap_grid_px = int(params.get("snap_grid_px") or DEFAULT_SNAP_GRID_PX)
    min_size_px = int(params.get("min_size_px") or DEFAULT_MIN_SIZE_PX)
    peer_snap_distance = int(
        params.get("peer_snap_distance") or snap_grid_px
    )
    return {
        "snap_grid_px": snap_grid_px,
        "min_size_px": min_size_px,
        "peer_snap_distance": peer_snap_distance,
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return (
        f"PanelPositioner id={ctx.node.id} "
        f"grid={state.get('snap_grid_px')} "
        f"min={state.get('min_size_px')}"
    )


def _snap_to_grid(value: int, grid: int) -> int:
    """Round ``value`` to the nearest ``grid`` multiple. Negative
    values round toward 0 so a slight overshoot past the top-left
    clamps to (0, 0) rather than (-grid, -grid).
    """
    if grid <= 0:
        return int(value)
    return int(round(value / grid) * grid)


def _compute_peer_snap(
    panel: Dict[str, Any],
    peers: List[Dict[str, Any]],
    snap_distance: int,
) -> Tuple[int, int, bool, bool]:
    """Return ``(snapped_x, snapped_y, snapped_x_flag, snapped_y_flag)``.

    For each peer, four candidate alignments per axis: align this
    panel's left/right edge to the peer's left/right edge. Each
    candidate is tested against the panel's current x; the smallest
    delta within ``snap_distance`` wins. x and y resolve independently.
    """
    px, py = int(panel["x"]), int(panel["y"])
    pw, ph = int(panel["w"]), int(panel["h"])

    best_x, best_dx = px, snap_distance + 1
    best_y, best_dy = py, snap_distance + 1

    for peer in peers:
        if peer.get("archived"):
            continue
        ex, ey = int(peer["x"]), int(peer["y"])
        ew, eh = int(peer["w"]), int(peer["h"])
        for cand in (ex, ex - pw, ex + ew, ex + ew - pw):
            dx = abs(cand - px)
            if dx < best_dx:
                best_dx = dx
                best_x = cand
        for cand in (ey, ey - ph, ey + eh, ey + eh - ph):
            dy = abs(cand - py)
            if dy < best_dy:
                best_dy = dy
                best_y = cand

    snapped_x_flag = best_dx <= snap_distance
    snapped_y_flag = best_dy <= snap_distance
    snapped_x = best_x if snapped_x_flag else px
    snapped_y = best_y if snapped_y_flag else py
    return max(0, snapped_x), max(0, snapped_y), snapped_x_flag, snapped_y_flag


def _view(engine: Any, node_id: str) -> Dict[str, Any]:
    """Return the live view-state slot for this node, creating it on
    first access. Mirrors session_target's pattern.
    """
    return engine.cache.setdefault("__view_state__", {}).setdefault(node_id, {})


def _panels(view: Dict[str, Any]) -> Dict[str, Dict[str, Any]]:
    """Return the live panels dict inside view-state."""
    return view.setdefault("panels", {})


def _ensure_panel(
    view: Dict[str, Any], panel_id: str, default_w: int, default_h: int
) -> Dict[str, Any]:
    """Insert-or-fetch the per-panel record. Mirrors
    ``_ensure_panel_handle`` from gui_shell.
    """
    panels = _panels(view)
    rec = panels.get(panel_id)
    if rec is None:
        rec = {
            "x": 0, "y": 0,
            "w": default_w, "h": default_h,
            "locked": False, "archived": False,
        }
        panels[panel_id] = rec
    return rec


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    grid = int(state.get("snap_grid_px") or DEFAULT_SNAP_GRID_PX)
    min_size = int(state.get("min_size_px") or DEFAULT_MIN_SIZE_PX)
    peer_dist = int(state.get("peer_snap_distance") or grid)
    view = _view(engine, node.id)

    if action_name == "register":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_register": {"registered": False, "reason": "empty panel_id"}}
        x = int(payload.get("x", 0))
        y = int(payload.get("y", 0))
        w = int(payload.get("w", 480))
        h = int(payload.get("h", 320))
        rec = _ensure_panel(view, panel_id, default_w=w, default_h=h)
        rec["x"], rec["y"] = _snap_to_grid(x, grid), _snap_to_grid(y, grid)
        rec["w"] = max(min_size, _snap_to_grid(w, grid))
        rec["h"] = max(min_size, _snap_to_grid(h, grid))
        return {
            "panels": _panels(view),
            "last_register": {
                "registered": True, "panel_id": panel_id,
                "x": rec["x"], "y": rec["y"], "w": rec["w"], "h": rec["h"],
            },
        }

    if action_name == "move":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_move": {"moved": False, "reason": "empty panel_id"}}
        rec = _ensure_panel(view, panel_id, default_w=480, default_h=320)
        if rec.get("locked"):
            return {"last_move": {
                "moved": False, "panel_id": panel_id,
                "x": rec["x"], "y": rec["y"],
                "reason": f"panel {panel_id!r} is locked",
            }}
        try:
            x = int(payload.get("x", rec["x"]))
            y = int(payload.get("y", rec["y"]))
        except (TypeError, ValueError):
            return {"last_move": {"moved": False, "panel_id": panel_id,
                                  "reason": "x and y must be ints"}}
        rec["x"] = _snap_to_grid(x, grid)
        rec["y"] = _snap_to_grid(y, grid)
        return {
            "panels": _panels(view),
            "last_move": {
                "moved": True, "panel_id": panel_id,
                "x": rec["x"], "y": rec["y"],
            },
        }

    if action_name == "resize":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_resize": {"resized": False, "reason": "empty panel_id"}}
        rec = _ensure_panel(view, panel_id, default_w=480, default_h=320)
        if rec.get("locked"):
            return {"last_resize": {
                "resized": False, "panel_id": panel_id,
                "w": rec["w"], "h": rec["h"],
                "reason": f"panel {panel_id!r} is locked",
            }}
        try:
            w = int(payload.get("w", rec["w"]))
            h = int(payload.get("h", rec["h"]))
        except (TypeError, ValueError):
            return {"last_resize": {"resized": False, "panel_id": panel_id,
                                    "reason": "w and h must be ints"}}
        rec["w"] = max(min_size, _snap_to_grid(w, grid))
        rec["h"] = max(min_size, _snap_to_grid(h, grid))
        return {
            "panels": _panels(view),
            "last_resize": {
                "resized": True, "panel_id": panel_id,
                "w": rec["w"], "h": rec["h"],
            },
        }

    if action_name == "lock":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_lock": {"locked": False, "reason": "empty panel_id"}}
        rec = _ensure_panel(view, panel_id, default_w=480, default_h=320)
        rec["locked"] = True
        return {"panels": _panels(view),
                "last_lock": {"locked": True, "panel_id": panel_id}}

    if action_name == "unlock":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_unlock": {"unlocked": False, "reason": "empty panel_id"}}
        rec = _ensure_panel(view, panel_id, default_w=480, default_h=320)
        rec["locked"] = False
        return {"panels": _panels(view),
                "last_unlock": {"unlocked": True, "panel_id": panel_id}}

    if action_name == "archive":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_archive": {"archived": False, "reason": "empty panel_id"}}
        rec = _ensure_panel(view, panel_id, default_w=480, default_h=320)
        rec["archived"] = True
        return {"panels": _panels(view),
                "last_archive": {"archived": True, "panel_id": panel_id}}

    if action_name == "unarchive":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_unarchive": {"unarchived": False, "reason": "empty panel_id"}}
        rec = _ensure_panel(view, panel_id, default_w=480, default_h=320)
        rec["archived"] = False
        return {"panels": _panels(view),
                "last_unarchive": {"unarchived": True, "panel_id": panel_id}}

    if action_name == "snap_to_peers":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_snap": {"snapped": False, "reason": "empty panel_id"}}
        panels = _panels(view)
        target = panels.get(panel_id)
        if target is None:
            return {"last_snap": {"snapped": False, "panel_id": panel_id,
                                  "reason": f"panel {panel_id!r} not registered"}}
        if target.get("locked"):
            return {"last_snap": {"snapped": False, "panel_id": panel_id,
                                  "x": target["x"], "y": target["y"],
                                  "reason": f"panel {panel_id!r} is locked"}}
        peers = [rec for pid, rec in panels.items()
                 if pid != panel_id and not rec.get("archived")]
        if not peers:
            return {"last_snap": {"snapped": False, "panel_id": panel_id,
                                  "x": target["x"], "y": target["y"],
                                  "reason": "no peers"}}
        snap_dist = int(payload.get("snap_distance", peer_dist))
        new_x, new_y, sx, sy = _compute_peer_snap(target, peers, snap_dist)
        target["x"] = new_x
        target["y"] = new_y
        return {
            "panels": panels,
            "last_snap": {
                "snapped": bool(sx or sy), "panel_id": panel_id,
                "x": new_x, "y": new_y,
                "snapped_x": sx, "snapped_y": sy,
            },
        }

    if action_name == "get_state":
        panel_id = (payload.get("panel_id") or "").strip()
        if not panel_id:
            return {"last_get_state": {}}
        rec = _panels(view).get(panel_id)
        return {"last_get_state": dict(rec) if rec is not None else {}}

    if action_name == "list":
        panels = _panels(view)
        out = []
        for pid in sorted(panels):
            rec = panels[pid]
            out.append({"panel_id": pid, **rec})
        return {"last_list": out}

    return None
