"""SceneMutator — runtime scene mutations as engine actions.

THE node that makes evolve-from-within work. Verbs map 1:1 onto the
Engine's SPEC-076 mutation surface:

  - ``spawn``     — wrap ``engine.spawn(node_id, type_name, params, connections)``
  - ``set_param`` — wrap ``engine.set_param(node_id, key, value)``
  - ``connect``   — wrap ``engine.connect(from_id, slot, to_id)``
  - ``disconnect`` — wrap ``engine.disconnect(from_id, slot)``

The maintainer's 2026-05-21 directive named this exact capability: a
node-based system where the user can *"add new nodes, move those around
freely"* from within the software. Before this node, scene mutation
required editing scenes/workflow_view.json by hand + reloading. After
this node, any surface (Tk button, Streamlit button, MCP-tool call
from the website) dispatches a single action and the engine mutates
the live graph — with full history emission per SPEC-076.

Result per verb lands in view-state under ``last_<verb>`` so callers
can read success/failure and node-ids without depending on engine
internals.

This node is the foundation for the 12-tool Apeiron MCP graph-ops
plugin filed in the handoff queue — each MCP tool wraps one
dispatch_action call against this node.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

import numpy as np

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="SceneMutator",
        version="1.0",
        renderer_id="logic",
        inputs={},
        outputs={},
        description=(
            "Runtime scene mutations: spawn/set_param/connect/disconnect. "
            "The primitive that makes evolve-from-within work — any "
            "surface or MCP-tool caller dispatches one action and the "
            "engine mutates the live graph."
        ),
    )


def build(params: Dict[str, Any]) -> Dict[str, Any]:
    return {}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }


def describe(state, ctx: EmitContext) -> str:
    return f"SceneMutator id={ctx.node.id}"


def handle_action(
    state: Dict[str, Any],
    action_name: str,
    payload: Dict[str, Any],
    engine: Any,
    node: Any,
) -> Optional[Dict[str, Any]]:
    if action_name == "spawn":
        node_id = (payload.get("node_id") or "").strip()
        type_name = (payload.get("type_name") or "").strip()
        if not node_id:
            return {"last_spawn": {"spawned": False, "reason": "empty node_id"}}
        if not type_name:
            return {"last_spawn": {"spawned": False, "node_id": node_id,
                                   "reason": "empty type_name"}}
        if node_id in engine.nodes:
            return {"last_spawn": {"spawned": False, "node_id": node_id,
                                   "reason": f"node {node_id!r} already exists"}}
        params = payload.get("params") or {}
        connections = payload.get("connections") or {}
        try:
            engine.spawn(node_id, type_name, params=params, connections=connections)
        except Exception as exc:
            return {"last_spawn": {"spawned": False, "node_id": node_id,
                                   "reason": f"spawn failed: {exc}"}}
        instance = engine.nodes.get(node_id)
        dead = instance.dead if instance is not None else True
        return {"last_spawn": {
            "spawned": not dead,
            "node_id": node_id,
            "type_name": type_name,
            "dead": dead,
            "reason": (instance.error if dead and instance else f"spawned {node_id} of type {type_name}"),
        }}

    if action_name == "set_param":
        node_id = payload.get("node_id") or ""
        key = payload.get("key") or ""
        value = payload.get("value")
        if not node_id or not key:
            return {"last_set_param": {"set": False,
                                       "reason": "node_id and key required"}}
        ok = engine.set_param(node_id, key, value)
        if not ok:
            return {"last_set_param": {"set": False, "node_id": node_id,
                                       "key": key,
                                       "reason": f"node {node_id!r} not found"}}
        return {"last_set_param": {"set": True, "node_id": node_id,
                                   "key": key, "value": value,
                                   "reason": f"{node_id}.{key} = {value!r}"}}

    if action_name == "connect":
        from_id = payload.get("from_id") or ""
        slot = payload.get("slot") or ""
        to_id = payload.get("to_id") or ""
        if not from_id or not slot or not to_id:
            return {"last_connect": {"connected": False,
                                     "reason": "from_id, slot, to_id required"}}
        ok = engine.connect(from_id, slot, to_id)
        if not ok:
            return {"last_connect": {"connected": False,
                                     "reason": f"from_id {from_id!r} not found"}}
        return {"last_connect": {
            "connected": True, "from_id": from_id, "slot": slot, "to_id": to_id,
            "reason": f"{from_id}.{slot} -> {to_id}",
        }}

    if action_name == "disconnect":
        from_id = payload.get("from_id") or ""
        slot = payload.get("slot") or ""
        if not from_id or not slot:
            return {"last_disconnect": {"disconnected": False,
                                        "reason": "from_id and slot required"}}
        ok = engine.disconnect(from_id, slot)
        if not ok:
            return {"last_disconnect": {"disconnected": False,
                                        "reason": (
                                            f"{from_id}.{slot} not connected "
                                            f"or {from_id!r} not found"
                                        )}}
        return {"last_disconnect": {"disconnected": True, "from_id": from_id,
                                    "slot": slot,
                                    "reason": f"unwired {from_id}.{slot}"}}

    if action_name == "list_nodes":
        nodes_info = []
        for nid, inst in engine.nodes.items():
            nodes_info.append({
                "id": nid,
                "type": inst.type_name,
                "dead": inst.dead,
                "connections": dict(inst.connections),
            })
        return {"last_list_nodes": nodes_info}

    if action_name == "list_types":
        return {"last_list_types": sorted(engine.types.keys())}

    return None
