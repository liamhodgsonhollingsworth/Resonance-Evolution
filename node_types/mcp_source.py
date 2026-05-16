"""
MCPSource — calls an Alethea-cc MCP tool, applies a named parser,
exposes the normalized item-list on an `items` channel.

The companion to FileSource. Together they form the DataSource family;
any renderer-node consuming the `items` channel pairs with either.

Architectural choices:

  - **Direct Python import of the MCP server.** The Alethea-cc MCP
    server's tools are FastMCP-decorated functions; the decorator is
    transparent so the underlying functions remain callable as plain
    Python. The adapter pushes `Alethea-cc/tools` onto sys.path and
    imports the named tool function by name.

  - **precompute_hook for the call, not emit().** MCP calls take
    50-500ms; emit() runs per-frame. The hook fires once at build,
    caches under the node-id; emit reads from cache.

  - **Graceful degrade if the MCP server can't be imported.** Apeiron
    runs as a standalone engine; the alethea integration is optional.
    Missing `mcp` package or missing alethea_mcp_server.py results in
    items=[] plus an error message, NOT a crash.

  - **Optional parser.** Many MCP tools return structured dicts/lists
    already; if `parser_name` is empty the raw result lands on a `raw`
    channel and items=[]. If parser_name is provided, the parser is
    called on the tool's stringified result.

The maintainer's wishlist item #001 is granted by this node; future
panels (#016 Email, #017 Calendar, #018 Journal, #019 Corpus-browser)
all become MCPSource(tool_name=X, parser_name=Y) + ListRenderer
compositions per the mount_panel skill.
"""

import os
import sys
from typing import List

from engine.node import Channels, EmitContext, Manifest, View
from node_types.parsers import get_parser


# Default search paths for the Alethea-cc MCP server. The first one to
# resolve wins. Add more if your checkout sits elsewhere.
DEFAULT_ALETHEA_TOOLS_PATHS = [
    r"C:\Users\Liam\Desktop\Alethea\Alethea-cc\tools",
    os.path.expanduser("~/Desktop/Alethea/Alethea-cc/tools"),
]


def manifest() -> Manifest:
    return Manifest(
        name="MCPSource",
        version="1.0",
        renderer_id="raster",
        inputs={
            "tool_name": "string",
            "tool_args": "dict",
            "parser_name": "string",
            "alethea_tools_path": "string",
        },
        outputs={
            "items": "list_of_dict",
            "raw": "any",
            "source_error": "string",
        },
        description=(
            "Calls an Alethea-cc MCP tool, optionally parses the result "
            "into normalized items. Pairs with any items-consuming "
            "renderer. Graceful degrade if MCP server unavailable."
        ),
    )


def build(params):
    return {
        "tool_name": str(params.get("tool_name", "")),
        "tool_args": dict(params.get("tool_args", {})),
        "parser_name": str(params.get("parser_name", "")),
        "alethea_tools_path": str(params.get("alethea_tools_path", "")),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    return []


def precompute_hook(state, engine, node):
    """Import the tool, call it with state['tool_args'], optionally
    parse, cache result."""
    if not state["tool_name"]:
        return {"items": [], "raw": None, "error": "MCPSource: tool_name required"}

    tool_fn = _resolve_tool(state["tool_name"], state.get("alethea_tools_path", ""))
    if tool_fn is None:
        return {
            "items": [],
            "raw": None,
            "error": (
                f"MCPSource: could not import tool {state['tool_name']!r}. "
                "Alethea-cc not on path or `mcp` package missing."
            ),
        }

    try:
        raw = tool_fn(**state["tool_args"])
    except Exception as e:
        return {
            "items": [],
            "raw": None,
            "error": f"MCPSource: tool {state['tool_name']!r} raised: {e}",
        }

    if not state["parser_name"]:
        return {"items": [], "raw": raw, "error": None}

    try:
        parser = get_parser(state["parser_name"])
    except (ImportError, AttributeError) as e:
        return {"items": [], "raw": raw, "error": f"MCPSource: parser {state['parser_name']!r} not found ({e})"}

    try:
        items = parser(_stringify(raw))
    except Exception as e:
        return {"items": [], "raw": raw, "error": f"MCPSource: parser failed: {e}"}

    return {"items": items, "raw": raw, "error": None}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    cache_entry = ctx.engine.cache.get(
        ctx.node.id, {"items": [], "raw": None, "error": None}
    )
    return {
        "items": cache_entry.get("items", []),
        "raw": cache_entry.get("raw"),
        "source_error": cache_entry.get("error"),
        "tool_name": state["tool_name"],
    }


def describe(state, ctx: EmitContext) -> str:
    cache_entry = ctx.engine.cache.get(
        ctx.node.id, {"items": [], "raw": None, "error": None}
    )
    items = cache_entry.get("items", [])
    err = cache_entry.get("error")
    if err:
        return f"MCPSource(tool={state['tool_name']}): error — {err}"
    return (
        f"MCPSource(tool={state['tool_name']!r}, parser={state['parser_name']!r}, "
        f"items={len(items)})"
    )


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_TOOL_CACHE: dict[str, object] = {}


def _resolve_tool(tool_name: str, override_path: str):
    """Locate and return the named tool function from the Alethea-cc
    MCP server. Cached after first resolution. Returns None on failure."""
    if tool_name in _TOOL_CACHE:
        return _TOOL_CACHE[tool_name]

    paths = [override_path] if override_path else []
    paths.extend(DEFAULT_ALETHEA_TOOLS_PATHS)

    candidate_paths = [p for p in paths if p and os.path.isdir(p)]
    if not candidate_paths:
        return None

    # Suppress side-effects from MCP server's import-time work
    os.environ.setdefault("ALETHEA_AUTO_NOTION_SYNC", "0")

    for path in candidate_paths:
        if path not in sys.path:
            sys.path.insert(0, path)
        try:
            module = __import__("alethea_mcp_server")
            tool_fn = _unwrap(getattr(module, tool_name, None))
            if tool_fn is not None and callable(tool_fn):
                _TOOL_CACHE[tool_name] = tool_fn
                return tool_fn
        except (ImportError, AttributeError):
            continue

    return None


def _unwrap(fn):
    """FastMCP's @mcp.tool() wraps the function; some versions expose
    the original via __wrapped__. Try a few unwrap conventions."""
    if fn is None:
        return None
    for attr in ("__wrapped__", "fn", "_fn", "func"):
        inner = getattr(fn, attr, None)
        if inner is not None and callable(inner):
            return inner
    return fn  # plain callable already


def _stringify(raw) -> str:
    """Convert an MCP tool result to text for a string-input parser."""
    if isinstance(raw, str):
        return raw
    if isinstance(raw, (list, dict)):
        import json
        return json.dumps(raw, default=str)
    return str(raw)
