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


def _cmd_invoke(
    engine: Engine,
    view: View,
    renderer_id: str,
    item_id: str,
    action_name: str,
    *payload_kvs,
) -> Tuple[str, View]:
    """Generic action dispatch: invoke <renderer> <item> <action> [k=v ...].

    Pass ``""`` (an empty-string item-id) for renderer-scoped actions
    that don't target an item — e.g. ``invoke panel "" refresh``.
    """
    from engine.actions import dispatch_action
    payload: Dict[str, Any] = {}
    for kv in payload_kvs:
        if "=" in kv:
            k, v = kv.split("=", 1)
            try:
                payload[k] = json.loads(v)
            except json.JSONDecodeError:
                payload[k] = v
    ok, msg = dispatch_action(
        engine,
        renderer_id=renderer_id,
        action_name=action_name,
        item_id=item_id if item_id else None,
        payload=payload or None,
    )
    return ("OK: " if ok else "ERR: ") + msg, view


def _cmd_expand(
    engine: Engine,
    view: View,
    renderer_id: str,
    item_id: str,
    *_,
) -> Tuple[str, View]:
    """Sugar: expand <renderer> <item> == invoke <renderer> <item> expand."""
    from engine.actions import dispatch_action
    ok, msg = dispatch_action(
        engine, renderer_id, "expand", item_id=item_id
    )
    return ("OK: " if ok else "ERR: ") + msg, view


def _cmd_collapse(
    engine: Engine,
    view: View,
    renderer_id: str,
    *_,
) -> Tuple[str, View]:
    """Sugar: collapse <renderer> — renderer-scoped, no item required."""
    from engine.actions import dispatch_action
    ok, msg = dispatch_action(engine, renderer_id, "collapse")
    return ("OK: " if ok else "ERR: ") + msg, view


def _cmd_set_mode(
    engine: Engine,
    view: View,
    node_id: str,
    new_mode: str,
    *_,
) -> Tuple[str, View]:
    """Set a node's ``mode`` field. Currently meaningful for ``WorkflowView``
    where it toggles between ``"panels"`` and ``"full_render"`` (the same
    state-change the realtime renderer's Escape global-handler dispatches
    via ``set_mode``).

    This closes the text-API parity gap with the GUI's Escape key —
    the maintainer can toggle the workflow surface mode from text
    without driving the realtime window. Composes with SPEC-062
    (text-API parity for every GUI interaction).
    """
    node = engine.nodes.get(node_id)
    if node is None:
        return f"ERR: unknown node: {node_id!r}", view
    module = engine.types.get(node.type_name)
    if module is None or not hasattr(module, "set_mode"):
        return (
            f"ERR: node {node_id!r} (type {node.type_name!r}) does not "
            f"declare a set_mode hook",
            view,
        )
    try:
        module.set_mode(node, new_mode)
    except Exception as exc:
        return f"ERR: set_mode failed: {exc}", view
    return f"OK: set {node_id}.mode = {new_mode!r}", view


def _cmd_set_view(
    engine: Engine,
    view: View,
    *args,
) -> Tuple[str, View]:
    """Activate a view from the workflow GUI's view registry (SPEC-067).

    Usage::

        set-view <view-name>
        set-view             # no arg: print current view + available list

    Every "alternative collection of nodes" is a view (maintainer
    directive 2026-05-20). The GUI shell attaches its
    ``ViewRegistry`` to ``engine.view_registry`` at startup; this
    command consults it. When no GUI is attached the command still
    reports the registered views (the registry may be created
    independently for headless testing).
    """
    reg = getattr(engine, "view_registry", None)
    shell = getattr(engine, "gui_shell", None)

    # No argument: report current view + the menu.
    if not args:
        if reg is None:
            return "ERR: no view registry attached to engine", view
        current = getattr(shell, "active_tab", None) if shell is not None else None
        names = reg.names()
        archived = reg.archived_names()
        lines = [f"current view: {current!r}"]
        lines.append(f"available views: {', '.join(names) if names else '(none)'}")
        if archived:
            lines.append(f"archived views: {', '.join(archived)}")
        return "\n".join(lines), view

    target = args[0]
    if reg is None:
        return f"ERR: no view registry attached; cannot switch to {target!r}", view
    if reg.get(target) is None:
        return (
            f"ERR: unknown view {target!r}; "
            f"registered: {', '.join(reg.names() + reg.archived_names())}",
            view,
        )
    if shell is None:
        # Headless: just verify the view is registered. Caller can
        # decide what to do without an actual UI.
        return (
            f"OK (headless): view {target!r} is registered; "
            f"attach a GuiShell to activate it",
            view,
        )
    try:
        ok = shell.set_view(target)
    except Exception as exc:
        return f"ERR: set_view failed: {exc}", view
    if not ok:
        return f"ERR: set_view({target!r}) returned False", view
    return f"OK: active view = {target!r}", view


def _cmd_list_views(engine: Engine, view: View, *_) -> Tuple[str, View]:
    """List the views registered on ``engine.view_registry`` (SPEC-067).

    Output is one row per view with kind + source/panel/scene refs so
    a non-GUI caller can verify the registry contents end-to-end.
    """
    reg = getattr(engine, "view_registry", None)
    if reg is None:
        return "ERR: no view registry attached to engine", view
    lines = [f"views ({len(reg.names())} visible, {len(reg.archived_names())} archived):"]
    for spec in reg.list_views():
        bits = [f"kind={spec.kind}"]
        if spec.source_id:
            bits.append(f"source={spec.source_id}")
        if spec.panel_id:
            bits.append(f"panel={spec.panel_id}")
        if spec.scene_root:
            bits.append(f"scene={spec.scene_root}")
        lines.append(f"  {spec.name:18s}  {', '.join(bits)}")
    for name in reg.archived_names():
        lines.append(f"  [archived] {name}")
    return "\n".join(lines), view


def _cmd_copy_module(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Serialize a node (and its sub-tree) to JSON text (SPEC-073).

    Usage::

        copy-module <node-id>

    Returns the JSON text. Callers can pipe this to a file, clipboard,
    or another `paste-module` invocation against a different engine.
    """
    if not args:
        return "ERR: copy-module requires <node-id>", view
    try:
        from tools.module_clipboard import serialize_module
        text = serialize_module(engine, args[0], include_subtree=True)
    except KeyError as exc:
        return f"ERR: {exc}", view
    except Exception as exc:
        return f"ERR: serialize failed: {exc}", view
    return text, view


def _cmd_paste_module(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Instantiate a module from JSON text (SPEC-073).

    Usage::

        paste-module <json>

    The full json blob is taken as the concatenation of remaining
    args (since the shell tokenizer splits on whitespace). For
    multi-line JSON, callers should write to a file and use the
    Python API directly; this CLI form is for short single-node
    snippets.
    """
    if not args:
        return "ERR: paste-module requires a JSON payload", view
    text = " ".join(args)
    try:
        from tools.module_clipboard import paste_text_to_engine
        new_ids = paste_text_to_engine(engine, text)
    except Exception as exc:
        return f"ERR: paste failed: {exc}", view
    return f"OK: spawned {len(new_ids)} node(s): {', '.join(new_ids)}", view


def _cmd_route_chat(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Route a chat-submit body through the workflow shell's routing
    layer (SPEC-068).

    Usage::

        route-chat <body>
        route-chat @worker-2 status?
        route-chat /all heads up

    Requires a GuiShell attached to the engine (``engine.gui_shell``).
    Returns the routing decision as a one-line summary.
    """
    if not args:
        return "ERR: route-chat requires a body", view
    body = " ".join(args)
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        result = shell.route_chat(body)
    except Exception as exc:
        return f"ERR: route_chat raised: {exc}", view
    prefix = "OK" if result.get("routed") else "ERR"
    target = result.get("target") or "(none)"
    delivered = result.get("delivered_to") or []
    return (
        f"{prefix}: target={target}  delivered_to={delivered}  "
        f"reason={result.get('reason', '')!r}"
    ), view


def _cmd_set_active_session(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Set the active chat target (SPEC-068).

    Usage::

        set-active-session <id-or-name>

    Accepts a session id, display_name, or id-prefix (≥4 chars).
    """
    if not args:
        return "ERR: set-active-session requires <id-or-name>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        sid = shell.set_active_session(args[0])
    except Exception as exc:
        return f"ERR: set_active_session raised: {exc}", view
    if sid is None:
        return f"ERR: no session matched {args[0]!r}", view
    return f"OK: active session = {sid}", view


def _cmd_list_sessions(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """List active sessions registered on the machine (SPEC-079).

    Usage::

        list-sessions                    # default 10-min stale filter
        list-sessions --include-stale    # show every entry

    Each row: ``id  project=...  type=...  focus=...  last_seen=...``.
    """
    try:
        from tools.active_sessions import list_active_sessions
    except Exception as exc:
        return f"ERR: tools.active_sessions import failed: {exc}", view
    include_stale = "--include-stale" in args
    state_dir = getattr(engine, "active_sessions_state_dir", None)
    sessions = list_active_sessions(
        state_dir=state_dir,
        include_stale=include_stale,
    )
    if not sessions:
        return "(no active sessions)", view
    lines = [f"active sessions ({len(sessions)}):"]
    for s in sessions:
        stale_tag = " [stale]" if s.is_stale else ""
        lines.append(
            f"  {s.id}  project={s.project}  type={s.session_type}  "
            f"focus={s.focus!r}  last_seen={s.last_seen}{stale_tag}"
        )
    return "\n".join(lines), view


def _cmd_list_commands(engine: Engine, view: View, *_) -> Tuple[str, View]:
    """Return the canonical command-grammar list — what verbs the CLI
    supports. Equivalent to rendering a TextRenderer-wrapped scene and
    reading the COMMANDS AVAILABLE section, but accessible directly
    without scene loading."""
    from renderers.text import command_grammar
    lines = ["available commands:"]
    for entry in command_grammar():
        lines.append(f"  {entry}")
    lines.append("  set-mode <node> <mode>          -- mutate a node's mode field (e.g. WorkflowView panels/full_render)")
    lines.append("  set-view <view-name>            -- activate a registered view (SPEC-067)")
    lines.append("  list-views                      -- list views from engine.view_registry (SPEC-067)")
    lines.append("  list-sessions [--include-stale] -- list active Claude sessions on the machine (SPEC-079)")
    lines.append("  route-chat <body>               -- route chat through the shell (bare/@-prefix/all) (SPEC-068)")
    lines.append("  set-active-session <id|name>    -- set the active chat target (SPEC-068)")
    lines.append("  copy-module <node-id>           -- serialize node + subtree to JSON text (SPEC-073)")
    lines.append("  paste-module <json>             -- instantiate module from JSON text (SPEC-073)")
    return "\n".join(lines), view


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
    "invoke": _cmd_invoke,
    "expand": _cmd_expand,
    "collapse": _cmd_collapse,
    "set-mode": _cmd_set_mode,
    "set-view": _cmd_set_view,
    "list-views": _cmd_list_views,
    "list-sessions": _cmd_list_sessions,
    "route-chat": _cmd_route_chat,
    "set-active-session": _cmd_set_active_session,
    "copy-module": _cmd_copy_module,
    "paste-module": _cmd_paste_module,
    "list-commands": _cmd_list_commands,
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
    # Run precompute so source-cache entries are populated before any
    # describe/view/command subcommand. Without this, FileSource and
    # MCPSource panels appear empty to the CLI even though the panel
    # is correctly wired in the scene.
    engine.precompute()
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
