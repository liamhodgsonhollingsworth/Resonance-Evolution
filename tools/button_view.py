"""
Derived-view button-row + connections for SPEC-076.

The "Author / History / Connections" row on every node-instance is NOT
implemented by spawning three real ButtonNodes per node (that's the 4x
``engine.nodes`` explosion the design rejects). Instead the row is
computed on demand by :func:`button_row_for`, which returns a list of
``ButtonSpec`` records: the three implicit standards first, then any
maintainer-added ButtonNode instances whose ``params.parent`` matches.

Connections are similarly derived — :func:`connections_for` walks
``engine.nodes`` once and returns the in-edges + out-edges for a focused
node-id. The result is shaped so a downstream ``ViewSpec(kind="dynamic",
items_provider=...)`` consumer can render one row per edge with no
special-case knowledge of the underlying graph.

Composes with:

- SPEC-077 ButtonNode: customizations are real nodes, surfaced through
  this builder alongside the implicit standards.
- SPEC-067 ViewRegistry: the GUI shell registers a Connections view
  whose ``items_provider`` calls :func:`connections_for`; the History
  view's provider calls :func:`tools.node_history.read_node_history`.
- SPEC-027 everything-is-a-node: maintainer-customizations of the
  standards are themselves ButtonNodes (set ``standard=True``).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


@dataclass
class ButtonSpec:
    """A render-time button entry.

    ``button_id`` is set ONLY for entries backed by a real ButtonNode
    in ``engine.nodes`` (i.e. customizations + maintainer-supplied
    standard overrides). The three implicit standards (Author /
    History / Connections) leave ``button_id`` empty — clicking them
    invokes the corresponding action against the parent node directly
    via :func:`dispatch_standard`.
    """

    label: str
    action: str
    target: str = ""
    icon: str = ""
    parent: str = ""
    button_id: str = ""
    standard: bool = False
    order: int = 0
    payload: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "label": self.label,
            "action": self.action,
            "target": self.target,
            "icon": self.icon,
            "parent": self.parent,
            "button_id": self.button_id,
            "standard": self.standard,
            "order": self.order,
            "payload": dict(self.payload),
        }


# Implicit-standard registry. Per the design §3, in v1 these are
# derived-only. Maintainer-customization is via spawning a ButtonNode
# with ``standard=True`` and matching ``action`` — the row-builder
# suppresses the implicit entry when a real one shadows it.
_STANDARDS = (
    ("Author", "show-author", "author"),
    ("History", "show-history", "clock-rewind"),
    ("Connections", "show-connections", "graph"),
)


def button_row_for(engine: Any, node_id: str) -> List[ButtonSpec]:
    """Return the full button row for ``node_id``.

    Layout: each implicit standard FIRST, in design order (Author then
    History then Connections), unless a real ButtonNode with
    ``standard=True`` and a matching ``action`` exists for the node —
    that customization replaces the implicit entry. Maintainer-added
    customizations (``standard=False``) follow, sorted by their
    ``order`` field with ties broken by id.

    Buttons whose ``hidden=True`` are filtered out before return so
    the design's "suppress standard" idiom (a hidden standard-override)
    works without renderer changes.
    """
    customizations: List[ButtonSpec] = []
    standard_overrides: Dict[str, ButtonSpec] = {}

    for nid, node in engine.nodes.items():
        if node.type_name != "ButtonNode":
            continue
        if node.dead:
            continue
        state = node.state or {}
        if state.get("parent") != node_id:
            continue
        spec = _spec_from_button_node(nid, state)
        if state.get("hidden"):
            # Hidden customization. Only honour it for standard overrides
            # (so the implicit entry suppresses), not for regular
            # customizations (a hidden regular button just disappears).
            if state.get("standard"):
                standard_overrides[state.get("action", "")] = spec
            continue
        if state.get("standard"):
            standard_overrides[state.get("action", "")] = spec
        else:
            customizations.append(spec)

    customizations.sort(key=lambda s: (s.order, s.button_id))

    row: List[ButtonSpec] = []
    for label, action, icon in _STANDARDS:
        override = standard_overrides.get(action)
        if override is not None:
            if override.label == "" and override.icon == "":
                # An empty override is the design's "suppress" pattern.
                continue
            # Honour any hidden flag on the override itself.
            real_node = engine.nodes.get(override.button_id)
            if real_node is not None:
                real_state = real_node.state or {}
                if real_state.get("hidden"):
                    continue
            row.append(override)
        else:
            row.append(
                ButtonSpec(
                    label=label,
                    action=action,
                    target=f"node:{node_id}",
                    icon=icon,
                    parent=node_id,
                    standard=True,
                )
            )
    row.extend(customizations)
    return row


def _spec_from_button_node(button_id: str, state: Dict[str, Any]) -> ButtonSpec:
    return ButtonSpec(
        label=str(state.get("label", "")),
        action=str(state.get("action", "")),
        target=str(state.get("target", "")),
        icon=str(state.get("icon", "")),
        parent=str(state.get("parent", "")),
        button_id=button_id,
        standard=bool(state.get("standard", False)),
        order=int(state.get("order", 0)),
        payload=dict(state.get("payload", {}) or {}),
    )


# ---------------------------------------------------------------------------
# Connections derived-view (SPEC-076 §7).
# ---------------------------------------------------------------------------


def connections_for(engine: Any, node_id: str) -> Dict[str, List[Dict[str, Any]]]:
    """Return the focused node's neighborhood.

    Output shape::

        {
            "out": [
                {"slot": "source", "target_id": "tasks_source"},
                ...
            ],
            "in": [
                {"from_id": "workflow_view", "slot": "panel_a"},
                ...
            ],
        }

    Out-edges come from ``node.connections``; in-edges are derived by
    walking every other node and checking whose connections point at
    ``node_id``. The walk is O(N * average-fanout); for the largest
    workflow scene to date that's still well under a millisecond.
    """
    node = engine.nodes.get(node_id)
    out_edges: List[Dict[str, Any]] = []
    in_edges: List[Dict[str, Any]] = []
    if node is None:
        return {"out": out_edges, "in": in_edges}

    for slot, conn in (node.connections or {}).items():
        target_id = _conn_target(conn)
        if target_id:
            out_edges.append({"slot": slot, "target_id": target_id})

    for other_id, other in engine.nodes.items():
        if other_id == node_id:
            continue
        for slot, conn in (other.connections or {}).items():
            if _conn_target(conn) == node_id:
                in_edges.append({"from_id": other_id, "slot": slot})

    return {"out": out_edges, "in": in_edges}


def _conn_target(conn: Any) -> str:
    """Decode the engine's polymorphic connection shape to a target id."""
    if isinstance(conn, str):
        return conn
    if isinstance(conn, dict):
        return conn.get("target", "")
    if isinstance(conn, list) and conn:
        return conn[0]
    return ""


# ---------------------------------------------------------------------------
# Standard-action dispatch (Author / History / Connections).
# ---------------------------------------------------------------------------


def dispatch_standard(
    engine: Any,
    node_id: str,
    action: str,
) -> Dict[str, Any]:
    """Compute the response for one of the three implicit standards.

    The standards are pure read operations — they don't mutate
    ``engine.cache`` or trigger ``handle_action``. The GUI shell
    reads the returned dict and renders a side-panel view; the text-API
    surfaces the same dict for testing.

    Recognised actions:

    - ``show-author`` -> ``{"type": "author", "summary": "<one-line>"}``
      The author summary is the node's ``params.author`` field when
      present, else the node's ``type_name`` plus its id (i.e.
      "no explicit author recorded; derived from type+id").
    - ``show-history`` -> ``{"type": "history", "rows": [...]}``
      The newest-first parsed history rows. Reads from
      ``state/node_history/<node-id>.jsonl`` via
      :func:`tools.node_history.read_node_history`.
    - ``show-connections`` -> ``{"type": "connections", "edges": {...}}``
      The in-edges + out-edges from :func:`connections_for`.

    Unknown actions return ``{"type": "unknown", "action": action}``.
    """
    if action == "show-author":
        node = engine.nodes.get(node_id)
        if node is None:
            return {"type": "author", "summary": f"(no node {node_id!r})"}
        author = (node.params or {}).get("author")
        if author:
            summary = f"author: {author}"
        else:
            summary = f"derived from type={node.type_name!r} id={node_id!r}"
        return {"type": "author", "node_id": node_id, "summary": summary}
    if action == "show-history":
        from tools.node_history import read_node_history
        rows = read_node_history(engine.root_dir, node_id, engine=engine)
        return {"type": "history", "node_id": node_id, "rows": rows}
    if action == "show-connections":
        edges = connections_for(engine, node_id)
        return {"type": "connections", "node_id": node_id, "edges": edges}
    return {"type": "unknown", "action": action}


def buttons_attached_to(engine: Any, node_id: str) -> List[str]:
    """Return the ids of every real ButtonNode whose parent is ``node_id``.

    Used by the ``node-buttons`` text-API verb to list customizations
    without computing the full derived row.
    """
    out: List[str] = []
    for nid, node in engine.nodes.items():
        if node.type_name != "ButtonNode":
            continue
        if node.dead:
            continue
        state = node.state or {}
        if state.get("parent") == node_id:
            out.append(nid)
    return out
