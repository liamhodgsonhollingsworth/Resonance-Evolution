"""
Group — composes its children into a single rendered output via the
engine's default compositor. Useful for organizing scenes hierarchically
without adding rendering logic.

A Group has no params of its own; its connections name its children.
"""

from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="Group",
        version="1.0",
        renderer_id="raster",
        description="Container that composites its children. No rendering logic of its own.",
    )


def build(params):
    return {}


def emit(state, view: View, ctx: EmitContext) -> Channels:
    """Composite children using the engine's default compositor."""
    return ctx.engine._composite_children(ctx.child_outputs, view)


def describe(state, ctx: EmitContext) -> str:
    child_count = len(ctx.node.connections)
    return f"Group id={ctx.node.id} children={child_count}"
