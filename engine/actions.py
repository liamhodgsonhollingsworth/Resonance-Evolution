"""
Action dispatch: route a named action against a renderer+item pair to
the renderer's handle_action hook, merging the resulting state-delta
into the per-renderer view-state.

The action primitive composes the wish cluster around per-item
interactions: expand-to-show-body (wish #006), add-button (wish #015),
mark-done / delete / edit per-item verbs (future Tier B and Tier C
panels). One dispatcher, one hook on each renderer that wants to react,
one cache slot per renderer for the resulting view-state.

API:
    dispatch_action(engine, renderer_id, action_name, item_id=None,
                    payload=None) -> tuple[bool, str]
        Look up the renderer; resolve the item via the renderer's source
        connection when item_id is given; validate the action against
        the item's declared ``actions`` list when applicable; call the
        renderer's ``handle_action`` hook; merge the returned delta into
        ``engine.cache["__view_state__"][renderer_id]``. Returns
        ``(success, message)``. Module isolation: a broken handler does
        not crash dispatch — it returns ``(False, error_msg)``.

    resolve_target(target, parent_node_id="") -> ResolvedTarget
        Decode a ButtonNode-shape ``target`` field into a
        ``(kind, target_id, payload_extras)`` triple suitable for
        feeding into ``dispatch_action``. Used by the GUI shell's
        click-dispatch layer to route button clicks through the same
        action surface (SPEC-077). See module docstring for the
        prefix-set.

    get_view_state(engine, renderer_id) -> dict
        Read the per-renderer view-state dict (creating an empty one if
        absent). Returned dict is the live cache slot — callers needing
        isolation should copy it.

State location:
    ``engine.cache["__view_state__"][renderer_id]`` -> dict

    Sibling to other reserved cache keys (``__lights__``,
    ``__gravity_fields__``). Survives ``engine.precompute()`` re-runs
    (precompute writes to ``engine.cache[node_id]`` only). Survives
    ``engine.reload_type`` (which touches sys.modules, not
    ``engine.cache``). Lives outside ``node.state`` because node.state
    is the build-time output and isn't intended to be mutated at
    runtime.

Renderer-side hook:
    ``handle_action(state, action_name, payload, engine, node) -> dict | None``

    ``payload`` is a dict containing at least:
        - ``item_id`` (str | None): the targeted item's id, or None
          when the action is renderer-scoped (e.g. ``collapse``).
        - ``item`` (dict | None): the targeted item itself, or None.
        - any caller-supplied keys.

    Returns a state_delta dict — keys merged into the view-state via
    ``dict.update``. Returns ``None`` or ``{}`` for no-op (the action
    ran but did not change state).

ButtonNode target-prefix grammar (SPEC-077):

    ""              -> dispatch against ``parent_node_id`` (the
                       decorated node, i.e. the button's owner).
    "panel:<id>"    -> dispatch against ``<id>`` (treated as a
                       renderer-id).
    "node:<id>"     -> dispatch against ``<id>`` (must declare
                       ``handle_action``).
    "session:<id>"  -> the chat-target routing path (SPEC-068).
                       The shell consumer reads ``chat_target=<id>``
                       from the resolved payload-extras and routes
                       through ``route_chat`` / ``set_active_session``.
    "view:<name>"   -> ``set_view(<name>)`` on the GUI shell
                       (SPEC-067). The kind is exposed so the click
                       handler can short-circuit instead of going
                       through ``dispatch_action``.

A broken or unknown prefix returns ``kind="unknown"`` so the caller
fails closed with a clear error message rather than dispatching
against a bogus renderer.
"""

from __future__ import annotations

import traceback
from dataclasses import dataclass, field
from typing import Any, Dict, Optional, Tuple, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.core import Engine
    from engine.node import NodeInstance


VIEW_STATE_CACHE_KEY = "__view_state__"


# ---------------------------------------------------------------------------
# Target-prefix decoder for ButtonNode (SPEC-077).
# ---------------------------------------------------------------------------


@dataclass
class ResolvedTarget:
    """The decoded form of a ButtonNode ``target`` field.

    Fields:

    - ``kind``: one of ``"self"`` (no prefix), ``"panel"``, ``"node"``,
      ``"session"``, ``"view"``, ``"unknown"``.
    - ``target_id``: the id / name extracted after the prefix. Equals
      ``parent_node_id`` for ``kind="self"``; equals the parsed body
      for the named prefixes; empty for ``"unknown"`` AND for the
      cases where ``self`` was requested without a parent.
    - ``payload_extras``: additional payload keys the dispatcher
      should fold into the click-payload. Currently only used by
      ``session:`` (which injects ``chat_target``); future prefixes
      can extend.
    - ``raw_target``: the input string, preserved for error messages.
    """

    kind: str
    target_id: str
    payload_extras: Dict[str, Any] = field(default_factory=dict)
    raw_target: str = ""

    def is_dispatchable(self) -> bool:
        """True iff this target can feed into ``dispatch_action`` directly.

        ``view`` is NOT dispatchable through the action surface — the
        click handler should call ``shell.set_view`` instead.
        ``unknown`` is never dispatchable. Empty ids fail closed.
        """
        if self.kind in {"unknown", "view"}:
            return False
        return bool(self.target_id)


_TARGET_PREFIXES = ("panel:", "node:", "session:", "view:")


def resolve_target(target: str, parent_node_id: str = "") -> ResolvedTarget:
    """Decode a ButtonNode ``target`` field.

    Empty string ⇒ self-resolution against ``parent_node_id``. A
    recognised prefix ⇒ the named kind + the id after the colon. An
    unrecognised non-empty value with no prefix ⇒ ``"unknown"`` so the
    caller surfaces the error rather than dispatching against the raw
    string (which would otherwise look like a node-id and silently
    try-and-fail downstream).
    """
    raw = str(target or "")
    if not raw:
        return ResolvedTarget(
            kind="self",
            target_id=parent_node_id or "",
            raw_target=raw,
        )
    for prefix in _TARGET_PREFIXES:
        if raw.startswith(prefix):
            kind = prefix[:-1]
            body = raw[len(prefix):]
            payload_extras: Dict[str, Any] = {}
            if kind == "session":
                payload_extras["chat_target"] = body
            return ResolvedTarget(
                kind=kind,
                target_id=body,
                payload_extras=payload_extras,
                raw_target=raw,
            )
    return ResolvedTarget(
        kind="unknown",
        target_id="",
        raw_target=raw,
    )


def dispatch_action(
    engine: "Engine",
    renderer_id: str,
    action_name: str,
    item_id: Optional[str] = None,
    payload: Optional[Dict[str, Any]] = None,
) -> Tuple[bool, str]:
    """
    Dispatch a named action against a renderer; see module docstring.

    item_id is optional — when None or empty, the action is treated as
    renderer-scoped (no item validation; payload's item_id/item come
    through as None). Renderer-scoped actions include things like
    ``collapse``, ``refresh``, ``scroll-up`` that target the whole
    renderer rather than a single item.
    """
    renderer = engine.nodes.get(renderer_id)
    if renderer is None:
        return False, f"unknown renderer: {renderer_id!r}"
    if renderer.dead:
        err_line = renderer.error.splitlines()[0] if renderer.error else "no error msg"
        return False, f"renderer is dead: {renderer_id!r} ({err_line})"

    module = engine.types.get(renderer.type_name)
    if module is None:
        return False, f"renderer module not loaded: type={renderer.type_name!r}"
    if not hasattr(module, "handle_action"):
        return False, (
            f"renderer type {renderer.type_name!r} does not declare handle_action"
        )

    full_payload: Dict[str, Any] = dict(payload or {})
    if item_id is not None and item_id != "":
        item = _resolve_item(engine, renderer, item_id)
        if item is None:
            return False, (
                f"item {item_id!r} not found in renderer {renderer_id!r}'s source"
            )
        declared_actions = item.get("actions") or []
        if action_name not in declared_actions:
            return False, (
                f"action {action_name!r} not declared on item {item_id!r}; "
                f"declared actions: {declared_actions!r}"
            )
        full_payload.setdefault("item_id", item_id)
        full_payload.setdefault("item", item)
    else:
        full_payload.setdefault("item_id", None)
        full_payload.setdefault("item", None)

    try:
        delta = module.handle_action(
            renderer.state, action_name, full_payload, engine, renderer
        )
    except Exception as e:
        engine.errors.append(
            f"handle_action({renderer_id}, {action_name}): {e}\n{traceback.format_exc()}"
        )
        return False, f"handle_action raised: {e}"

    if delta:
        view_state = get_view_state(engine, renderer_id)
        view_state.update(delta)

    suffix = f" (item={item_id})" if item_id else ""
    return True, f"dispatched {action_name!r} on {renderer_id}{suffix}"


def get_view_state(engine: "Engine", renderer_id: str) -> Dict[str, Any]:
    """
    Return the per-renderer view-state dict, creating an empty one if
    absent. The returned dict is the live cache slot — modifying the
    returned dict modifies the stored state. Defensive readers copy if
    they need isolation.
    """
    by_renderer = engine.cache.setdefault(VIEW_STATE_CACHE_KEY, {})
    return by_renderer.setdefault(renderer_id, {})


def dispatch_button(
    engine: "Engine",
    button_node_id: str,
) -> Tuple[bool, str]:
    """Dispatch a ButtonNode's action through the action surface (SPEC-077).

    Resolves the button's ``target`` prefix via :func:`resolve_target`,
    then routes through :func:`dispatch_action` for the dispatchable
    kinds (``self`` / ``panel`` / ``node`` / ``session``). For
    ``view:<name>`` the function fails closed with an explanatory
    message — view-switching belongs to the shell layer, not the
    engine.

    ``button_node_id`` MUST be a ButtonNode (``type_name="ButtonNode"``).
    Any other type returns ``(False, …)``; module isolation means the
    caller does not crash on a bad id.

    The payload forwarded to ``dispatch_action`` carries the button's
    ``payload`` dict plus the target's ``payload_extras`` plus a
    ``button_id`` key referring back to the source button (so a
    handler can read the button's metadata when needed).
    """
    button = engine.nodes.get(button_node_id)
    if button is None:
        return False, f"unknown button node: {button_node_id!r}"
    if button.dead:
        err = button.error.splitlines()[0] if button.error else "no error msg"
        return False, f"button node is dead: {button_node_id!r} ({err})"
    if button.type_name != "ButtonNode":
        return False, (
            f"node {button_node_id!r} is type {button.type_name!r}, "
            f"not ButtonNode"
        )

    state = button.state or {}
    action_name = state.get("action") or ""
    if not action_name:
        return False, f"button {button_node_id!r} has no action"

    target_str = state.get("target") or ""
    parent_id = state.get("parent") or ""
    resolved = resolve_target(target_str, parent_node_id=parent_id)

    if resolved.kind == "unknown":
        return False, (
            f"button {button_node_id!r}: unrecognised target prefix "
            f"in {resolved.raw_target!r}"
        )
    if resolved.kind == "view":
        # The shell layer (gui_shell.set_view) handles this. Surface a
        # message that names the desired view so the click handler can
        # route appropriately without dispatching through the engine
        # action surface.
        return False, (
            f"button {button_node_id!r}: target view={resolved.target_id!r} "
            f"belongs to the shell layer; call shell.set_view directly"
        )
    if not resolved.target_id:
        return False, (
            f"button {button_node_id!r}: target {resolved.raw_target!r} "
            f"resolves to an empty id (parent={parent_id!r})"
        )

    button_payload = dict(state.get("payload") or {})
    full_payload: Dict[str, Any] = {**button_payload, **resolved.payload_extras}
    full_payload["button_id"] = button_node_id

    return dispatch_action(
        engine,
        renderer_id=resolved.target_id,
        action_name=action_name,
        item_id=button_payload.get("item_id"),
        payload=full_payload,
    )


def _resolve_item(
    engine: "Engine",
    renderer: "NodeInstance",
    item_id: str,
) -> Optional[Dict[str, Any]]:
    """
    Read the renderer's source-cache items list and return the item
    whose id matches. Returns None if no source connection exists, the
    source has no cached items, or no item matches.
    """
    source_conn = renderer.connections.get("source")
    if source_conn is None:
        return None
    if isinstance(source_conn, str):
        source_id = source_conn
    elif isinstance(source_conn, dict):
        source_id = source_conn.get("target", "")
    elif isinstance(source_conn, list) and source_conn:
        source_id = source_conn[0]
    else:
        return None
    cache_entry = engine.cache.get(source_id, {})
    if not isinstance(cache_entry, dict):
        return None
    for item in cache_entry.get("items") or []:
        if item.get("id") == item_id:
            return item
    return None
