"""
TextRenderer — the first-class bidirectional text-interaction surface.

Wraps a sub-graph and produces a text representation instead of pixels.
Reads each child node's describe() (or falls back to a default
description based on type and params) and assembles a structured text
output suitable for LLM consumption.

Also exposes a command_grammar() function listing the text commands an
LLM can issue against the wrapped sub-graph. The engine's tools layer
(tools/text_test.py) is what actually dispatches commands; this module
declares what commands are available.
"""

from typing import Any, Dict, List
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="TextRenderer",
        version="1.0",
        renderer_id="text",
        outputs={"text": "string"},
        description=(
            "Renders the wrapped sub-graph as structured text instead of pixels. "
            "Bidirectional — accepts text commands via the engine's tools layer. "
            "The first-class LLM-interaction surface for the engine."
        ),
    )


def build(params):
    return {
        "include_state": bool(params.get("include_state", True)),
        "include_topology": bool(params.get("include_topology", True)),
        "include_view": bool(params.get("include_view", True)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """
    Walk the wrapped sub-graph and produce a text description. The text
    appears under the "text" channel in the returned Channels dict.
    """
    lines: List[str] = []

    if state["include_view"]:
        lines.append("VIEW:")
        lines.append(f"  position={_fmt_vec(view.position)}")
        lines.append(f"  scale={view.scale:.3f}  size={view.width}x{view.height}")
        lines.append("")

    if state["include_topology"]:
        lines.append("SCENE:")
        lines.append(f"  rendered through TextRenderer id={ctx.node.id}")
        for conn_name, (child_node, _) in ctx.child_outputs.items():
            lines.append(f"  connection \"{conn_name}\" -> {child_node.type_name}#{child_node.id}")
            sub_desc = _describe_subtree(ctx.engine, child_node.id, indent="    ")
            if sub_desc:
                lines.extend(sub_desc.splitlines())
        lines.append("")

    if state["include_state"]:
        lines.append("OBSERVATIONS:")
        for _, (child_node, child_channels) in ctx.child_outputs.items():
            obs = _observe_child_channels(child_node, child_channels)
            if obs:
                lines.append(f"  {obs}")
        lines.append("")

    lines.append("COMMANDS AVAILABLE:")
    for cmd in command_grammar():
        lines.append(f"  {cmd}")

    return {"text": "\n".join(lines)}


def describe(state, ctx: EmitContext) -> str:
    return f"TextRenderer id={ctx.node.id} (wraps {len(ctx.node.connections)} child connection(s))"


def command_grammar() -> List[str]:
    """
    The text-command vocabulary an LLM can issue. The tools/text_test.py
    layer dispatches these. Adding a new command type means appending here
    and adding a handler in the dispatcher — no engine-core change.
    """
    return [
        "describe <node_id>             — return a one-line description of a node",
        "describe-subtree <node_id>     — return a structured description of a subtree",
        "list-types                     — list all registered node-types and renderers",
        "list-nodes                     — list all spawned node instances",
        "spawn <type> <id> [params]     — create a new node instance",
        "connect <from_id> <name> <to_id> — add a connection from one node to another",
        "move <dx> <dy> <dz>            — translate the viewer by a vector",
        "look-at <x> <y> <z>            — rotate the viewer to look at a world point",
        "render <root_id>               — render the current scene to a bundle",
        "render-text <root_id>          — render the current scene as text only",
    ]


# ---- helpers ----

def _describe_subtree(engine, node_id: str, indent: str = "  ") -> str:
    node = engine.nodes.get(node_id)
    if node is None:
        return f"{indent}<missing node {node_id}>"
    module = engine.types.get(node.type_name)
    if module and hasattr(module, "describe"):
        try:
            from engine.node import EmitContext
            ctx = EmitContext(engine=engine, node=node)
            line = module.describe(node.state, ctx)
        except Exception as e:
            line = f"{node.type_name}#{node.id} (describe failed: {e})"
    else:
        line = f"{node.type_name}#{node.id} params={node.params}"
    lines = [f"{indent}{line}"]
    for conn_name, conn in node.connections.items():
        target_id = conn if isinstance(conn, str) else (conn.get("target") if isinstance(conn, dict) else conn[0])
        lines.append(f"{indent}  -> {conn_name}:")
        lines.append(_describe_subtree(engine, target_id, indent + "    "))
    return "\n".join(lines)


def _observe_child_channels(node, channels: Channels) -> str:
    """Produce a short observation string from a child's emitted channels."""
    parts = [f"{node.type_name}#{node.id}:"]
    if "depth" in channels:
        import numpy as np
        d = channels["depth"]
        finite = d[np.isfinite(d)]
        if finite.size > 0:
            parts.append(f"visible (depth range [{float(finite.min()):.2f}, {float(finite.max()):.2f}])")
        else:
            parts.append("not visible")
    if "text" in channels and isinstance(channels["text"], str):
        parts.append("(emits text)")
    return " ".join(parts)


def _fmt_vec(v) -> str:
    return f"[{v[0]:.2f}, {v[1]:.2f}, {v[2]:.2f}]"
