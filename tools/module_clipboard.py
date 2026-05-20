"""
Module clipboard — SPEC-073 (copy/paste modules as text).

Modules ARE text (their node-JSON representation). Selecting any
panel and pressing Ctrl+C serializes its scene-JSON; pasting on any
surface that accepts modules instantiates the node from that text.
Pasting valid node-JSON from any external source (a chat message, a
file, another text editor) instantiates the same.

Maintainer directive (cockpit wish #11 sub-points 5+6, session
2575849f 2026-05-18) verbatim:

    "Right clicking buttons/pages is what allows them to be archived
    or allows me to bring them back to the main menu from the archive.
    Also, in general, I should be able to copy and paste a module from
    any place in the software to any other place in the software, and
    each page should have a default behavior for where pasted modules
    should go."

    "Since the entire system is text, copy and pasting modules is
    identical to copying and pasting their nodes, and therefore I can
    paste in new nodes from text all the same as copying and pasting
    nodes from within the system."

Composes with SPEC-027 (everything is a node), SPEC-072 (Ctrl is the
modification gate), SPEC-021 (hot-reload — pasting an unseen
type-name triggers the type registry to load it).

How serialization works
-----------------------

A serialized module is a JSON object::

    {
      "module": [
        {"id": "task_panel", "type": "ListRenderer", "params": {...},
         "connections": {"source": "tasks_source"}},
        ...
      ]
    }

The ``module`` array preserves order so child nodes can be listed
alongside their parent. Single-node modules use a one-element array.
Cross-module connections (a panel's ``source`` that points at a
node *not* in the snippet) are preserved as-is; if the target node
doesn't exist at paste time, the engine creates the panel with an
unresolved connection (the panel will render its placeholder until
the missing target lands).

ID-collision policy
-------------------

If a snippet's id already exists in the target engine, paste rewrites
the id to ``<original>_<n>`` (smallest n that doesn't collide). The
new id also propagates into any in-snippet connections that referenced
the original. This means pasting the same Tasks panel twice produces
``task_panel``, ``task_panel_2``, ``task_panel_3``, ... each with its
own copy of the snippet's internal connections.
"""

from __future__ import annotations

import copy
import json
from typing import Any, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Serialize.
# ---------------------------------------------------------------------------


def serialize_module(engine: Any, node_id: str, *, include_subtree: bool = True) -> str:
    """Serialize one node (optionally with its connected sub-tree) to
    JSON text suitable for the clipboard.

    Returns a JSON string in the ``{"module": [...]}`` shape so
    parsers can distinguish single-node vs multi-node payloads
    uniformly. Raises ``KeyError`` if the named node isn't spawned.
    """
    if node_id not in engine.nodes:
        raise KeyError(f"unknown node: {node_id}")
    seen: Dict[str, Dict[str, Any]] = {}
    order: List[str] = []

    def visit(nid: str) -> None:
        if nid in seen or nid not in engine.nodes:
            return
        node = engine.nodes[nid]
        seen[nid] = {
            "id": nid,
            "type": node.type_name,
            "params": dict(node.params or {}),
            "connections": copy.deepcopy(node.connections or {}),
        }
        order.append(nid)
        if include_subtree:
            for conn in (node.connections or {}).values():
                target_id = _conn_target_id(conn)
                if target_id and target_id != nid:
                    visit(target_id)

    visit(node_id)
    module = [seen[nid] for nid in order]
    return json.dumps({"module": module}, indent=2)


def _conn_target_id(conn: Any) -> Optional[str]:
    """Resolve a connection value to a target id. Mirrors
    engine.core._resolve_connection but returns None on unknowns
    rather than raising (a malformed connection in a serialized
    snippet must not crash the copy path)."""
    if isinstance(conn, str):
        return conn
    if isinstance(conn, dict):
        return conn.get("target")
    if isinstance(conn, list) and conn:
        return conn[0]
    return None


# ---------------------------------------------------------------------------
# Parse.
# ---------------------------------------------------------------------------


def parse_module(text: str) -> List[Dict[str, Any]]:
    """Parse a clipboard payload to a list of node dicts.

    Accepts three input shapes for robustness against ad-hoc paste
    sources:

    1. ``{"module": [{...}, {...}]}`` — canonical shape produced by
       ``serialize_module``.
    2. A single node dict: ``{"id": ..., "type": ..., ...}``.
    3. A bare list of node dicts: ``[{...}, {...}]``.

    Raises ``ValueError`` on a malformed payload (non-JSON, wrong
    structure, missing required fields).
    """
    if not text or not text.strip():
        raise ValueError("empty paste payload")
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ValueError(f"paste payload is not valid JSON: {exc}") from exc

    if isinstance(data, dict) and "module" in data:
        module = data["module"]
    elif isinstance(data, dict) and "id" in data and "type" in data:
        module = [data]
    elif isinstance(data, list):
        module = data
    else:
        raise ValueError(
            "paste payload must be {'module': [...]}, a single node dict, "
            "or a list of node dicts"
        )

    if not isinstance(module, list) or not module:
        raise ValueError("module must be a non-empty list of node dicts")

    for idx, n in enumerate(module):
        if not isinstance(n, dict):
            raise ValueError(f"module[{idx}] is not a dict")
        if "id" not in n or "type" not in n:
            raise ValueError(f"module[{idx}] missing required id / type")
    return module


# ---------------------------------------------------------------------------
# Instantiate (paste).
# ---------------------------------------------------------------------------


def instantiate_module(
    engine: Any,
    module: List[Dict[str, Any]],
    *,
    auto_rename: bool = True,
) -> List[str]:
    """Spawn every node in ``module`` into ``engine``.

    Returns the new ids (after auto-rename) in module order. The
    rename map is also applied to in-module connections so a snippet
    with internal references stays self-consistent after id
    rewriting.

    If ``auto_rename`` is False, collisions raise ``ValueError``
    instead of being auto-resolved. The default True is the safer
    paste behavior; callers wanting strict insertion (e.g. restoring
    an archived view) can opt out.
    """
    rename: Dict[str, str] = {}
    existing_ids = set(engine.nodes.keys())
    new_ids: List[str] = []

    # First pass: compute rename map.
    for n in module:
        original = n["id"]
        if original not in existing_ids and original not in rename.values():
            rename[original] = original
            continue
        if not auto_rename:
            raise ValueError(f"id collision on paste: {original!r}")
        # Find first non-colliding suffix.
        idx = 2
        while True:
            candidate = f"{original}_{idx}"
            if candidate not in existing_ids and candidate not in rename.values():
                rename[original] = candidate
                break
            idx += 1

    # Second pass: spawn with renamed ids + rewritten in-module
    # connection targets.
    for n in module:
        new_id = rename[n["id"]]
        params = dict(n.get("params", {}))
        connections = _rewrite_connections(n.get("connections", {}), rename)
        engine.spawn(
            node_id=new_id,
            type_name=n["type"],
            params=params,
            connections=connections,
        )
        new_ids.append(new_id)
    return new_ids


def _rewrite_connections(connections: Dict[str, Any], rename: Dict[str, str]) -> Dict[str, Any]:
    """Replace any target ids that appear in ``rename`` with their
    new ids; leave external targets (not in rename) untouched."""
    out: Dict[str, Any] = {}
    for key, conn in (connections or {}).items():
        if isinstance(conn, str):
            out[key] = rename.get(conn, conn)
        elif isinstance(conn, dict):
            new_conn = dict(conn)
            tgt = new_conn.get("target")
            if isinstance(tgt, str) and tgt in rename:
                new_conn["target"] = rename[tgt]
            out[key] = new_conn
        elif isinstance(conn, list) and conn:
            new_list = list(conn)
            if isinstance(new_list[0], str) and new_list[0] in rename:
                new_list[0] = rename[new_list[0]]
            out[key] = new_list
        else:
            out[key] = conn
    return out


# ---------------------------------------------------------------------------
# Top-level convenience.
# ---------------------------------------------------------------------------


def copy_node_to_text(engine: Any, node_id: str) -> str:
    """Convenience: serialize a single node (with sub-tree) to text.
    The two-step form (``serialize_module``) is preferred when the
    caller wants to control sub-tree inclusion."""
    return serialize_module(engine, node_id, include_subtree=True)


def paste_text_to_engine(engine: Any, text: str) -> List[str]:
    """Convenience: parse + instantiate in one call. Returns the
    new node ids."""
    module = parse_module(text)
    return instantiate_module(engine, module, auto_rename=True)


__all__ = [
    "serialize_module",
    "parse_module",
    "instantiate_module",
    "copy_node_to_text",
    "paste_text_to_engine",
]
