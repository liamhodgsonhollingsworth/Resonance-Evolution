"""Command definitions — one set per logical surface.

Each ``build_*_commands`` returns a list of ``Command`` instances the
runtime registers at startup. Keeping the handlers in this single
module (rather than scattered across each panel file) makes the
catalog auditable in one place and lets headless tests exercise every
command without touching ``streamlit``.

The GUI panels invoke these same handlers via
``CommandRegistry.run_gui``, so a button click and a typed command go
through one code path.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import List

from .command_registry import (
    Command,
    CommandContext,
    CommandRegistry,
    CommandResult,
)


# ---------------------------------------------------------------------------
# Idea queue — dispatched through idea_queue_main (logic node). Every
# verb here is a thin wrapper around engine.actions.dispatch_action;
# the file CRUD + list manipulation lives in node_types/idea_queue.py.
# ---------------------------------------------------------------------------


def _idea_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="idea_queue_main",
        action_name="list", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "idea_queue_main")
    if view.get("last_error"):
        return CommandResult.err(view["last_error"])
    items = view.get("items", [])
    if not items:
        return CommandResult.ok_msg("(queue empty)", data=[])
    rendered = "\n".join(f"  {i}: {text}" for i, text in enumerate(items))
    return CommandResult.ok_msg(rendered, data=items)


def _idea_add(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: idea-queue.add <text>")
    text = " ".join(args).strip()
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="idea_queue_main",
        action_name="add", payload={"text": text},
    )
    view = engine_actions.get_view_state(ctx.engine, "idea_queue_main")
    res = view.get("last_add", {})
    if not res.get("added"):
        return CommandResult.err(res.get("reason") or "add failed")
    return CommandResult.ok_msg(f"added at index {res['index']}", data=res["text"])


def _idea_move(ctx: CommandContext, args: List[str], verb: str) -> CommandResult:
    if not args:
        return CommandResult.err(f"usage: idea-queue.{verb} <index>")
    try:
        i = int(args[0])
    except ValueError:
        return CommandResult.err(f"index must be an integer, got {args[0]!r}")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="idea_queue_main",
        action_name=verb, payload={"index": i},
    )
    view = engine_actions.get_view_state(ctx.engine, "idea_queue_main")
    res = view.get(f"last_{verb}", {})
    if not res.get("moved"):
        return CommandResult.err(res.get("reason") or f"{verb} failed")
    return CommandResult.ok_msg(f"swapped {res['i']} <-> {res['j']}")


def _idea_up(ctx: CommandContext, args: List[str]) -> CommandResult:
    return _idea_move(ctx, args, "up")


def _idea_down(ctx: CommandContext, args: List[str]) -> CommandResult:
    return _idea_move(ctx, args, "down")


def _idea_delete(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: idea-queue.delete <index>")
    try:
        i = int(args[0])
    except ValueError:
        return CommandResult.err(f"index must be an integer, got {args[0]!r}")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="idea_queue_main",
        action_name="delete", payload={"index": i},
    )
    view = engine_actions.get_view_state(ctx.engine, "idea_queue_main")
    res = view.get("last_delete", {})
    if not res.get("deleted"):
        return CommandResult.err(res.get("reason") or "delete failed")
    return CommandResult.ok_msg(f"removed: {res['text']!r}")


def build_idea_queue_commands() -> List[Command]:
    return [
        Command("idea-queue.list", "list every item in the idea queue", _idea_list),
        Command("idea-queue.add", "append an item", _idea_add, arg_help="<text...>"),
        Command("idea-queue.up", "move item up", _idea_up, arg_help="<index>"),
        Command("idea-queue.down", "move item down", _idea_down, arg_help="<index>"),
        Command("idea-queue.delete", "delete item", _idea_delete, arg_help="<index>"),
    ]


# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------


def _session_status(ctx: CommandContext, args: List[str]) -> CommandResult:
    sid = ctx.active_session_id
    if not sid:
        return CommandResult.ok_msg("(no active session)", data=None)
    rec = ctx.session_manager.get(sid)
    if rec is None:
        return CommandResult.ok_msg(f"id {sid[:8]} (record missing)")
    return CommandResult.ok_msg(
        f"{rec.display_name} id={rec.id[:8]} type={rec.session_type} status={rec.status}",
        data={"id": rec.id, "status": rec.status, "type": rec.session_type, "name": rec.display_name},
    )


def _session_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SessionLister node so any surface reads the same list."""
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="session_lister_main",
        action_name="refresh", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "session_lister_main")
    records = view.get("sessions", [])
    if not records:
        return CommandResult.ok_msg("(no sessions)", data=[])
    lines = [
        f"  {r['id'][:8]} {r.get('status',''):10s} {r.get('session_type',''):25s} {r.get('display_name','')}"
        for r in records
    ]
    return CommandResult.ok_msg("\n".join(lines), data=[r["id"] for r in records])


def _session_respawn(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Signal the runtime to re-spawn on next rerun + clear the
    Streamlit cached runtime so the next rerun rebuilds it.

    Folds the GUI-only ``st.cache_resource.clear()`` side-channel into
    the command handler so the CLI-bridge invocation produces the same
    effect as a button click. Per the 2026-05-21 GUI/CLI 1:1 audit.
    The cache clear is best-effort — when streamlit isn't importable
    (headless tests) the clear is a no-op.
    """
    ctx.scratch["respawn_session"] = True
    try:
        import streamlit as st
        st.cache_resource.clear()
    except Exception:
        # Headless / pre-runtime / streamlit-missing path; the scratch
        # flag is the durable signal the runtime reads.
        pass
    return CommandResult.ok_msg("respawn flagged — will fire on next rerun")


def _session_spawn(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SessionSpawner node.

    Usage: ``session.spawn <session_type> [display_name] [-- seed prompt]``
    """
    if not args:
        return CommandResult.err(
            "usage: session.spawn <session_type> [display_name] [-- seed prompt]"
        )
    if "--" in args:
        sep = args.index("--")
        head, seed_parts = args[:sep], args[sep + 1:]
        seed_message = " ".join(seed_parts).strip() or None
    else:
        head, seed_message = args, None
    session_type = head[0]
    display_name = head[1] if len(head) > 1 else None
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="session_spawner_main",
        action_name="spawn",
        payload={
            "session_type": session_type,
            "display_name": display_name,
            "seed_message": seed_message,
            "cwd": str(ctx.apeiron_root),
        },
    )
    view = engine_actions.get_view_state(ctx.engine, "session_spawner_main")
    result = view.get("last_spawn", {})
    if not result.get("spawned"):
        return CommandResult.err(f"spawn failed: {result.get('reason')}")
    rec = result.get("record", {})
    return CommandResult.ok_msg(
        f"spawned {rec.get('display_name')} id={rec.get('id','')[:8]} type={rec.get('session_type','')}",
        data={
            "id": rec.get("id"),
            "type": rec.get("session_type"),
            "name": rec.get("display_name"),
        },
    )


def _chat_target_path(ctx: CommandContext):
    return ctx.config.state_dir / "chat_target.txt"


def _session_target(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SessionTarget node.

    Persists in node view-state. Streamlit driver continues to honor
    chat_target.txt for cache_resource compatibility — writing the file
    here keeps that path live until session_target's view-state becomes
    the canonical persistence layer.
    """
    if not args:
        return CommandResult.err("usage: session.target <session_id|none>")
    target = args[0]
    target_path = _chat_target_path(ctx)
    from engine import actions as engine_actions
    if target.lower() in {"none", "off", "clear"}:
        engine_actions.dispatch_action(
            ctx.engine, renderer_id="session_target_main",
            action_name="set", payload={"session_id": None},
        )
        try:
            target_path.unlink()
        except FileNotFoundError:
            pass
        ctx.active_session_id = None
        return CommandResult.ok_msg("chat target cleared")
    # Resolve via SessionResolver so name/prefix/id all work uniformly.
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="session_resolver_main",
        action_name="resolve", payload={"name_or_id": target},
    )
    resolution = engine_actions.get_view_state(
        ctx.engine, "session_resolver_main"
    ).get("last_resolution", {})
    if not resolution.get("resolved"):
        return CommandResult.err(
            f"no such session: {target} ({resolution.get('reason','')})"
        )
    sid = resolution["session_id"]
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="session_target_main",
        action_name="set", payload={"session_id": sid},
    )
    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(sid, encoding="utf-8")
    ctx.active_session_id = sid
    rec = ctx.session_manager.get(sid)
    name = rec.display_name if rec else sid[:8]
    return CommandResult.ok_msg(f"chat target → {name} ({sid[:8]})")


def _session_send(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SessionSender node."""
    if len(args) < 2:
        return CommandResult.err("usage: session.send <session_id> <message...>")
    sid = args[0]
    body = " ".join(args[1:]).strip()
    if not body:
        return CommandResult.err("empty message body")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="session_sender_main",
        action_name="send", payload={"session_id": sid, "body": body},
    )
    result = engine_actions.get_view_state(
        ctx.engine, "session_sender_main"
    ).get("last_send", {})
    if not result.get("sent"):
        return CommandResult.err(f"send failed: {result.get('reason')}")
    return CommandResult.ok_msg(f"sent ({len(body)} chars) to {sid[:8]}")


def _session_archive(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SessionArchiver node."""
    if not args:
        return CommandResult.err("usage: session.archive <session_id>")
    sid = args[0]
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="session_archiver_main",
        action_name="archive", payload={"session_id": sid},
    )
    result = engine_actions.get_view_state(
        ctx.engine, "session_archiver_main"
    ).get("last_archive", {})
    if not result.get("archived"):
        return CommandResult.err(f"archive failed: {result.get('reason')}")
    return CommandResult.ok_msg(f"archived {sid[:8]}")


def build_session_commands() -> List[Command]:
    return [
        Command("session.status", "show active session", _session_status),
        Command("session.list", "list all sessions", _session_list),
        Command("session.spawn", "spawn a claude-CLI session", _session_spawn,
                arg_help="<type> [name] [-- seed...]"),
        Command("session.target", "route chat to a specific session", _session_target,
                arg_help="<id|none>"),
        Command("session.send", "send to any session (not just the active one)",
                _session_send, arg_help="<id> <message...>"),
        Command("session.archive", "archive a session", _session_archive,
                arg_help="<id>"),
        Command("session.respawn", "respawn default workflow-mgmt session", _session_respawn),
    ]


# ---------------------------------------------------------------------------
# Scene picker
# ---------------------------------------------------------------------------


def _scene_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SceneLoader node."""
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_loader_main",
        action_name="list", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_loader_main")
    if view.get("error"):
        return CommandResult.err(view["error"])
    names = view.get("scenes", [])
    if not names:
        return CommandResult.ok_msg("(no scenes)", data=[])
    return CommandResult.ok_msg("\n".join(f"  {n}" for n in names), data=names)


def _scene_load(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SceneLoader node."""
    if not args:
        return CommandResult.err("usage: scene.load <name>")
    name = args[0]
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_loader_main",
        action_name="load", payload={"name": name},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_loader_main")
    result = view.get("last_load", {})
    if not result.get("loaded"):
        return CommandResult.err(result.get("reason") or "load failed")
    ctx.scratch["current_scene"] = result["scene"]
    return CommandResult.ok_msg(f"loaded {result['scene']}")


def _scene_current(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SceneLoader node; falls back to default_scene."""
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_loader_main",
        action_name="current", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_loader_main")
    current = (
        view.get("current_scene")
        or ctx.scratch.get("current_scene")
        or ctx.config.default_scene
    )
    return CommandResult.ok_msg(current, data=current)


def _scene_reload(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Dispatch through SceneLoader node — reload current scene from disk.

    Closes the scenes-JSON-not-watched gap. The maintainer edits the
    scene file by hand, then runs `scene.reload` to apply the change
    without restarting the program.
    """
    name = args[0] if args else ""
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_loader_main",
        action_name="reload", payload={"name": name},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_loader_main")
    res = view.get("last_reload", {})
    if not res.get("reloaded"):
        return CommandResult.err(res.get("reason") or "reload failed")
    ctx.scratch["current_scene"] = res["scene"]
    return CommandResult.ok_msg(f"reloaded {res['scene']}", data=res)


def build_scene_commands() -> List[Command]:
    return [
        Command("scene.list", "list available scenes", _scene_list),
        Command("scene.load", "load a scene by name", _scene_load, arg_help="<name>"),
        Command("scene.current", "show currently-loaded scene", _scene_current),
        Command("scene.reload", "re-load the current scene from disk",
                _scene_reload, arg_help="[name]"),
    ]


# ---------------------------------------------------------------------------
# Scene mutation — runtime evolve-from-within primitive. Every verb
# dispatches against scene_mutator_main; the engine's SPEC-076 mutation
# surface (spawn / set_param / connect / disconnect) is exposed plus
# the two inspectors (list_nodes / list_types). The maintainer's
# 2026-05-21 stress-test directive — "add new nodes, move those around
# freely" from within the software — is operational through these
# commands today. The Tk + HTML + MCP surfaces inherit the same verbs.
# ---------------------------------------------------------------------------


def _mutate_spawn(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 2:
        return CommandResult.err("usage: mutate.spawn <node_id> <type_name> [key=val ...]")
    node_id = args[0]
    type_name = args[1]
    params: dict = {}
    for tok in args[2:]:
        if "=" not in tok:
            return CommandResult.err(f"bad param {tok!r}; use key=value")
        k, _, v = tok.partition("=")
        # Best-effort numeric coercion; falls back to string.
        try:
            params[k] = int(v)
        except ValueError:
            try:
                params[k] = float(v)
            except ValueError:
                params[k] = v
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_mutator_main",
        action_name="spawn",
        payload={"node_id": node_id, "type_name": type_name, "params": params},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_mutator_main")
    res = view.get("last_spawn", {})
    if not res.get("spawned"):
        return CommandResult.err(res.get("reason") or "spawn failed")
    return CommandResult.ok_msg(
        f"spawned {res['node_id']} of type {res['type_name']}", data=res
    )


def _mutate_set_param(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 3:
        return CommandResult.err("usage: mutate.set-param <node_id> <key> <value>")
    node_id, key, raw = args[0], args[1], " ".join(args[2:])
    # Numeric coercion as above.
    try:
        value = int(raw)
    except ValueError:
        try:
            value = float(raw)
        except ValueError:
            value = raw
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_mutator_main",
        action_name="set_param",
        payload={"node_id": node_id, "key": key, "value": value},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_mutator_main")
    res = view.get("last_set_param", {})
    if not res.get("set"):
        return CommandResult.err(res.get("reason") or "set_param failed")
    return CommandResult.ok_msg(f"{node_id}.{key} = {value!r}", data=res)


def _mutate_connect(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 3:
        return CommandResult.err("usage: mutate.connect <from_id> <slot> <to_id>")
    from_id, slot, to_id = args[0], args[1], args[2]
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_mutator_main",
        action_name="connect",
        payload={"from_id": from_id, "slot": slot, "to_id": to_id},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_mutator_main")
    res = view.get("last_connect", {})
    if not res.get("connected"):
        return CommandResult.err(res.get("reason") or "connect failed")
    return CommandResult.ok_msg(f"{from_id}.{slot} -> {to_id}", data=res)


def _mutate_disconnect(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 2:
        return CommandResult.err("usage: mutate.disconnect <from_id> <slot>")
    from_id, slot = args[0], args[1]
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_mutator_main",
        action_name="disconnect",
        payload={"from_id": from_id, "slot": slot},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_mutator_main")
    res = view.get("last_disconnect", {})
    if not res.get("disconnected"):
        return CommandResult.err(res.get("reason") or "disconnect failed")
    return CommandResult.ok_msg(f"unwired {from_id}.{slot}", data=res)


def _mutate_list_nodes(ctx: CommandContext, args: List[str]) -> CommandResult:
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_mutator_main",
        action_name="list_nodes", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_mutator_main")
    nodes = view.get("last_list_nodes", [])
    if not nodes:
        return CommandResult.ok_msg("(no nodes)", data=[])
    lines = [
        f"  {n['id']:30s} {n['type']:20s}" + (" [dead]" if n.get("dead") else "")
        for n in nodes
    ]
    return CommandResult.ok_msg("\n".join(lines), data=nodes)


def _mutate_list_types(ctx: CommandContext, args: List[str]) -> CommandResult:
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="scene_mutator_main",
        action_name="list_types", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "scene_mutator_main")
    types = view.get("last_list_types", [])
    if not types:
        return CommandResult.ok_msg("(no types discovered)", data=[])
    return CommandResult.ok_msg("\n".join(f"  {t}" for t in types), data=types)


def build_mutate_commands() -> List[Command]:
    return [
        Command("mutate.spawn", "spawn a new node into the live graph",
                _mutate_spawn, arg_help="<node_id> <type_name> [key=val ...]"),
        Command("mutate.set-param", "set a param on a live node",
                _mutate_set_param, arg_help="<node_id> <key> <value>"),
        Command("mutate.connect", "wire from_id.slot -> to_id",
                _mutate_connect, arg_help="<from_id> <slot> <to_id>"),
        Command("mutate.disconnect", "unwire from_id.slot",
                _mutate_disconnect, arg_help="<from_id> <slot>"),
        Command("mutate.list-nodes", "list every node in the live graph",
                _mutate_list_nodes),
        Command("mutate.list-types", "list every node-type the engine discovered",
                _mutate_list_types),
    ]


# ---------------------------------------------------------------------------
# Panel positioning — surface-agnostic snap/move/resize/lock math.
# Every verb dispatches against panel_positioner_main; the math lives
# in node_types/panel_positioner.py and is shared with the Tk surface
# (when it migrates) and the HTML/MCP surfaces (future).
# ---------------------------------------------------------------------------


def _panel_register(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: panel.register <id> [x] [y] [w] [h]")
    panel_id = args[0]
    try:
        x = int(args[1]) if len(args) > 1 else 0
        y = int(args[2]) if len(args) > 2 else 0
        w = int(args[3]) if len(args) > 3 else 480
        h = int(args[4]) if len(args) > 4 else 320
    except ValueError:
        return CommandResult.err("x/y/w/h must be ints")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="register",
        payload={"panel_id": panel_id, "x": x, "y": y, "w": w, "h": h},
    )
    view = engine_actions.get_view_state(ctx.engine, "panel_positioner_main")
    res = view.get("last_register", {})
    if not res.get("registered"):
        return CommandResult.err(res.get("reason") or "register failed")
    return CommandResult.ok_msg(
        f"registered {panel_id} at ({res['x']},{res['y']}) {res['w']}x{res['h']}",
        data=res,
    )


def _panel_move(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 3:
        return CommandResult.err("usage: panel.move <id> <x> <y>")
    try:
        panel_id, x, y = args[0], int(args[1]), int(args[2])
    except ValueError:
        return CommandResult.err("x and y must be ints")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="move",
        payload={"panel_id": panel_id, "x": x, "y": y},
    )
    view = engine_actions.get_view_state(ctx.engine, "panel_positioner_main")
    res = view.get("last_move", {})
    if not res.get("moved"):
        return CommandResult.err(res.get("reason") or "move failed")
    return CommandResult.ok_msg(f"moved {panel_id} to ({res['x']},{res['y']})", data=res)


def _panel_resize(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 3:
        return CommandResult.err("usage: panel.resize <id> <w> <h>")
    try:
        panel_id, w, h = args[0], int(args[1]), int(args[2])
    except ValueError:
        return CommandResult.err("w and h must be ints")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="resize",
        payload={"panel_id": panel_id, "w": w, "h": h},
    )
    view = engine_actions.get_view_state(ctx.engine, "panel_positioner_main")
    res = view.get("last_resize", {})
    if not res.get("resized"):
        return CommandResult.err(res.get("reason") or "resize failed")
    return CommandResult.ok_msg(f"resized {panel_id} to {res['w']}x{res['h']}", data=res)


def _panel_lock(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: panel.lock <id>")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="lock", payload={"panel_id": args[0]},
    )
    return CommandResult.ok_msg(f"locked {args[0]}")


def _panel_unlock(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: panel.unlock <id>")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="unlock", payload={"panel_id": args[0]},
    )
    return CommandResult.ok_msg(f"unlocked {args[0]}")


def _panel_archive(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: panel.archive <id>")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="archive", payload={"panel_id": args[0]},
    )
    return CommandResult.ok_msg(f"archived {args[0]}")


def _panel_snap(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: panel.snap <id>")
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="snap_to_peers", payload={"panel_id": args[0]},
    )
    view = engine_actions.get_view_state(ctx.engine, "panel_positioner_main")
    res = view.get("last_snap", {})
    if not res.get("snapped"):
        return CommandResult.ok_msg(res.get("reason") or "no snap")
    return CommandResult.ok_msg(f"snapped {args[0]} to ({res['x']},{res['y']})", data=res)


def _panel_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="panel_positioner_main",
        action_name="list", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "panel_positioner_main")
    panels = view.get("last_list", [])
    if not panels:
        return CommandResult.ok_msg("(no panels)", data=[])
    lines = []
    for p in panels:
        flags = " [locked]" if p.get("locked") else ""
        flags += " [archived]" if p.get("archived") else ""
        lines.append(
            f"  {p['panel_id']}: ({p['x']},{p['y']}) {p['w']}x{p['h']}{flags}"
        )
    return CommandResult.ok_msg("\n".join(lines), data=panels)


def build_panel_commands() -> List[Command]:
    return [
        Command("panel.register", "register a panel for positioning",
                _panel_register, arg_help="<id> [x] [y] [w] [h]"),
        Command("panel.move", "move a panel; snaps to 12-px grid",
                _panel_move, arg_help="<id> <x> <y>"),
        Command("panel.resize", "resize a panel; 48-px minimum; snaps to grid",
                _panel_resize, arg_help="<id> <w> <h>"),
        Command("panel.lock", "lock a panel (refuse move/resize)",
                _panel_lock, arg_help="<id>"),
        Command("panel.unlock", "unlock a panel", _panel_unlock, arg_help="<id>"),
        Command("panel.archive", "archive a panel (skipped by peer-snap)",
                _panel_archive, arg_help="<id>"),
        Command("panel.snap", "snap a panel to closest peer edges",
                _panel_snap, arg_help="<id>"),
        Command("panel.list", "list all registered panels", _panel_list),
    ]


# ---------------------------------------------------------------------------
# Items / workflow panels
# ---------------------------------------------------------------------------


def _items_from_cache(ctx: CommandContext, source_id: str) -> List[dict]:
    entry = ctx.engine.cache.get(source_id, {})
    if not isinstance(entry, dict):
        return []
    items = entry.get("items", [])
    if not isinstance(items, list):
        return []
    return items


def _items_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: items.list <source_id>")
    source_id = args[0]
    items = _items_from_cache(ctx, source_id)
    if not items:
        return CommandResult.ok_msg(f"(no items at {source_id})", data=[])
    lines = [
        f"  [{it.get('status','?'):10s}] {it.get('id','?')}: {it.get('title','(untitled)')}"
        for it in items
    ]
    return CommandResult.ok_msg("\n".join(lines), data=items)


def _items_show(ctx: CommandContext, args: List[str]) -> CommandResult:
    if len(args) < 2:
        return CommandResult.err("usage: items.show <source_id> <item_id>")
    source_id, item_id = args[0], args[1]
    for it in _items_from_cache(ctx, source_id):
        if str(it.get("id")) == item_id:
            body = it.get("body", "")
            title = it.get("title", "")
            return CommandResult.ok_msg(f"{title}\n\n{body}", data=it)
    return CommandResult.err(f"no item {item_id} in {source_id}")


def build_items_commands() -> List[Command]:
    return [
        Command("items.list", "list items in a cache source", _items_list, arg_help="<source_id>"),
        Command("items.show", "show one item's body", _items_show, arg_help="<source_id> <item_id>"),
    ]


# ---------------------------------------------------------------------------
# Chat
# ---------------------------------------------------------------------------


def _chat_send(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Route a chat send through the ChatRouter node-type.

    The handler previously did inline inbox-echo + sm.send. That logic
    now lives in node_types/chat_router.py so the Tk surface and the
    Streamlit surface dispatch through one canonical routing node
    instead of each reimplementing the routing rules. This is the
    first concrete lift toward the "same logic node, different
    renderers" architectural commitment.
    """
    if not args:
        return CommandResult.err("usage: chat.send <message...>")
    text = " ".join(args).strip()
    if not text:
        return CommandResult.err("empty message")
    from engine import actions as engine_actions
    ok, msg = engine_actions.dispatch_action(
        ctx.engine,
        renderer_id="chat_router_main",
        action_name="send",
        payload={"text": text, "session_id": ctx.active_session_id},
    )
    if not ok:
        return CommandResult.err(f"chat_router.send: {msg}")
    view_state = engine_actions.get_view_state(ctx.engine, "chat_router_main")
    route = view_state.get("last_route") or {}
    if not route.get("routed"):
        return CommandResult.err(
            f"chat_router.send: {route.get('reason', 'unknown failure')}"
        )
    return CommandResult.ok_msg(f"sent ({len(text)} chars)")


def _chat_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    try:
        msgs = ctx.inbox.list_all(unread_only=False)
    except Exception as exc:
        return CommandResult.err(f"list_all failed: {exc}")
    if not msgs:
        return CommandResult.ok_msg("(no messages)", data=[])
    tail = msgs[-20:]
    lines = []
    for m in tail:
        when = time.strftime("%H:%M:%S", time.localtime(m.ts)) if m.ts else "—"
        lines.append(f"  {when}  from={m.sender}  to={m.to}  {m.summary[:60]}")
    return CommandResult.ok_msg("\n".join(lines), data=[m.summary for m in tail])


def build_chat_commands() -> List[Command]:
    return [
        Command("chat.send", "send a chat message to the active session", _chat_send, arg_help="<message...>"),
        Command("chat.list", "show last 20 inbox messages", _chat_list),
    ]


# ---------------------------------------------------------------------------
# Meta — help, clear, ping
# ---------------------------------------------------------------------------


def _help(ctx: CommandContext, args: List[str], registry: CommandRegistry) -> CommandResult:
    if args:
        target = registry.get(args[0])
        if target is None:
            return CommandResult.err(f"no such command: {args[0]}")
        lines = [
            f"{target.name}",
            f"  usage: {target.usage()}",
            f"  {target.description}",
        ]
        if target.aliases:
            lines.append(f"  aliases: {', '.join(target.aliases)}")
        return CommandResult.ok_msg("\n".join(lines))
    cmds = registry.commands()
    return CommandResult.ok_msg(
        "\n".join(f"  {c.usage():40s}  {c.description}" for c in cmds),
        data=[c.name for c in cmds],
    )


def _clear(ctx: CommandContext, args: List[str], registry: CommandRegistry) -> CommandResult:
    registry.clear_log()
    return CommandResult.ok_msg("log cleared")


def _ping(ctx: CommandContext, args: List[str]) -> CommandResult:
    return CommandResult.ok_msg("pong " + " ".join(args))


def _echo(ctx: CommandContext, args: List[str]) -> CommandResult:
    return CommandResult.ok_msg(" ".join(args), data=args)


def build_meta_commands(registry: CommandRegistry) -> List[Command]:
    return [
        Command("help", "list commands or describe one", lambda c, a: _help(c, a, registry), arg_help="[command]"),
        Command("clear", "clear the terminal log", lambda c, a: _clear(c, a, registry)),
        Command("ping", "smoke-test echo (returns pong)", _ping, arg_help="[message]"),
        Command("echo", "echo args back", _echo, arg_help="[message...]"),
    ]


# ---------------------------------------------------------------------------
# UI toggles — every interactive widget gets a command, so the in-page
# terminal logs the equivalent CLI form on each click.
# ---------------------------------------------------------------------------


def _ui_terminal_toggle(ctx: CommandContext, args: List[str]) -> CommandResult:
    try:
        import streamlit as st
        current = st.session_state.get("terminal_visible", True)
        st.session_state["terminal_visible"] = not current
        return CommandResult.ok_msg(f"terminal_visible={not current}")
    except Exception as exc:
        return CommandResult.err(f"streamlit session unavailable: {exc}")


def _ui_terminal_hide(ctx: CommandContext, args: List[str]) -> CommandResult:
    try:
        import streamlit as st
        st.session_state["terminal_visible"] = False
        return CommandResult.ok_msg("terminal_visible=False")
    except Exception as exc:
        return CommandResult.err(f"streamlit session unavailable: {exc}")


def _ui_terminal_show(ctx: CommandContext, args: List[str]) -> CommandResult:
    try:
        import streamlit as st
        st.session_state["terminal_visible"] = True
        return CommandResult.ok_msg("terminal_visible=True")
    except Exception as exc:
        return CommandResult.err(f"streamlit session unavailable: {exc}")


def build_ui_commands() -> List[Command]:
    return [
        Command("ui.terminal.toggle", "show/hide the in-page terminal", _ui_terminal_toggle),
        Command("ui.terminal.hide", "hide the in-page terminal", _ui_terminal_hide),
        Command("ui.terminal.show", "show the in-page terminal", _ui_terminal_show),
    ]


# ---------------------------------------------------------------------------
# Auth — every interaction (including the login form) has a CLI verb.
# Closes the 2026-05-21 audit gap where the login form dispatched
# directly against auth_gate_main and was unreachable from the CLI
# bridge.
# ---------------------------------------------------------------------------


def _auth_login(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Authenticate against auth_gate_main. The result lands in
    view-state and is returned as data so the GUI surface can decide
    what to do (write session_state["user"], rerun) while the CLI
    surface can act on the boolean directly.
    """
    if len(args) < 2:
        return CommandResult.err("usage: auth.login <username> <password>")
    username, password = args[0], " ".join(args[1:])
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="auth_gate_main",
        action_name="authenticate",
        payload={"username": username, "password": password},
    )
    view = engine_actions.get_view_state(ctx.engine, "auth_gate_main")
    res = view.get("last_authenticate", {})
    if not res.get("ok"):
        return CommandResult.err(res.get("reason") or "authentication failed")
    return CommandResult.ok_msg(f"signed in as {res['username']}", data=res)


def _auth_list_accounts(ctx: CommandContext, args: List[str]) -> CommandResult:
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="auth_gate_main",
        action_name="list_accounts", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "auth_gate_main")
    res = view.get("last_list_accounts", {})
    if not res.get("ok"):
        return CommandResult.err(res.get("reason") or "list_accounts failed")
    accounts = res.get("accounts", [])
    if not accounts:
        return CommandResult.ok_msg("(no accounts)", data=[])
    return CommandResult.ok_msg("\n".join(f"  {a}" for a in accounts), data=accounts)


def _auth_has_any_account(ctx: CommandContext, args: List[str]) -> CommandResult:
    from engine import actions as engine_actions
    engine_actions.dispatch_action(
        ctx.engine, renderer_id="auth_gate_main",
        action_name="has_any_account", payload={},
    )
    view = engine_actions.get_view_state(ctx.engine, "auth_gate_main")
    res = view.get("last_has_any_account", {})
    if not res.get("ok"):
        return CommandResult.err(res.get("reason") or "has_any_account failed")
    return CommandResult.ok_msg(
        "true" if res["present"] else "false", data=res["present"]
    )


def build_auth_commands() -> List[Command]:
    return [
        Command("auth.login", "authenticate username + password",
                _auth_login, arg_help="<username> <password>"),
        Command("auth.list-accounts", "list known account usernames",
                _auth_list_accounts),
        Command("auth.has-any-account", "check whether the store has any account",
                _auth_has_any_account),
    ]


# ---------------------------------------------------------------------------
# Aggregate registration
# ---------------------------------------------------------------------------


def register_all(registry: CommandRegistry) -> None:
    """Register every command this module owns. Idempotent."""
    registry.register_many(build_idea_queue_commands())
    registry.register_many(build_session_commands())
    registry.register_many(build_scene_commands())
    registry.register_many(build_mutate_commands())
    registry.register_many(build_panel_commands())
    registry.register_many(build_items_commands())
    registry.register_many(build_chat_commands())
    registry.register_many(build_ui_commands())
    registry.register_many(build_auth_commands())
    registry.register_many(build_meta_commands(registry))
