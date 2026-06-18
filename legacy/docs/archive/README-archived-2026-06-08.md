# Archived README sections — 2026-06-08

These sections were removed from the root `README.md` during the
README audit/refresh on 2026-06-08 because they no longer described the
project's current state. They are preserved here verbatim under the
append-only invariant (this repository never deletes content; outdated
material is archived, not erased).

## Why archived

The original "Tools and features that exist" and "Features being
developed" prose described Apeiron as a small early-stage raster engine
with roughly a dozen node-types and a handful of renderers, and listed
Sphere, Plane, the painterly post-processor, the browser renderer, and a
LLM chat interface as *future / in-progress* work. By 2026-06-08 all of
those had shipped, and the project had grown a large workflow /
session-management substrate (WorkflowView panels, the realtime
renderer, a Streamlit GUI, a session manager driving real `claude` CLI
subprocesses, an auth/trust layer, ~50 node-types, ~190 renderer/UI
widgets, and roughly 1,800 test functions). The "Features being
developed" list in particular had become actively misleading — it
presented shipped features as not-yet-built.

The refreshed README points at `whats_built.md` as the canonical,
continuously-updated index of implementation state, and gives a current
high-level picture instead of the frozen early-stage snapshot below.

The `LICENSE` section was also updated: the original framed the licence
as an MIT "placeholder; the license stack is a deferred decision at the
meta-layer". The repository now ships a real MIT `LICENSE` file, so the
placeholder/deferred framing was removed.

---

## Archived: "Tools and features that exist" (original prose)

> Major working components of Apeiron. The high-level shape is here; detailed status, sub-features, and open issues live in [What's built](../../whats_built.md).
>
> - **Engine core** — discovery of node-type files in `node_types/` and `renderers/`, spawn with try/except isolation, assemble walking the graph from a viewer with module-isolated emit() calls, default Z-buffer compositor plus list-concat text compositor, scene loader from JSON, hot-reload entry point.
> - **Cube node-type** — axis-aligned cube with ray-cast emit() against AABB; produces color, depth, and IDs channels with Lambertian-ish shading.
> - **Sphere node-type** — sphere primitive with smooth normal-based shading; same channel contract as Cube.
> - **Plane node-type** — bounded floor primitive (XZ plane, normal +Y); walls and ceilings via rotation transforms.
> - **Light node-type + LambertianShader renderer-node** — directional lights register themselves in `engine.cache["__lights__"]` at precompute time; LambertianShader reads the cache plus source's color and normal channels, outputs lit color via standard `base * (ambient + Σ light·diffuse)`. Deferred-shading-style separation between geometry and lighting; new light types add as new node-types registering richer cache metadata.
> - **Group node-type** — container that composites its children via the engine's default compositor.
> - **Portal node-type** — rectangular doorway whose "through" connection's 4x4 transform places the far-side sub-graph at any pose; demonstrates topology-over-coordinates, since impossible geometries fall out of non-identity connection transforms rather than special-cased engine code.
> - **Aggregator node-type** — observes its "target" sub-graph, precomputes centroid + bounding-box + average-color, and dispatches at emit time between a colored-AABB impostor (far view) and the target's full render (near view); demonstrates aggregator-as-node, emergence-at-scale, and precomputation-moves-heavy-work-to-build-time simultaneously. The engine's new `select_children` hook lets the aggregator skip the target's runtime render entirely when the impostor is in use, so precomputation is real rather than aspirational.
> - **Computer node-type** — owns both a rectangular screen in outer world space and the internal camera that renders its "running" sub-graph; uses `select_children` to skip the engine's default recursion and calls `ctx.engine.assemble` itself with the constructed internal view, then pastes the internal render onto the screen rectangle via UV sampling. Demonstrates renderer-as-node, screen-region-ownership, and unbounded recursive worlds (a Computer's sub-graph can contain another Computer; recursion falls out of the engine's normal traversal).
> - **PainterlyPostProcessor renderer-node** — wraps a "source" sub-graph, consumes its bundle channels (color + ids), and applies palette reduction plus ID-edge darkening to produce painterly output. The first bundle-consuming renderer; validates the bundle format as a pipeline seam between an upstream content stage and downstream stylistic stages.
> - **ChatInterface node-type** — owns a screen rectangle in the outer world and renders the contents of a chat log file onto it via PIL text rendering. The "side channel" to Claude Code is the file itself, so the system contains the authoring tool as a node inside the system being authored.
> - **TextRenderer** — the first-class bidirectional LLM-facing surface; walks its wrapped sub-graph, produces structured text output (view state, scene topology, observations, command grammar) via the `text` channel.
> - **AsciiDebug renderer** — depth channel rendered as ASCII art for text-mode topology debugging.
> - **Bundle writer** — emits `color.png`, `depth.png`, `depth.npy`, optional `normal.png` and `ids.png`, and `manifest.json` matching the painterly module engine's input contract.
> - **CLI tools** — `python -m tools.render <scene>` writes a bundle; `python -m tools.text_test` provides describe/view/summary/command subcommands for text-based testing.
> - **Text testing tools** — `describe_scene`, `describe_view`, `summarize_bundle`, `dispatch_command`, `assert_visible` — the LLM-facing verification surface; once visuals are confirmed, new features can be built and verified through these tools alone.
> - **Test suite** — 15 pytest tests covering discovery, spawn, assemble, bundle output, text-renderer, command dispatcher, visibility, and module isolation (a deliberately-broken node-type doesn't crash the engine).
> - **Starter scenes** — `scenes/hello_cube.json` (single cube, raster output) and `scenes/text_demo.json` (TextRenderer wrapping a group of cubes).

## Archived: "Features being developed" (original prose)

> Active in-progress work; detailed status in [What's built](../../whats_built.md).
>
> - **Focus-state for Computer** — flip-flag plus engine API for full-frame takeover, so the viewer can "enter" a Computer and the outer world stops rendering entirely; the v1 Computer node-type's interface is preserved.
> - **File-watch reload** — auto-trigger hot-reload when node-type files change on disk.
> - **More node-types and renderers** — Sphere, Plane, Cylinder, painterly post-processor, OpenGL renderer, browser renderer, etc.

## Archived: "License" section (original prose)

> [MIT License](../../LICENSE) — placeholder; the license stack is a deferred decision at the meta-layer.
