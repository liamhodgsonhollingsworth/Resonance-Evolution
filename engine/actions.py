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
"""

from __future__ import annotations

import traceback
from typing import Any, Dict, Optional, Tuple, TYPE_CHECKING

if TYPE_CHECKING:
    from engine.core import Engine
    from engine.node import NodeInstance


VIEW_STATE_CACHE_KEY = "__view_state__"


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
