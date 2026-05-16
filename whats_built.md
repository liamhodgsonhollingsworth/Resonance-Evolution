# What's built — Apeiron

This page is Apeiron's index of what is implemented, what is partially implemented, and what is still open work. It is the canonical source for the project's current build state.

## What this index contains

Every load-bearing piece of Apeiron's implementation, grouped by area:

- **Engine core** — the precompute/assemble split, the manifest loader, the try/except isolation wrapper, the file-watch reload, the scene loader, the viewer state model.
- **Node types** — the catalog of node-type implementations under `node_types/`.
- **Renderers** — the catalog of renderer implementations under `renderers/`.
- **Bundle output** — the writer that emits color, depth, optional normal, optional ID, and a manifest, matching the painterly module engine's input contract.
- **Text-renderer surface** — the bidirectional LLM-facing interface for observation, action, inspection, and composition.
- **Build tooling** — scripts that run precompute, watch the graph for edits, and trigger incremental rebuilds.
- **Test suite** — tests covering node-type isolation, renderer-swap, topology walks, aggregator dispatch, and bundle output.

An item is "implemented" when it functions reliably and is in regular use. It is "partially implemented" when parts work but the full design is not in place. It is "open work" when the design exists but no implementation has been built yet.

## Engine core

- **Precompute/assemble split** — open work. The architectural commitment is in [architecture.md](architecture.md); no code yet.
- **Manifest loader** — open work. Loads node-type modules from `node_types/` by reading their `manifest()` function.
- **Try/except isolation wrapper** — open work. Wraps every `emit()` call; broken nodes return typed-zero placeholders.
- **File-watch reload** — open work. Re-imports node-type modules when their files change; rebuilds the affected sub-graph.
- **Scene loader** — open work. Reads `scenes/<name>.json` and instantiates the node graph.
- **Viewer state** — open work. Dataclass with position-in-current-node, orientation, and view-scale.

## Node types

(Skeleton — entries land here as node-type files migrate into `node_types/`.)

Starter node-types planned: Cube, Sphere, Group, Aggregator, Renderer, Portal, Computer, ChatInterface, TextRenderer.

## Renderers

(Skeleton — entries land here as renderer files migrate into `renderers/`.)

Starter renderers planned: software-raster (numpy + Pillow), ASCII-debug, TextRenderer.

## Bundle output

- **Color, depth, normal, ID writer** — open work. Writes `color.png`, `depth.png`, optional `normal.png`, optional `ids.png`, and `manifest.json` to an output directory matching the painterly module engine's input contract.

## Text-renderer surface

- **Observation channel** — open work. Renders the world's state at the viewer's current position and scale as text.
- **Action channel** — open work. Accepts text commands (move, add, edit, link, render) and applies them to the graph or viewer state.
- **Inspection channel** — open work. Surfaces node state, connection topology, and dispatch tables as text.
- **Composition support** — open work. Lets an LLM write new node-types and renderers, then use them via hot-reload.

## Build tooling

(Skeleton — entries land here as tooling migrates into `tools/`.)

## Test suite

(Skeleton — entries land here as the test suite is built.)

## How to modify this page

This page is an [evolving index](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/evolving_indexes.md).

- **Linking.** When a piece of implementation lands in the repo, add it under the appropriate area with a one-sentence description of what it does and its current state (implemented / partially implemented / open work).
- **Promoting.** A sub-area becomes its own page when it grows enough to warrant separate structure — for example, "Renderers" could split into a top-level Atlas entry once it has many renderer variants.

The trigger for an entry: a piece of work has changed state (implementation has started, is partial, has completed) or has been added to the project. State changes are tracked by appending a dated note rather than overwriting; the history of build state is itself part of the project's record.

## Deferred improvements

(Empty at first creation.)
