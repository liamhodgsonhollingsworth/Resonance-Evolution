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


def _cmd_visual_regression_capture(
    engine: Engine, view: View, *args
) -> Tuple[str, View]:
    """Capture the current scene of a registered baseline (SPEC-080).

    Usage::

        visual-regression-capture <name>

    Looks up the baseline in the default manifest, invokes its
    renderer hook, captures the resulting Tk widget, and writes the
    PNG to ``tests/visual_regression/baselines/<name>.png``. This is
    the "establish a new baseline" path — overwrites any existing
    file at the same name without prompting.

    Returns an error if the baseline isn't registered, the renderer
    raises, or the capture surface reports a headless environment.
    Production renderer hooks are registered by SPEC-069; this PR
    ships scaffolding only.
    """
    if not args:
        return "ERR: visual-regression-capture requires <name>", view
    name = args[0]
    try:
        from tools.visual_regression.manifest import default_manifest
        from tools.visual_regression.capture import (
            CaptureError,
            HeadlessCaptureError,
            capture_widget,
        )
        from tools.visual_regression.runner import baselines_dir
    except Exception as exc:
        return f"ERR: visual_regression unavailable: {exc}", view

    manifest = default_manifest()
    spec = manifest.get(name)
    if spec is None:
        registered = ", ".join(manifest.names()) or "(none)"
        return (
            f"ERR: unknown baseline {name!r}; "
            f"registered: {registered}",
            view,
        )
    try:
        widget = spec.renderer()
    except Exception as exc:
        return f"ERR: renderer hook for {name!r} raised: {exc}", view
    try:
        img = capture_widget(widget)
    except HeadlessCaptureError as exc:
        return f"ERR: headless capture: {exc}", view
    except CaptureError as exc:
        return f"ERR: capture failed: {exc}", view
    path = baselines_dir() / f"{name}.png"
    try:
        img.save(path, format="PNG")
    except Exception as exc:
        return f"ERR: writing baseline PNG raised: {exc}", view
    return f"OK: captured {name!r} -> {path}", view


def _cmd_visual_regression_compare(
    engine: Engine, view: View, *args
) -> Tuple[str, View]:
    """Compare the current scene against its baseline (SPEC-080).

    Usage::

        visual-regression-compare <name>

    Drives the capture-and-compare cycle. Returns the SSIM score
    plus a one-line summary; failure artifacts get written to
    ``tests/visual_regression/failures/`` per the runner contract.

    Status codes the verb may surface:

    - ``pass`` / ``fail`` — comparison ran; threshold cleared or not.
    - ``baseline_missing`` — no PNG yet; record a baseline first via
      ``visual-regression-capture``.
    - ``unknown_baseline`` — name not in the manifest.
    - ``headless`` / ``capture_error`` — capture surface couldn't run.
    """
    if not args:
        return "ERR: visual-regression-compare requires <name>", view
    name = args[0]
    try:
        from tools.visual_regression.runner import run_baseline
    except Exception as exc:
        return f"ERR: visual_regression unavailable: {exc}", view
    try:
        result = run_baseline(name)
    except Exception as exc:
        return f"ERR: run_baseline raised: {exc}", view
    prefix = "OK" if result.passed else "ERR"
    parts = [f"status={result.status}"]
    if result.compare is not None:
        parts.append(f"score={result.compare.score:.4f}")
        parts.append(f"threshold={result.compare.threshold:.2f}")
    if result.capture_path is not None:
        parts.append(f"failure_artifact={result.capture_path}")
    if result.error:
        parts.append(f"reason={result.error}")
    return f"{prefix}: {name} {' '.join(parts)}", view


def _cmd_visual_regression_list(
    engine: Engine, view: View, *_
) -> Tuple[str, View]:
    """List baselines registered in the default manifest (SPEC-080).

    Usage::

        visual-regression-list

    One row per baseline with the slug, threshold (if set), tags,
    and a flag indicating whether the baseline PNG exists on disk.
    """
    try:
        from tools.visual_regression.manifest import default_manifest
        from tools.visual_regression.runner import baselines_dir
    except Exception as exc:
        return f"ERR: visual_regression unavailable: {exc}", view
    manifest = default_manifest()
    if not len(manifest):
        return (
            "no baselines registered in the default manifest "
            "(SPEC-069 populates production scenes)",
            view,
        )
    base_dir = baselines_dir()
    lines = [f"baselines ({len(manifest)} registered):"]
    for spec in manifest:
        png_path = base_dir / f"{spec.name}.png"
        png_state = "[has PNG]" if png_path.exists() else "[no PNG yet]"
        bits = [png_state]
        if spec.threshold is not None:
            bits.append(f"threshold={spec.threshold:.2f}")
        if spec.tags:
            bits.append(f"tags={list(spec.tags)}")
        desc = f" — {spec.description}" if spec.description else ""
        lines.append(f"  {spec.name:24s}  {' '.join(bits)}{desc}")
    return "\n".join(lines), view


def _cmd_move_panel(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Move a panel to (x, y) — snapped to the 12-px grid (SPEC-007).

    Usage::

        move-panel <panel-id> <x> <y>

    Requires a GuiShell attached to the engine. Returns the resulting
    panel state {panel_id, view_name, x, y, w, h, locked, archived}.
    """
    if len(args) < 3:
        return "ERR: move-panel requires <panel-id> <x> <y>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        pid, x, y = args[0], int(args[1]), int(args[2])
    except ValueError:
        return "ERR: x and y must be integers", view
    try:
        state = shell.move_panel(pid, x, y)
    except Exception as exc:
        return f"ERR: move_panel raised: {exc}", view
    return f"OK: {state}", view


def _cmd_resize_panel(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Resize a panel to (w, h) — snapped to the 12-px grid (SPEC-007).

    Usage::

        resize-panel <panel-id> <w> <h>

    Width/height clamp to a 48 px minimum.
    """
    if len(args) < 3:
        return "ERR: resize-panel requires <panel-id> <w> <h>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        pid, w, h = args[0], int(args[1]), int(args[2])
    except ValueError:
        return "ERR: w and h must be integers", view
    try:
        state = shell.resize_panel(pid, w, h)
    except Exception as exc:
        return f"ERR: resize_panel raised: {exc}", view
    return f"OK: {state}", view


def _cmd_lock_panel(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Lock a panel — subsequent move/resize calls no-op (SPEC-007)."""
    if not args:
        return "ERR: lock-panel requires <panel-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    ok = shell.lock_panel(args[0])
    if not ok:
        return f"ERR: no panel handle for {args[0]!r}", view
    return f"OK: locked {args[0]}", view


def _cmd_unlock_panel(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Unlock a panel (SPEC-007)."""
    if not args:
        return "ERR: unlock-panel requires <panel-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    ok = shell.unlock_panel(args[0])
    if not ok:
        return f"ERR: no panel handle for {args[0]!r}", view
    return f"OK: unlocked {args[0]}", view


def _cmd_panel_state(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Read the (x, y, w, h, locked, archived) state of a panel."""
    if not args:
        return "ERR: panel-state requires <panel-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    state = shell.panel_state(args[0])
    if not state:
        return f"ERR: no panel handle for {args[0]!r}", view
    return f"OK: {state}", view


def _cmd_archive_panel(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Archive a panel via the same code path the right-click menu
    uses (SPEC-008). Verifies the wiring without driving a real menu."""
    if not args:
        return "ERR: archive-panel requires <panel-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    ok = shell.archive_panel(args[0])
    if not ok:
        return f"ERR: no panel handle for {args[0]!r}", view
    return f"OK: archived {args[0]}", view


def _cmd_restore_panel(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Restore a previously-archived panel (SPEC-008)."""
    if not args:
        return "ERR: restore-panel requires <panel-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    ok = shell.restore_panel(args[0])
    if not ok:
        return f"ERR: no panel handle for {args[0]!r}", view
    return f"OK: restored {args[0]}", view


def _cmd_lock_widget(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Lock any widget by id (SPEC-075). Routes through the generic
    WidgetLock registry; panel widgets continue to flow through
    lock_panel so SPEC-007's invariants hold."""
    if not args:
        return "ERR: lock-widget requires <widget-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    ok = shell.lock_widget(args[0])
    if not ok:
        return f"ERR: lock_widget refused for {args[0]!r}", view
    return f"OK: locked {args[0]}", view


def _cmd_unlock_widget(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Unlock any widget by id (SPEC-075). Returns ERR if no entry
    exists in either the panel-handle table or the registry."""
    if not args:
        return "ERR: unlock-widget requires <widget-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    ok = shell.unlock_widget(args[0])
    if not ok:
        return f"ERR: no widget entry for {args[0]!r}", view
    return f"OK: unlocked {args[0]}", view


def _cmd_widget_lock_state(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Read the WidgetLock registry entry for a widget id (SPEC-075).
    Returns ``{widget_id, locked, frozen_position, widget_kind}``."""
    if not args:
        return "ERR: widget-lock-state requires <widget-id>", view
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    state = shell.widget_lock_state(args[0])
    if not state:
        return f"ERR: no widget entry for {args[0]!r}", view
    return f"OK: {state}", view


def _cmd_list_locked_widgets(engine: Engine, view: View, *_) -> Tuple[str, View]:
    """List every currently-locked widget across all kinds (SPEC-075).
    Returns sorted-by-id entries for deterministic test assertions."""
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    locked = shell.list_locked_widgets()
    if not locked:
        return "OK: []", view
    return f"OK: {locked}", view


def _cmd_visual_contract_list_colors(
    engine: Engine, view: View, *_
) -> Tuple[str, View]:
    """List every semantic color token + its hex value (SPEC-069).

    Includes per-view tints under a ``view-accent::<name>``
    pseudo-prefix so the text-API surfaces both palettes.
    """
    try:
        from tools.visual_contract import (
            get_color,
            list_color_tokens,
            list_view_accents,
            view_accent,
        )
    except Exception as exc:
        return f"ERR: visual_contract import failed: {exc}", view
    lines = [f"color tokens ({len(list_color_tokens())}):"]
    for token in list_color_tokens():
        lines.append(f"  {token:20s}  {get_color(token)}")
    accents = list_view_accents()
    if accents:
        lines.append(f"view accents ({len(accents)}):")
        for name in accents:
            lines.append(f"  view-accent::{name:18s} {view_accent(name)}")
    return "\n".join(lines), view


def _cmd_visual_contract_list_icons(
    engine: Engine, view: View, *_
) -> Tuple[str, View]:
    """List every icon name registered in the contract (SPEC-069)."""
    try:
        from tools.visual_contract import (
            active_renderer,
            list_icon_names,
        )
    except Exception as exc:
        return f"ERR: visual_contract import failed: {exc}", view
    names = list_icon_names()
    lines = [
        f"icons ({len(names)}, renderer={active_renderer()}):",
    ]
    for name in names:
        lines.append(f"  {name}")
    return "\n".join(lines), view


def _cmd_visual_contract_list_fonts(
    engine: Engine, view: View, *_
) -> Tuple[str, View]:
    """List font aliases + size tokens (SPEC-069).

    Reports the *probed* family for each alias (i.e. the first
    available in the stack) and the full stack so the maintainer can
    see why a particular family was chosen.
    """
    try:
        from tools.visual_contract import (
            font_stack,
            get_font,
            get_font_size,
            list_font_families,
            list_font_sizes,
        )
    except Exception as exc:
        return f"ERR: visual_contract import failed: {exc}", view
    lines = ["font aliases:"]
    for alias in list_font_families():
        chosen_family = get_font(alias)[0]
        stack = " -> ".join(font_stack(alias))
        lines.append(
            f"  {alias:6s}  probed={chosen_family!r}  stack={stack}"
        )
    lines.append("size tokens:")
    for token in list_font_sizes():
        lines.append(f"  {token:20s}  {get_font_size(token)}pt")
    return "\n".join(lines), view


def _cmd_visual_contract_resolve_icon(
    engine: Engine, view: View, *args
) -> Tuple[str, View]:
    """Render an icon to PIL and report its dimensions (SPEC-069).

    Usage::

        visual-contract-resolve-icon <name> [size]

    Returns ``OK: <name> rendered (<w>x<h>) via <renderer>`` on
    success. ``ERR`` with a clear message on unknown name, bad
    size, or render failure. The PhotoImage cache is bypassed —
    headless callers don't need a Tk root.
    """
    if not args:
        return "ERR: visual-contract-resolve-icon requires <name> [size]", view
    name = args[0]
    size = 16
    if len(args) >= 2:
        try:
            size = int(args[1])
        except ValueError:
            return f"ERR: size must be an integer, got {args[1]!r}", view
    try:
        from tools.visual_contract import (
            active_renderer,
            render_icon_image,
        )
    except Exception as exc:
        return f"ERR: visual_contract import failed: {exc}", view
    try:
        img = render_icon_image(name, size=size)
    except KeyError as exc:
        return f"ERR: {exc}", view
    except ValueError as exc:
        return f"ERR: {exc}", view
    except Exception as exc:
        return f"ERR: render failed: {exc}", view
    return (
        f"OK: {name} rendered ({img.size[0]}x{img.size[1]}) "
        f"via {active_renderer()}"
    ), view


def _cmd_spawn_button(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Spawn a ButtonNode (SPEC-077).

    Usage::

        spawn-button <label> <action> [target]
        spawn-button <label> <action> [target] parent=<id> icon=<name> \\
                     standard=true order=10 payload=<json>

    The first positional arg is the button label, the second is the
    action name dispatched on click. The optional third positional is
    the target prefix (``panel:foo``, ``node:bar``, etc — empty for
    self). Extra ``key=value`` pairs (with JSON-decoded values) tune
    the optional fields.

    The new node-id is auto-generated as ``button_<label-slug>_<n>``
    so callers don't need to pass one explicitly.
    """
    if len(args) < 2:
        return (
            "ERR: spawn-button requires <label> <action> [target] [key=value ...]",
            view,
        )
    label = args[0]
    action = args[1]
    target = args[2] if len(args) >= 3 and "=" not in args[2] else ""
    kwarg_start = 3 if target else 2
    params: Dict[str, Any] = {
        "label": label,
        "action": action,
        "target": target,
    }
    for kv in args[kwarg_start:]:
        if "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        try:
            params[k] = json.loads(v)
        except json.JSONDecodeError:
            params[k] = v
    slug = "".join(c if c.isalnum() else "_" for c in label.lower()) or "btn"
    base_id = f"button_{slug}"
    button_id = base_id
    n = 2
    while button_id in engine.nodes:
        button_id = f"{base_id}_{n}"
        n += 1
    engine.spawn(button_id, "ButtonNode", params=params)
    node = engine.nodes.get(button_id)
    if node is None or node.dead:
        err = (node.error if node else "spawn failed") or "spawn failed"
        return f"ERR: spawn failed: {err.splitlines()[0]}", view
    return f"OK: spawned ButtonNode#{button_id}", view


def _cmd_list_node_history(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """List the history rows for a node (SPEC-076).

    Usage::

        list-node-history <node-id>

    Reads ``state/node_history/<node-id>.jsonl`` via
    :func:`tools.node_history.read_node_history`. Returns one row per
    line, newest-first, in a compact ``ts kind summary`` shape.
    """
    if not args:
        return "ERR: list-node-history requires <node-id>", view
    from tools.node_history import read_node_history
    rows = read_node_history(engine.root_dir, args[0], engine=engine)
    if not rows:
        return f"(no history for {args[0]!r})", view
    lines = [f"history for {args[0]!r} ({len(rows)} rows, newest first):"]
    for row in rows:
        ts = row.get("ts", "")
        kind = row.get("kind", "")
        summary = row.get("summary") or row.get("payload") or ""
        if isinstance(summary, dict):
            summary = json.dumps(summary, separators=(",", ":"))
        lines.append(f"  {ts}  {kind:12s} {summary}")
    return "\n".join(lines), view


def _cmd_list_node_connections(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """List in-edges + out-edges for a node (SPEC-076).

    Usage::

        list-node-connections <node-id>

    Returns the dict from :func:`tools.button_view.connections_for`,
    formatted for human-reading. Same data the Connections view
    surfaces.
    """
    if not args:
        return "ERR: list-node-connections requires <node-id>", view
    from tools.button_view import connections_for
    edges = connections_for(engine, args[0])
    out_lines = [f"connections for {args[0]!r}:"]
    out_lines.append(f"  out-edges ({len(edges['out'])}):")
    for e in edges["out"]:
        out_lines.append(f"    .{e['slot']} -> {e['target_id']}")
    out_lines.append(f"  in-edges ({len(edges['in'])}):")
    for e in edges["in"]:
        out_lines.append(f"    {e['from_id']}.{e['slot']} -> here")
    return "\n".join(out_lines), view


def _cmd_node_buttons(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """List the button row for a node (SPEC-076).

    Usage::

        node-buttons <node-id>

    Returns the derived button row — standards first (Author, History,
    Connections) plus any maintainer-added customizations. The
    standards have empty ``button_id`` because they're not real
    ButtonNodes; customizations carry the real id.
    """
    if not args:
        return "ERR: node-buttons requires <node-id>", view
    from tools.button_view import button_row_for
    row = button_row_for(engine, args[0])
    if not row:
        return f"(no buttons on {args[0]!r})", view
    lines = [f"button row for {args[0]!r} ({len(row)} buttons):"]
    for spec in row:
        tag = "standard" if spec.standard else "custom"
        bid = spec.button_id or "(derived)"
        lines.append(
            f"  [{tag}] {spec.label:14s} action={spec.action:18s} "
            f"target={spec.target or '(self)':20s} icon={spec.icon or '-':12s} "
            f"id={bid}"
        )
    return "\n".join(lines), view


def _cmd_click_button(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Click a ButtonNode and route the resulting action (SPEC-077).

    Usage::

        click-button <button-node-id>

    Resolves the ButtonNode's target prefix through
    :func:`engine.actions.resolve_target`, then dispatches through
    ``engine.actions.dispatch_action`` for the dispatchable target
    kinds. View-prefixed targets surface a hint that the GUI shell
    handles those.
    """
    if not args:
        return "ERR: click-button requires <button-node-id>", view
    from engine.actions import dispatch_button
    ok, msg = dispatch_button(engine, args[0])
    return ("OK: " if ok else "ERR: ") + msg, view


def _cmd_browser_open(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Load a URL into the active Browser tab's HtmlFrame (SPEC-066).

    Usage::

        browser-open <url>

    Requires a GuiShell with an active Browser view. Headless callers
    (no GUI) get a clear error so the failure mode is named rather
    than silent.
    """
    if not args:
        return "ERR: browser-open requires <url>", view
    url = " ".join(args)
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        ok = shell.browser_open(url)
    except Exception as exc:
        return f"ERR: browser_open raised: {exc}", view
    if not ok:
        return (
            "ERR: no active Browser frame; activate the Browser view first "
            "via 'set-view Browser'"
        ), view
    return f"OK: loaded {url!r}", view


def _cmd_browser_html(engine: Engine, view: View, *args) -> Tuple[str, View]:
    """Render an inline HTML string in the active Browser tab (SPEC-066).

    Usage::

        browser-html <html>

    The full HTML is the whitespace-joined remainder of args. For
    multi-line documents, write to a file and call the Python API
    directly; this CLI form is for short snippets.
    """
    if not args:
        return "ERR: browser-html requires an HTML payload", view
    html = " ".join(args)
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        ok = shell.browser_load_html(html)
    except Exception as exc:
        return f"ERR: browser_load_html raised: {exc}", view
    if not ok:
        return (
            "ERR: no active Browser frame; activate the Browser view first "
            "via 'set-view Browser'"
        ), view
    return f"OK: rendered inline HTML ({len(html)} chars)", view


def _cmd_browser_current_url(engine: Engine, view: View, *_) -> Tuple[str, View]:
    """Return the URL currently displayed in the Browser tab (SPEC-066).

    Usage::

        browser-current-url

    Returns the placeholder "(no url)" when no Browser frame is
    active or no page has loaded yet.
    """
    shell = getattr(engine, "gui_shell", None)
    if shell is None:
        return "ERR: no gui_shell attached to engine", view
    try:
        url = shell.browser_current_url()
    except Exception as exc:
        return f"ERR: browser_current_url raised: {exc}", view
    if not url:
        return "OK: (no url)", view
    return f"OK: {url}", view


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
    lines.append("  visual-regression-capture <name> -- capture current scene to baseline PNG (SPEC-080)")
    lines.append("  visual-regression-compare <name> -- compare current scene against baseline (SPEC-080)")
    lines.append("  visual-regression-list           -- list registered baselines + their PNG state (SPEC-080)")
    lines.append("  move-panel <pid> <x> <y>        -- move a panel; snapped to 12-px grid (SPEC-007)")
    lines.append("  resize-panel <pid> <w> <h>      -- resize a panel; snapped to 12-px grid (SPEC-007)")
    lines.append("  lock-panel <pid>                -- lock a panel (move/resize no-op) (SPEC-007)")
    lines.append("  unlock-panel <pid>              -- unlock a panel (SPEC-007)")
    lines.append("  panel-state <pid>               -- read panel handle {x,y,w,h,locked,archived} (SPEC-007)")
    lines.append("  archive-panel <pid>             -- archive a panel (composes with SPEC-067) (SPEC-008)")
    lines.append("  restore-panel <pid>             -- restore a previously-archived panel (SPEC-008)")
    lines.append("  lock-widget <widget-id>         -- lock any widget (panel / button / icon) (SPEC-075)")
    lines.append("  unlock-widget <widget-id>       -- unlock any widget (SPEC-075)")
    lines.append("  widget-lock-state <widget-id>   -- read WidgetLock registry entry (SPEC-075)")
    lines.append("  list-locked-widgets             -- list every currently-locked widget (SPEC-075)")
    lines.append("  visual-contract-list-colors     -- list semantic color tokens + view tints (SPEC-069)")
    lines.append("  visual-contract-list-icons      -- list icon names registered in the contract (SPEC-069)")
    lines.append("  visual-contract-list-fonts      -- list font aliases + size tokens with probed family (SPEC-069)")
    lines.append("  visual-contract-resolve-icon <name> [size] -- render an icon and report dimensions (SPEC-069)")
    lines.append("  spawn-button <label> <action> [target] [k=v ...]  -- spawn a ButtonNode (SPEC-077)")
    lines.append("  list-node-history <node-id>     -- list edit history rows for a node (SPEC-076)")
    lines.append("  list-node-connections <node-id> -- list in-edges + out-edges for a node (SPEC-076)")
    lines.append("  node-buttons <node-id>          -- list derived button row (standards + customizations) (SPEC-076)")
    lines.append("  click-button <button-node-id>   -- dispatch a ButtonNode's action (SPEC-077)")
    lines.append("  browser-open <url>              -- load URL into the active Browser view (SPEC-066)")
    lines.append("  browser-html <html>             -- render inline HTML in the Browser view (SPEC-066)")
    lines.append("  browser-current-url             -- read the Browser view's current URL (SPEC-066)")
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
    "visual-regression-capture": _cmd_visual_regression_capture,
    "visual-regression-compare": _cmd_visual_regression_compare,
    "visual-regression-list": _cmd_visual_regression_list,
    "move-panel": _cmd_move_panel,
    "resize-panel": _cmd_resize_panel,
    "lock-panel": _cmd_lock_panel,
    "unlock-panel": _cmd_unlock_panel,
    "panel-state": _cmd_panel_state,
    "archive-panel": _cmd_archive_panel,
    "restore-panel": _cmd_restore_panel,
    "lock-widget": _cmd_lock_widget,
    "unlock-widget": _cmd_unlock_widget,
    "widget-lock-state": _cmd_widget_lock_state,
    "list-locked-widgets": _cmd_list_locked_widgets,
    "visual-contract-list-colors": _cmd_visual_contract_list_colors,
    "visual-contract-list-icons": _cmd_visual_contract_list_icons,
    "visual-contract-list-fonts": _cmd_visual_contract_list_fonts,
    "visual-contract-resolve-icon": _cmd_visual_contract_resolve_icon,
    "spawn-button": _cmd_spawn_button,
    "list-node-history": _cmd_list_node_history,
    "list-node-connections": _cmd_list_node_connections,
    "node-buttons": _cmd_node_buttons,
    "click-button": _cmd_click_button,
    "browser-open": _cmd_browser_open,
    "browser-html": _cmd_browser_html,
    "browser-current-url": _cmd_browser_current_url,
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
