"""
FileSource — a data-source node-type. Reads a file, applies a named
parser, exposes the normalized item-list on an `items` channel.

Pairs with any renderer-node consuming the `items` channel (ListRenderer
is the first such). The orthogonality is the load-bearing design move:
data sources are interchangeable; renderers are interchangeable; a new
panel = one source-config + one renderer-config + one connection.

FileSource uses `precompute_hook` to do the read+parse work once at
build time and cache the result. emit() reads from the cache, so the
per-frame cost is constant regardless of source file size. The engine's
file-watcher (engine/file_watcher.py) already covers `node_types/` and
`renderers/`; future work wires it to invalidate FileSource caches when
arbitrary source paths change (wishlist #008).

The same primitive composes with the engine's failure isolation: a
broken parser leaves an error message on the items channel instead of
crashing the whole panel — the renderer downstream displays the error
in-place, which is what the maintainer wants for debuggable panels.
"""

from pathlib import Path
from typing import List

from engine.node import Channels, EmitContext, Manifest, View
from node_types.parsers import get_parser


def manifest() -> Manifest:
    return Manifest(
        name="FileSource",
        version="1.0",
        renderer_id="raster",
        inputs={
            "path": "string",
            "parser_name": "string",
        },
        outputs={"items": "list_of_dict", "source_path": "string"},
        description=(
            "Reads a file, applies a named parser, exposes normalized "
            "items on the 'items' channel. Pairs with any renderer that "
            "consumes 'items'."
        ),
    )


def build(params):
    return {
        "path": str(params.get("path", "")),
        "parser_name": str(params.get("parser_name", "")),
    }


def select_children(state, view: View, engine, node) -> List[str]:
    # Data-source nodes have no graphical children to recurse into.
    return []


def precompute_hook(state, engine, node):
    """Read file + parse once at build time; cache the items list."""
    path = state["path"]
    parser_name = state["parser_name"]

    if not path or not parser_name:
        return {"items": [], "error": "FileSource: 'path' and 'parser_name' both required"}

    try:
        text = Path(path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return {"items": [], "error": f"FileSource: file not found at {path}"}
    except OSError as e:
        return {"items": [], "error": f"FileSource: read failed: {e}"}

    try:
        parser = get_parser(parser_name)
    except (ImportError, AttributeError) as e:
        return {"items": [], "error": f"FileSource: parser '{parser_name}' not found ({e})"}

    try:
        items = parser(text)
    except Exception as e:
        return {"items": [], "error": f"FileSource: parser '{parser_name}' failed: {e}"}

    return {"items": items, "error": None}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Empty visual channels; items live in engine.cache, consumed by
    downstream renderer-nodes via ctx.engine.cache[source_node_id]."""
    cache_entry = ctx.engine.cache.get(ctx.node.id, {"items": [], "error": None})
    return {
        "items": cache_entry.get("items", []),
        "source_error": cache_entry.get("error"),
        "source_path": state["path"],
    }


def describe(state, ctx: EmitContext) -> str:
    cache_entry = ctx.engine.cache.get(ctx.node.id, {"items": [], "error": None})
    items = cache_entry.get("items", [])
    err = cache_entry.get("error")
    if err:
        return f"FileSource({state['path']}): error — {err}"
    return (
        f"FileSource(path={state['path']!r}, parser={state['parser_name']!r}, "
        f"items={len(items)})"
    )
