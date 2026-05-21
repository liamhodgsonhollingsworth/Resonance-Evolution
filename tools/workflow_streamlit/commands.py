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
# Idea queue
# ---------------------------------------------------------------------------


def _idea_queue_path(ctx: CommandContext) -> Path:
    return ctx.config.state_dir / "idea_queue.md"


def _load_idea_queue(ctx: CommandContext) -> List[str]:
    path = _idea_queue_path(ctx)
    if not path.exists():
        return []
    out: List[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith("- "):
            out.append(line[2:].strip())
    return out


def _save_idea_queue(ctx: CommandContext, items: List[str]) -> None:
    path = _idea_queue_path(ctx)
    path.parent.mkdir(parents=True, exist_ok=True)
    body = "# Idea queue\n\n" + "\n".join(f"- {it}" for it in items) + ("\n" if items else "")
    path.write_text(body, encoding="utf-8")


def _idea_list(ctx: CommandContext, args: List[str]) -> CommandResult:
    items = _load_idea_queue(ctx)
    if not items:
        return CommandResult.ok_msg("(queue empty)", data=[])
    rendered = "\n".join(f"  {i}: {text}" for i, text in enumerate(items))
    return CommandResult.ok_msg(rendered, data=items)


def _idea_add(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: idea-queue.add <text>")
    text = " ".join(args).strip()
    if not text:
        return CommandResult.err("empty text")
    items = _load_idea_queue(ctx)
    items.append(text)
    _save_idea_queue(ctx, items)
    return CommandResult.ok_msg(f"added at index {len(items) - 1}", data=text)


def _idea_move(ctx: CommandContext, args: List[str], direction: int) -> CommandResult:
    if not args:
        return CommandResult.err(f"usage: idea-queue.{'up' if direction < 0 else 'down'} <index>")
    try:
        i = int(args[0])
    except ValueError:
        return CommandResult.err(f"index must be an integer, got {args[0]!r}")
    items = _load_idea_queue(ctx)
    j = i + direction
    if not (0 <= i < len(items)) or not (0 <= j < len(items)):
        return CommandResult.err(f"out of range: i={i} target={j} len={len(items)}")
    items[i], items[j] = items[j], items[i]
    _save_idea_queue(ctx, items)
    return CommandResult.ok_msg(f"swapped {i} <-> {j}")


def _idea_up(ctx: CommandContext, args: List[str]) -> CommandResult:
    return _idea_move(ctx, args, -1)


def _idea_down(ctx: CommandContext, args: List[str]) -> CommandResult:
    return _idea_move(ctx, args, +1)


def _idea_delete(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: idea-queue.delete <index>")
    try:
        i = int(args[0])
    except ValueError:
        return CommandResult.err(f"index must be an integer, got {args[0]!r}")
    items = _load_idea_queue(ctx)
    if not (0 <= i < len(items)):
        return CommandResult.err(f"out of range: i={i} len={len(items)}")
    removed = items.pop(i)
    _save_idea_queue(ctx, items)
    return CommandResult.ok_msg(f"removed: {removed!r}")


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
    records = ctx.session_manager.list()
    if not records:
        return CommandResult.ok_msg("(no sessions)", data=[])
    lines = [
        f"  {r.id[:8]} {r.status:10s} {r.session_type:25s} {r.display_name}"
        for r in records
    ]
    return CommandResult.ok_msg("\n".join(lines), data=[r.id for r in records])


def _session_respawn(ctx: CommandContext, args: List[str]) -> CommandResult:
    # Signal the runtime to re-spawn on next rerun. We can't actually
    # rebuild cache_resource singletons from a handler; we set a scratch
    # flag the runtime reads.
    ctx.scratch["respawn_session"] = True
    return CommandResult.ok_msg("respawn flagged — will fire on next rerun")


def _session_spawn(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Spawn an additional claude-CLI session of any type.

    Usage: ``session.spawn <session_type> [display_name] [-- seed prompt]``

    The seed prompt is everything after ``--``. With no ``--``, the
    receiving session boots with no seed and waits for the next message.
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
    try:
        rec = ctx.session_manager.spawn(
            session_type=session_type,
            display_name=display_name,
            cwd=ctx.apeiron_root,
            seed_message=seed_message,
        )
    except Exception as exc:
        return CommandResult.err(f"spawn failed: {type(exc).__name__}: {exc}")
    return CommandResult.ok_msg(
        f"spawned {rec.display_name} id={rec.id[:8]} type={rec.session_type}",
        data={"id": rec.id, "type": rec.session_type, "name": rec.display_name},
    )


def _chat_target_path(ctx: CommandContext):
    return ctx.config.state_dir / "chat_target.txt"


def _session_target(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Route the chat panel + chat.send to a specific session id.

    Persists to ``state/workflow/chat_target.txt`` so the next rerun
    picks up the override. The app driver reads this on each rerun.
    """
    if not args:
        return CommandResult.err("usage: session.target <session_id|none>")
    target = args[0]
    target_path = _chat_target_path(ctx)
    if target.lower() in {"none", "off", "clear"}:
        try:
            target_path.unlink()
        except FileNotFoundError:
            pass
        ctx.active_session_id = None
        return CommandResult.ok_msg("chat target cleared")
    rec = ctx.session_manager.get(target)
    if rec is None:
        return CommandResult.err(f"no such session: {target}")
    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(rec.id, encoding="utf-8")
    ctx.active_session_id = rec.id
    return CommandResult.ok_msg(f"chat target → {rec.display_name} ({rec.id[:8]})")


def _session_send(ctx: CommandContext, args: List[str]) -> CommandResult:
    """Send a message to a specific session (any, not just the active one)."""
    if len(args) < 2:
        return CommandResult.err("usage: session.send <session_id> <message...>")
    sid = args[0]
    body = " ".join(args[1:]).strip()
    if not body:
        return CommandResult.err("empty message body")
    try:
        ctx.session_manager.send(sid, body)
    except Exception as exc:
        return CommandResult.err(f"send failed: {type(exc).__name__}: {exc}")
    return CommandResult.ok_msg(f"sent ({len(body)} chars) to {sid[:8]}")


def _session_archive(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: session.archive <session_id>")
    sid = args[0]
    try:
        ctx.session_manager.archive(sid)
    except Exception as exc:
        return CommandResult.err(f"archive failed: {type(exc).__name__}: {exc}")
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
    scenes_dir = ctx.apeiron_root / "scenes"
    if not scenes_dir.exists():
        return CommandResult.err("no scenes/ directory")
    names = sorted(p.name for p in scenes_dir.glob("*.json"))
    if not names:
        return CommandResult.ok_msg("(no scenes)", data=[])
    return CommandResult.ok_msg("\n".join(f"  {n}" for n in names), data=names)


def _scene_load(ctx: CommandContext, args: List[str]) -> CommandResult:
    if not args:
        return CommandResult.err("usage: scene.load <name>")
    name = args[0]
    scenes_dir = ctx.apeiron_root / "scenes"
    target = scenes_dir / (name if name.endswith(".json") else f"{name}.json")
    if not target.exists():
        return CommandResult.err(f"scene not found: {target.name}")
    try:
        ctx.engine.load_scene(target)
        ctx.engine.precompute()
    except Exception as exc:
        return CommandResult.err(f"load failed: {exc}")
    ctx.scratch["current_scene"] = target.name
    return CommandResult.ok_msg(f"loaded {target.name}")


def _scene_current(ctx: CommandContext, args: List[str]) -> CommandResult:
    current = ctx.scratch.get("current_scene") or ctx.config.default_scene
    return CommandResult.ok_msg(current, data=current)


def build_scene_commands() -> List[Command]:
    return [
        Command("scene.list", "list available scenes", _scene_list),
        Command("scene.load", "load a scene by name", _scene_load, arg_help="<name>"),
        Command("scene.current", "show currently-loaded scene", _scene_current),
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
    if not args:
        return CommandResult.err("usage: chat.send <message...>")
    text = " ".join(args).strip()
    if not text:
        return CommandResult.err("empty message")
    sid = ctx.active_session_id
    summary = text.replace("\n", " ")[:80]
    # Path 1: inbox echo for the chat panel UI.
    try:
        ctx.inbox.post(
            to=sid or "maintainer",
            kind="chat",
            summary=summary,
            body=text,
            sender="maintainer",
        )
    except Exception as exc:
        return CommandResult.err(f"inbox.post failed: {exc}")
    # Path 2: deliver to the session.
    if sid:
        try:
            ctx.session_manager.send(sid, text)
        except Exception as exc:
            return CommandResult.err(f"session.send failed: {exc}")
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
# Aggregate registration
# ---------------------------------------------------------------------------


def register_all(registry: CommandRegistry) -> None:
    """Register every command this module owns. Idempotent."""
    registry.register_many(build_idea_queue_commands())
    registry.register_many(build_session_commands())
    registry.register_many(build_scene_commands())
    registry.register_many(build_items_commands())
    registry.register_many(build_chat_commands())
    registry.register_many(build_meta_commands(registry))
