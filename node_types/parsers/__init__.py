"""
Parsers turn raw source text (file content, MCP tool result) into a
normalized item-list that any renderer consumes. The shared item shape
is:

    {
        "id":     str,           # stable across reads; used for selection / expand
        "title":  str,           # one-line label shown by every renderer
        "body":   str,           # optional longer text
        "status": str | None,    # "pending" / "done" / "in_progress" / "granted" / ...
        "meta":   dict,          # parser-specific extras (line number, tier, etc.)
    }

A parser exposes one function:

    def parse(text: str) -> list[dict]

Modules in this directory are auto-discoverable by name from FileSource
and MCPSource via their `parser_name` param.
"""

from importlib import import_module
from typing import Callable, List, Dict, Any


def get_parser(name: str) -> Callable[[str], List[Dict[str, Any]]]:
    """Look up a parser by short name (e.g. 'tasks' -> node_types.parsers.tasks)."""
    module = import_module(f"node_types.parsers.{name}")
    return module.parse
