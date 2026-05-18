"""
Parsers turn raw source text (file content, MCP tool result) into a
normalized item-list that any renderer consumes. The shared item shape
is:

    {
        "id":      str,           # stable across reads; used for selection / expand
        "title":   str,           # one-line label shown by every renderer
        "body":    str,           # optional longer text
        "status":  str | None,    # "pending" / "done" / "in_progress" / "granted" / ...
        "meta":    dict,          # parser-specific extras (line number, tier, etc.)
        "actions": list[str],     # action verbs this item supports (default: ["expand"])
    }

A parser exposes one function:

    def parse(text: str) -> list[dict]

Parsers should call ``attach_default_actions(items)`` as the last step
before returning so every item carries an ``actions`` field. The default
is ``["expand"]`` — every item is expandable. Parsers may set richer
``actions`` per-item (e.g. ``["expand", "mark_done", "delete"]``) before
calling the helper; the helper only fills in items that lack the field.

The action verbs declared here are consumed by ``engine.actions.dispatch_action``
when an action is invoked against an item. A renderer that wants to handle
an action exposes ``handle_action(state, action_name, payload, engine, node)
-> state_delta`` (see ``node_types/list_renderer.py`` for the v1
implementation).

Modules in this directory are auto-discoverable by name from FileSource
and MCPSource via their `parser_name` param.
"""

from importlib import import_module
from typing import Callable, List, Dict, Any


DEFAULT_ACTIONS: List[str] = ["expand"]


def get_parser(name: str) -> Callable[[str], List[Dict[str, Any]]]:
    """Look up a parser by short name (e.g. 'tasks' -> node_types.parsers.tasks)."""
    module = import_module(f"node_types.parsers.{name}")
    return module.parse


def attach_default_actions(
    items: List[Dict[str, Any]],
    default: List[str] | None = None,
) -> List[Dict[str, Any]]:
    """
    Ensure every item carries an ``actions`` field. Items that already
    define ``actions`` keep their declared list; items without one get a
    copy of ``default`` (or :data:`DEFAULT_ACTIONS` when no override).

    Returns the same list (mutated in place) for chaining convenience.
    """
    fallback = list(default if default is not None else DEFAULT_ACTIONS)
    for item in items:
        if "actions" not in item or item["actions"] is None:
            item["actions"] = list(fallback)
    return items
