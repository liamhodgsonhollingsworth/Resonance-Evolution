"""
Inverse-pass infrastructure.

When the viewer mutates a generator-produced node, the engine asks the
nearest Generator ancestor's invert_hook for a parameter delta that "would
have generated" the new content. The delta is applied to the connected
Seed, and the affected sub-graph re-precomputes.

This is the dual of precompute: precompute_hook produces content from a
seed; invert_hook updates the seed from a content edit. Both are
node-module functions discovered by name — the engine dispatches without
knowing what either does.

Why "nearest Generator ancestor" rather than walking arbitrarily: because
the seed-to-content map is local to a Generator. A Generator's invert
hook is the authoritative inverse over its own outputs; further up the
graph is some other generator over different content.

API:
    engine.invert_edit(node_id, edit) -> bool
        Find nearest Generator ancestor of node_id, call its invert_hook
        with the edit, apply the returned param_delta to the Seed, and
        re-trigger precompute for the affected sub-graph. Returns True if
        an ancestor handled the edit; False if no Generator on the path.

Modules expose:
    invert_hook(state, edit, engine, node) -> param_delta | None
        Returns a dict of parameter deltas to apply to the connected
        Seed, or None if the edit cannot be inverted (e.g. would produce
        an inconsistent generator state).
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.core import Engine


def invert_edit(engine: "Engine", node_id: str, edit: Dict[str, Any]) -> bool:
    """
    Walk up the graph from node_id looking for a Generator (or any node
    whose module exposes invert_hook). Call the first one found.
    """
    ancestor_id = _nearest_inverting_ancestor(engine, node_id)
    if ancestor_id is None:
        return False

    node = engine.nodes[ancestor_id]
    module = engine.types.get(node.type_name)
    if module is None or not hasattr(module, "invert_hook"):
        return False

    try:
        delta = module.invert_hook(node.state, edit, engine, node)
    except Exception as e:
        engine.errors.append(f"invert_hook({ancestor_id}): {e}")
        return False

    if not delta:
        return False

    # Apply delta to the connected Seed (by convention, the connection
    # named "seed" on the Generator points at it).
    seed_conn = node.connections.get("seed")
    if seed_conn is None:
        return False
    seed_id = seed_conn if isinstance(seed_conn, str) else seed_conn.get("target")
    seed_node = engine.nodes.get(seed_id)
    if seed_node is None or seed_node.dead:
        return False

    # Apply delta to seed state.
    if isinstance(seed_node.state, dict):
        for k, v in delta.items():
            seed_node.state[k] = v
    else:
        # Non-dict state: replace if delta is a full state, otherwise skip.
        if isinstance(delta, dict) and "__replace__" in delta:
            seed_node.state = delta["__replace__"]

    # Trigger sub-graph re-precompute: call the Generator's precompute_hook
    # again so it regenerates against the updated seed. Tools/callers that
    # want a fuller rebuild may call engine.precompute() themselves.
    if hasattr(module, "precompute_hook"):
        try:
            engine.cache[ancestor_id] = module.precompute_hook(node.state, engine, node)
        except Exception as e:
            engine.errors.append(f"re-precompute({ancestor_id}): {e}")
            return False
    return True


def _nearest_inverting_ancestor(engine: "Engine", node_id: str) -> Optional[str]:
    """
    Find the nearest node that exposes invert_hook, starting from
    node_id itself and walking parents (incoming connections) breadth-first.

    Checking node_id first matters when callers pass a Generator id
    directly (editing the generator's output as a whole rather than
    editing one descendant); without this the API only worked when
    walking from a deeper-than-generator child.
    """
    parents_of = _build_parent_index(engine)
    seen = set()
    frontier: List[str] = [node_id]
    while frontier:
        candidate = frontier.pop(0)
        if candidate in seen:
            continue
        seen.add(candidate)
        node = engine.nodes.get(candidate)
        if node is None:
            continue
        module = engine.types.get(node.type_name)
        if module is not None and hasattr(module, "invert_hook"):
            return candidate
        frontier.extend(p for p in parents_of.get(candidate, []) if p not in seen)
    return None


def _build_parent_index(engine: "Engine") -> Dict[str, List[str]]:
    """For each node, list the nodes whose connections point to it."""
    parents: Dict[str, List[str]] = {}
    for nid, node in engine.nodes.items():
        for conn in node.connections.values():
            if isinstance(conn, str):
                target = conn
            elif isinstance(conn, dict):
                target = conn.get("target")
            elif isinstance(conn, list) and conn:
                target = conn[0]
            else:
                continue
            if target:
                parents.setdefault(target, []).append(nid)
    return parents
