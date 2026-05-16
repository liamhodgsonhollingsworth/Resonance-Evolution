"""
LambertianShader — deferred-shading-style renderer-node. Reads the
source sub-graph's color + normal channels and the engine's shared
lights cache; outputs lit color via the standard Lambertian model:

    lit_color = base_color * (ambient + sum_lights(light_color * intensity * max(0, n·-l_dir)))

For each light, max(0, normal · -light_direction) gives the diffuse
intensity (the light_direction vector points FROM the light source
toward illuminated surfaces, so the surface normal pointing back at
the light gives positive dot product).

Demonstrates the deferred-shading architecture: primitives emit
geometry channels (color + normal + depth + ids); a separate
renderer-node consumes them and applies lighting. Adding new light
types (point, spot, area) doesn't require touching primitive emit
code — they just register richer metadata in engine.cache["__lights__"]
and the shader picks them up.
"""

import numpy as np
from engine.node import Channels, EmitContext, Manifest, View


def manifest() -> Manifest:
    return Manifest(
        name="LambertianShader",
        version="1.0",
        renderer_id="raster",
        inputs={"ambient": "float"},
        outputs={"color": "rgb_image", "depth": "depth_image", "normal": "vec3_image"},
        description=(
            "Reads source's color + normal channels, applies Lambertian "
            "lighting from engine.cache['__lights__']. Deferred-shading "
            "split between primitive (geometry channels) and renderer "
            "(lit output)."
        ),
    )


def build(params):
    return {
        "ambient": float(params.get("ambient", 0.15)),
    }


def emit(state, view: View, ctx: EmitContext) -> Channels:
    source = ctx.child_outputs.get("source")
    if source is None:
        return _empty_channels(view)
    _, channels = source
    color = channels.get("color")
    normal = channels.get("normal")
    if color is None or normal is None:
        return channels

    lights = ctx.engine.cache.get("__lights__", [])
    ambient = state["ambient"]

    # Per-pixel shading factor; starts at ambient
    shading = np.full(color.shape, ambient, dtype=np.float32)

    for light in lights:
        light_dir = np.asarray(light["direction"], dtype=np.float32)
        light_color = np.asarray(light["color"], dtype=np.float32)
        intensity = float(light["intensity"])
        # Diffuse: max(0, normal · -light_dir)
        diffuse = np.maximum(0.0, -(normal * light_dir[None, None, :]).sum(axis=-1))
        shading = shading + light_color[None, None, :] * (diffuse[..., None] * intensity)

    lit = np.clip(color * shading, 0.0, 1.0).astype(np.float32)
    result = dict(channels)
    result["color"] = lit
    return result


def describe(state, ctx: EmitContext) -> str:
    return (f"LambertianShader id={ctx.node.id} ambient={state['ambient']:.2f}")


def _empty_channels(view: View) -> Channels:
    return {
        "color": np.zeros((view.height, view.width, 3), dtype=np.float32),
        "depth": np.full((view.height, view.width), np.inf, dtype=np.float32),
    }
