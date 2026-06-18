# *"Any sufficiently immersive science fiction work is indistinguishable from reality."*

# Apeiron

A node-graph engine for building, rendering, and inhabiting worlds. Every world-object, every renderer, every aggregation rule, every text-interaction surface is a node. The graph is the medium; renderers are nodes that turn the graph into output (visual, textual, or compositional); aggregation nodes turn fine-scale structure into coarse-scale emergent behavior. Produces image bundles (color, depth, optional normal, optional ID) that feed the [painterly module engine](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/ideas/painterly_module_engine.md) and exposes a text-renderer surface so Claude Code can interact with the world as fully as a human could. A project in the [Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront) network.

> **Naming note.** "Resonance Polymathematics" is the corporate entity name used for business and licensing matters. "Resonance Wavefront" is the sci-fi creative project / meta-layer. The two are distinct and should not be conflated. Apeiron is a project within the Resonance network and inherits this distinction.

> **Working name.** "Apeiron" is a placeholder name — better-name suggestions go in [name_suggestions.md](name_suggestions.md).

## Atlas

- **[Current state](whats_built.md)** — canonical index of what is and is not implemented for Apeiron, listing every node-type, renderer, engine module, and tooling component with implementation status.
  - **[Tools and features that exist](#tools-and-features-that-exist)** — the working components: the engine core, the node-type and renderer catalogs, the bundle output, the text-renderer surface, the realtime renderer, and the workflow / session-management shell.
  - **[Features being developed](#features-being-developed)** — active in-progress and open work.
- **[Architecture](architecture.md)** — the load-bearing design commitments: the single `emit` primitive, topology over coordinates, channels-by-name wires, aggregator-as-node, renderer-as-node, build-vs-runtime split, module isolation, text-renderer as first-class.
- **[Node types](#node-types)** — the catalog of node-type implementations; each is one file under `node_types/`.
- **[Renderers](#renderers)** — the catalog of renderer implementations; each is one file under `renderers/`.
- **[Scenes](#scenes)** — the data graphs that get rendered; each is one JSON file under `scenes/`.
- **[Engine](#engine)** — the core code that loads node-types, walks the graph, precomputes aggregations, and assembles frames.
- **[Conventions](#conventions)** — project-specific conventions; the meta-layer's apply by default.
- **[Meta-conventions](#meta-conventions)** — the meta-layer's apply directly; project-specific overrides land here.

This page is a [static index](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/index_pages.md).

## Tools and features that exist

Major working components of Apeiron. The high-level shape is here; the
exhaustive, continuously-updated status of every node-type, renderer,
engine module, and tool — with per-item implemented / partial / open
markings — is the job of [What's built](whats_built.md), which is the
canonical index. The list below is the front-page summary, not the full
catalog.

- **Engine core** — file-based discovery of node-type and renderer modules, spawn with try/except module isolation (a broken node-type only breaks itself), graph-walking `assemble()` from a viewer, a `precompute()` / `sim_precompute()` build-time pass, the `select_children` recursion-control hook, hot-reload of edited modules, a polling file-watcher that registers newly-written node-types without a restart, a JSON scene loader, named-channel wires, and connection-transform topology. Lives in `engine/`.
- **Geometry and lighting node-types** — Cube, Sphere, Plane, Group, Portal (topology-over-coordinates doorways), Aggregator (precomputed impostor / full-render dispatch by viewer distance), Computer (a screen that renders its own recursive sub-graph), Light + the LambertianShader deferred-shading renderer-node, and DimensionN (N-dimensional shapes projected by ProjectorN). Each is one file under `node_types/`.
- **Renderers** — TextRenderer (the first-class bidirectional LLM-facing text surface), AsciiDebug (depth-as-ASCII), PainterlyPostProcessor (bundle-consuming palette-reduction + ID-edge darkening), LambertianShader, and ProjectorN (N-D to 3D projection). Each is one file under `renderers/`. The engine's default Z-buffer compositor handles software raster inline.
- **Bundle output** — `engine/bundle.py` writes `color.png`, `depth.png`, `depth.npy`, optional `normal.png` and `ids.png`, and `manifest.json`, matching the painterly module engine's input contract. Unknown channels pass through as `.npy` + a manifest reference.
- **Text-renderer surface and tooling** — `python -m tools.text_test` exposes `describe_scene`, `describe_view`, `summarize_bundle`, `dispatch_command`, and `assert_visible`: the LLM-facing observation / action / inspection / composition surface. An LLM can describe a scene, dispatch commands, write a new node-type file, trigger discovery, and spawn it — all through text.
- **Realtime renderer** — `python -m tools.realtime <scene>` opens a live interactive window (`engine/realtime.py` driver + a pure-stdlib `tkinter` backend). WASD/mouse drive the camera, Escape toggles the WorkflowView panels / full-render mode (or quits other scenes), F11 toggles fullscreen, and assemble errors blit an obvious magenta frame rather than a stale one. This turns Apeiron from a one-shot bundle renderer into an interactive surface.
- **Workflow / session-management shell** — `python -m tools.workflow` is an interactive REPL that hosts the "build Apeiron from inside Apeiron" loop. It boots the engine + file-watcher, spawns and drives real `claude` CLI subprocesses (the `SessionManager`), routes a file-based inbox compatible with the Alethea-cc convention, and exposes slash-commands (`/spawn`, `/wish`, `/send`, `/render`, `/reload`, …). The `WorkflowView` node-type plus its data-source / list-renderer node family render a multi-panel workflow surface as a live scene. A Streamlit GUI front-end lives under `tools/workflow_streamlit/`. An auth / trust layer gates cross-session messaging.
- **Browser renderer** — `node_types/browser_renderer.py` renders web content to a node's bitmap output via headless Chromium (the opt-in `browser-3d` extra; `playwright install chromium`).
- **CLI entry points** — installed via `pyproject.toml`: `apeiron-render`, `apeiron-text`, `apeiron-realtime` (plus the `python -m tools.*` forms).
- **Demo scenes** — `scenes/` includes `hello_cube`, `sphere_demo`, `lighting_demo`, `portal_demo`, `aggregator_demo`, `computer_demo`, `painterly_demo`, `dim4_cube_demo`, `seed_world_demo`, `text_demo`, `workflow_view`, `showcase`, and more.
- **Test suite** — a large pytest suite (on the order of 1,800 test functions across `tests/`) covers engine isolation, the node-type and renderer catalogs, bundle output, the text-renderer, the realtime driver, the workflow shell and session manager, trust/auth, and the GUI layer. Run with `pytest tests/`. Some process-supervisor tests are opt-in via `-m supervisor`.

## Features being developed

Active in-progress and open work. Per-item status — implemented,
partially implemented, or open — is tracked in
[What's built](whats_built.md); feature requests queue in
[wishlist.md](wishlist.md).

- **Realtime backends beyond tkinter** — the `WindowBackend` protocol is backend-agnostic; a pygame backend (better for first-person mouse-look with pointer lock) is the next backend to plug in.
- **Dream-mode / first-person inhabiting** — the input system, gravity fields, key-bindings, and the View's dream-mode fields are wired as a skeleton; the full first-person inhabiting experience is open work.
- **Inverse-edit and procedural generation** — Seed + Generator + `invert_edit` exist with a v1 hook; richer inversion (gradient over parameters, learned models) is future work.
- **OpenGL / GPU renderer** — scoped but not implemented; the software raster compositor is the current path.
- **Downstream painterly module engine** — Apeiron's bundle contract is forward-defined to its input requirements, but the painterly engine itself lives in the meta-layer's idea graph and is not yet implemented.

## Getting started

Apeiron is a Python package (requires Python 3.11+). From the repo root:

```bash
pip install -e .            # install the engine + CLI entry points
pip install -e ".[test]"    # add pytest for the test suite

apeiron-render hello_cube   # render a scene to a bundle under output/
apeiron-text describe hello_cube   # describe the scene as text
apeiron-realtime workflow_view     # open the live interactive window
python -m tools.workflow           # the workflow / session-management shell

pytest tests/               # run the test suite
```

On Windows, `scripts/launch_apeiron.bat` is a one-click launcher that opens
the workflow shell with a default session and the realtime window.

There is no hosted/live URL for Apeiron — it is a local engine and
toolkit, not a deployed website.

## Node types

(Skeleton — node-type implementations live in `node_types/` and migrate into individual page entries here as they stabilize.)

## Renderers

(Skeleton — renderer implementations live in `renderers/` and migrate into individual page entries here as they stabilize.)

## Scenes

(Skeleton — scene graphs live in `scenes/` and migrate into individual page entries here as they stabilize.)

## Engine

(Skeleton — engine code lives in `engine/` and migrates into individual page entries here as it stabilizes.)

## Conventions

Project-specific conventions iterate here through standard pull request. The [conventions of the Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/tree/main/conventions) apply by default; entries here override or extend them for this project.

(No project-specific conventions yet.)

## Meta-conventions

This project follows the [meta-conventions of the Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront#meta-conventions). Project-specific overrides or additions land here; the same maintainer-gating applies.

(No project-specific overrides yet.)

## License

[MIT License](LICENSE). For business and licensing matters, the corporate
entity is **Resonance Polymathematics** (distinct from the "Resonance
Wavefront" creative project — see the naming note at the top of this page).
