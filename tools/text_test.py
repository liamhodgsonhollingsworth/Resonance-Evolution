"""
Text-based testing tools. The LLM-facing surface for verifying engine
behavior without opening rendered images.

The principle: once the visual renderers are confirmed working, an LLM
can build and verify new features using only the text outputs here and
trust that what works for text also works for visuals — because the
graph is the same. This decouples functionality verification from human
visual confirmation.

Functions:
    describe_scene(engine, root_id)
        Returns a structured text description of the entire scene below
        root_id, walking the graph via each node-type's describe().

    describe_view(engine, root_id, view)
        Renders the scene through the TextRenderer at the given view and
        returns the text channel. The same path an LLM would use to
        observe the world.

    summarize_bundle(bundle_dir)
        Reads a written bundle directory and returns a text summary
        (color statistics, depth range, ID histogram). For regression
        testing against expected scene state.

    dispatch_command(engine, command_text)
        Parses and applies a text command from the TextRenderer's
        command_grammar(). Returns a text result. Adding new command
        types: extend _COMMANDS below.

    assert_visible(engine, root_id, view, type_name)
        Returns True if a node of the given type contributes any visible
        pixel from the given view. Useful for assertions in tests.

All functions accept the engine and return strings or booleans — no
images, no GUI, no human-in-the-loop. Composable from CLI, REPL, or
sub-session.
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import numpy as np

from engine import Engine, View, look_at
from engine.node import EmitContext


# ---------------------------------------------------------------------------
# Observation functions
# ---------------------------------------------------------------------------

def describe_scene(engine: Engine, root_id: str) -> str:
    """Walk the graph from root_id; produce a structured text description."""
    lines: List[str] = [f"SCENE rooted at {root_id}:"]
    _walk_describe(engine, root_id, lines, indent="  ", visited=set())
    return "\n".join(lines)


def _walk_describe(engine: Engine, node_id: str, lines: List[str], indent: str, visited: set) -> None:
    if node_id in visited:
        lines.append(f"{indent}<cycle back to {node_id}>")
        return
    visited.add(node_id)
    node = engine.nodes.get(node_id)
    if node is None:
        lines.append(f"{indent}<missing {node_id}>")
        return
    module = engine.types.get(node.type_name)
    if module and hasattr(module, "describe"):
        try:
            line = module.describe(node.state, EmitContext(engine=engine, node=node))
        except Exception as e:
            line = f"{node.type_name}#{node.id} (describe failed: {e})"
    else:
        line = f"{node.type_name}#{node.id} params={node.params}"
    lines.append(f"{indent}{line}")
    if node.dead:
        lines.append(f"{indent}  [DEAD: {node.error.splitlines()[0] if node.error else 'unknown'}]")
    for conn_name, conn in node.connections.items():
        target_id = _conn_target(conn)
        lines.append(f"{indent}  -> {conn_name}:")
        _walk_describe(engine, target_id, lines, indent + "    ", visited)


def describe_view(engine: Engine, root_id: str, view: View) -> str:
    """
    Render the scene at root_id through a TextRenderer wrapper at view.
    If the scene's root already IS a TextRenderer, render it directly.
    """
    root = engine.nodes.get(root_id)
    if root and root.type_name == "TextRenderer":
        channels = engine.assemble(root_id, view)
        return str(channels.get("text", "(no text channel produced)"))

    # Wrap the scene in an ad-hoc TextRenderer
    wrap_id = f"_text_wrap_{root_id}"
    if wrap_id not in engine.nodes:
        engine.spawn(
            node_id=wrap_id,
            type_name="TextRenderer",
            params={"include_state": True, "include_topology": True, "include_view": True},
            connections={"scene": root_id},
        )
    channels = engine.assemble(wrap_id, view)
    return str(channels.get("text", "(no text channel produced)"))


def summarize_bundle(bundle_dir: Path) -> str:
    """Read a written bundle and produce a text summary for regression checking."""
    bundle_dir = Path(bundle_dir)
    manifest_path = bundle_dir / "manifest.json"
    if not manifest_path.exists():
        return f"BUNDLE {bundle_dir}: no manifest.json (not a bundle?)"
    manifest = json.loads(manifest_path.read_text())
    lines: List[str] = [f"BUNDLE {bundle_dir.name}:"]
    for name, ref in manifest.get("channels", {}).items():
        if isinstance(ref, str) and ref.endswith(".png"):
            try:
                from PIL import Image
                img = Image.open(bundle_dir / ref)
                arr = np.asarray(img)
                lines.append(f"  channel '{name}': shape={arr.shape} dtype={arr.dtype} "
                             f"mean={float(arr.mean()):.2f}")
            except Exception as e:
                lines.append(f"  channel '{name}': PNG at {ref} (read failed: {e})")
        elif isinstance(ref, str) and ref.endswith(".npy"):
            try:
                arr = np.load(bundle_dir / ref)
                if arr.dtype.kind in "fc":
                    finite = arr[np.isfinite(arr)]
                    if finite.size > 0:
                        lines.append(f"  channel '{name}': shape={arr.shape} dtype={arr.dtype} "
                                     f"range=[{float(finite.min()):.2f}, {float(finite.max()):.2f}]")
                    else:
                        lines.append(f"  channel '{name}': shape={arr.shape} dtype={arr.dtype} (no finite values)")
                else:
                    unique = np.unique(arr)
                    lines.append(f"  channel '{name}': shape={arr.shape} dtype={arr.dtype} "
                                 f"unique={len(unique)} values")
            except Exception as e:
                lines.append(f"  channel '{name}': npy at {ref} (read failed: {e})")
        elif isinstance(ref, str):
            lines.append(f"  channel '{name}': {ref!r}")
        else:
            lines.append(f"  channel '{name}': inline value type {type(ref).__name__}")
    if "view" in manifest:
        lines.append(f"  view: position={manifest['view']['position']} "
                     f"scale={manifest['view']['scale']} "
                     f"{manifest['view']['width']}x{manifest['view']['height']}")
    return "\n".join(lines)


def assert_visible(engine: Engine, root_id: str, view: View, type_name: str) -> bool:
    """
    Returns True if a node of type_name contributes a visible pixel from view.
    Uses the ids channel if present (faster); falls back to walking children.
    """
    channels = engine.assemble(root_id, view)
    ids = channels.get("ids")
    if ids is not None:
        # Find which node-ids appear in the rendered output
        present_hashes = set(int(h) for h in np.unique(ids) if int(h) != 0)
        for node in engine.nodes.values():
            if node.type_name == type_name:
                hash_value = node.state.get("node_id_hash") if isinstance(node.state, dict) else None
                if hash_value in present_hashes:
                    return True
        return False
    # Fallback: check depth range
    depth = channels.get("depth")
    if depth is None:
        return False
    return bool(np.any(np.isfinite(depth)))


# ---------------------------------------------------------------------------
# Command dispatcher
# ---------------------------------------------------------------------------

def dispatch_command(engine: Engine, command_text: str, view: View = None) -> Tuple[str, View]:
    """
    Parse and execute a text command from the TextRenderer's grammar.
    Returns (result_text, possibly_updated_view).

    Adding new commands: append a handler to _COMMANDS below. The handler
    signature is (engine, view, *args) -> Tuple[str, View].
    """
    view = view or View()
    parts = command_text.strip().split()
    if not parts:
        return "(empty command)", view
    cmd = parts[0]
    args = parts[1:]
    handler = _COMMANDS.get(cmd)
    if handler is None:
        return f"unknown command: {cmd!r} (try: {', '.join(_COMMANDS)})", view
    try:
        return handler(engine, view, *args)
    except Exception as e:
        return f"command {cmd!r} failed: {e}", view


def _cmd_describe(engine: Engine, view: View, node_id: str, *_) -> Tuple[str, View]:
    node = engine.nodes.get(node_id)
    if node is None:
        return f"no such node: {node_id}", view
    module = engine.types.get(node.type_name)
    if module and hasattr(module, "describe"):
        ctx = EmitContext(engine=engine, node=node)
        return module.describe(node.state, ctx), view
    return f"{node.type_name}#{node.id} params={node.params}", view


def _cmd_describe_subtree(engine: Engine, view: View, node_id: str, *_) -> Tuple[str, View]:
    return describe_scene(engine, node_id), view


def _cmd_list_types(engine: Engine, view: View, *_) -> Tuple[str, View]:
    lines = ["registered types:"]
    for name, module in sorted(engine.types.items()):
        m = module.manifest()
        lines.append(f"  {name} (v{m.version}, renderer={m.renderer_id}) — {m.description}")
    return "\n".join(lines), view


def _cmd_list_nodes(engine: Engine, view: View, *_) -> Tuple[str, View]:
    lines = ["spawned nodes:"]
    for nid, node in sorted(engine.nodes.items()):
        status = "DEAD" if node.dead else "ok"
        lines.append(f"  {nid} : {node.type_name} [{status}]")
    return "\n".join(lines), view


def _cmd_spawn(engine: Engine, view: View, type_name: str, node_id: str, *param_kvs) -> Tuple[str, View]:
    params: Dict[str, Any] = {}
    for kv in param_kvs:
        if "=" in kv:
            k, v = kv.split("=", 1)
            try:
                params[k] = json.loads(v)
            except json.JSONDecodeError:
                params[k] = v
    engine.spawn(node_id=node_id, type_name=type_name, params=params)
    node = engine.nodes[node_id]
    if node.dead:
        return f"spawn failed: {node.error}", view
    return f"spawned {type_name}#{node_id}", view


def _cmd_connect(engine: Engine, view: View, from_id: str, conn_name: str, to_id: str, *_) -> Tuple[str, View]:
    node = engine.nodes.get(from_id)
    if node is None:
        return f"no such node: {from_id}", view
    node.connections[conn_name] = to_id
    return f"connected {from_id}.{conn_name} -> {to_id}", view


def _cmd_move(engine: Engine, view: View, dx: str, dy: str, dz: str, *_) -> Tuple[str, View]:
    delta = np.array([float(dx), float(dy), float(dz)], dtype=np.float64)
    new_view = View(
        position=view.position + delta,
        orientation=view.orientation,
        scale=view.scale,
        width=view.width,
        height=view.height,
        fov_y_radians=view.fov_y_radians,
    )
    return f"viewer moved by {delta.tolist()}; now at {new_view.position.tolist()}", new_view


def _cmd_look_at(engine: Engine, view: View, x: str, y: str, z: str, *_) -> Tuple[str, View]:
    target = np.array([float(x), float(y), float(z)], dtype=np.float64)
    new_orient = look_at(view.position, target)
    new_view = View(
        position=view.position,
        orientation=new_orient,
        scale=view.scale,
        width=view.width,
        height=view.height,
        fov_y_radians=view.fov_y_radians,
    )
    return f"viewer now looking at {target.tolist()}", new_view


def _cmd_render(engine: Engine, view: View, root_id: str, *_) -> Tuple[str, View]:
    channels = engine.assemble(root_id, view)
    keys = sorted(channels.keys())
    return f"assembled channels: {keys}", view


def _cmd_render_text(engine: Engine, view: View, root_id: str, *_) -> Tuple[str, View]:
    return describe_view(engine, root_id, view), view


_COMMANDS = {
    "describe": _cmd_describe,
    "describe-subtree": _cmd_describe_subtree,
    "list-types": _cmd_list_types,
    "list-nodes": _cmd_list_nodes,
    "spawn": _cmd_spawn,
    "connect": _cmd_connect,
    "move": _cmd_move,
    "look-at": _cmd_look_at,
    "render": _cmd_render,
    "render-text": _cmd_render_text,
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _conn_target(conn) -> str:
    if isinstance(conn, str):
        return conn
    if isinstance(conn, dict):
        return conn["target"]
    if isinstance(conn, list):
        return conn[0]
    raise ValueError(f"unrecognized connection shape: {conn!r}")


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    parser = argparse.ArgumentParser(description="Apeiron text-based testing tools.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_describe = sub.add_parser("describe", help="Describe a scene as text.")
    p_describe.add_argument("scene", type=Path)
    p_describe.add_argument("--root", type=str, default=None)

    p_view = sub.add_parser("view", help="Render scene through TextRenderer at view.")
    p_view.add_argument("scene", type=Path)
    p_view.add_argument("--root", type=str, default=None)

    p_summary = sub.add_parser("summary", help="Summarize a written bundle.")
    p_summary.add_argument("bundle_dir", type=Path)

    p_command = sub.add_parser("command", help="Run a text command against a loaded scene.")
    p_command.add_argument("scene", type=Path)
    p_command.add_argument("command_text", nargs="+")

    args = parser.parse_args(argv)

    if args.cmd == "summary":
        print(summarize_bundle(args.bundle_dir))
        return 0

    # All other subcommands load a scene
    root_dir = Path(__file__).parent.parent.resolve()
    engine = Engine(root_dir=root_dir)
    engine.discover()
    scene_data = json.loads(args.scene.read_text())
    root_id = engine.load_scene(args.scene)
    if args.cmd != "summary" and getattr(args, "root", None):
        root_id = args.root

    view_meta = scene_data.get("view", {})
    position = np.asarray(view_meta.get("position", [3.0, 2.0, 5.0]), dtype=np.float64)
    target = np.asarray(view_meta.get("look_at", [0.0, 0.0, 0.0]), dtype=np.float64)
    view = View(
        position=position,
        orientation=look_at(position, target),
        width=int(view_meta.get("width", 256)),
        height=int(view_meta.get("height", 256)),
        scale=float(view_meta.get("scale", 1.0)),
    )

    if args.cmd == "describe":
        print(describe_scene(engine, root_id))
    elif args.cmd == "view":
        print(describe_view(engine, root_id, view))
    elif args.cmd == "command":
        result, _ = dispatch_command(engine, " ".join(args.command_text), view=view)
        print(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
