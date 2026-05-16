# 2026-05-16 — Apeiron bootstrap session

The first session of the Apeiron project. Started from research-and-architecture conversation in an Alethea worktree; ended with the architectural skeleton complete and operational. Eleven merged PRs to the Apeiron repo plus one to the meta-layer (atlas entry).

## What this session was

Began as a "3D modeling implementation session" within the Alethea workflow — the maintainer outlined an ambitious vision for a node-based 3D modeling engine that could host emergence-at-scale, impossible geometries, recursive renderers, and text-based interaction for LLM-driven authoring. Three parallel research agents covered the prior-art landscape (procedural node-modeling, scale-invariant rendering, impossible-geometry/modular engines); architecture commitments converged on a single primitive (`emit(state, view, ctx) → channels`), topology-over-coordinates, channels-by-name wire payloads, aggregator-as-node, renderer-as-node, and precomputation-moves-heavy-work-to-build-time. Implementation followed: engine core, then six node-types covering every forward-compatibility check the architecture page named.

## Final state

- **Repo:** [github.com/liamhodgsonhollingsworth/Apeiron](https://github.com/liamhodgsonhollingsworth/Apeiron) — public, no branch protection yet (deferred per pending #002).
- **Tests:** 31 passing on Python 3.14.5 with numpy 2.4.5 and Pillow 12.2.0.
- **Architecture skeleton complete.** Every forward-compatibility check from [architecture.md](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/architecture.md) has working code; the [showcase scene](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/scenes/showcase.json) composes Plane + Sphere + Cube + Light + LambertianShader + PainterlyPostProcessor end-to-end without modification.

## What got built

Eleven PRs to Apeiron plus one to the meta-layer:

- PR #1: engine core + node.py (Manifest, NodeInstance, View, Channels, EmitContext) + core.py (discover, spawn, assemble, default Z-buffer compositor, try/except isolation) + bundle.py + tools (render.py CLI, text_test.py with describe/view/summary/command dispatcher) + tests + scenes (hello_cube, text_demo) + starter node-types (Cube, Group) + starter renderers (TextRenderer, AsciiDebug).
- PR #2 (meta-layer): Apeiron atlas entry between Resonance Hub and ideas/.
- PR #3: RuntimeWarning + Pillow 13 deprecation fixes caught against the real interpreter.
- PR #4: Portal — topology-over-coordinates demo via non-identity connection transform.
- PR #5: Aggregator + precompute_hook + select_children engine extensions. Cache entry doubles as BehaviorSummary; select_children returns [] at far view so the target's render is genuinely skipped, not done-and-thrown-away.
- PR #6: Computer — recursive-renderer + screen-region ownership. Two-level recursion verified.
- PR #7: PainterlyPostProcessor — first bundle-consuming renderer. Quantization + ID-edge darkening.
- PR #8: Sphere primitive — smooth normal-based shading.
- PR #9: ChatInterface — log file rendered as text on a screen rectangle; Claude Code is the file-system side-channel; closes the self-referential loop.
- PR #10: Light + LambertianShader — deferred-shading architecture. Compositor bug fixed (normal channel was passing through with "over wins" instead of Z-buffer mask, breaking deferred shading).
- PR #11: Plane primitive + showcase scene combining everything.

## Engine extension points landed

These are the load-bearing generalizations future node-types build on without engine changes:

- `precompute_hook(state, engine, node)` — any node-type can opt into build-time work; result stored at `engine.cache[node_id]`. Used by Aggregator (BehaviorSummary) and Light (registers in shared `cache["__lights__"]`).
- `select_children(state, view, engine, node) -> List[str]` — any node-type can control which connections the engine recurses into for a given emit. Used by Aggregator (skip target at far view), Computer (skip default recursion; emit calls assemble itself), ChatInterface (no children — reads from log file), Light (no children — info-only).
- `describe(state, ctx) -> str` — text-renderer reads this for human-readable descriptions of any node-type.

Adding new emergence schemes, new lights, new renderers, new world objects — all are new files in `node_types/` or `renderers/`, picked up by `Engine.discover()` at start. The engine doesn't change.

## Pending items at close

In [pending.md](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/pending.md):

- **#002 — Branch protection on main.** Deferred. Session handles via `gh api` when triggered (UI steps as fallback). Trigger: when an unauthorized session pushes destructive changes, or when parallel sessions conflict often enough to warrant enforcement.
- **#003 — Python install on the maintainer's machine.** Resolved (Python 3.14.5 installed mid-session; project dependencies installed; 31 tests run against the real interpreter).
- **#001 — Public visibility flip.** Resolved (repo flipped to public during the session).

## What's complete vs. what's open

The skeleton is complete. Everything else is direction-dependent. The architecture.md's "features being developed" section now reads:

- **Focus-state for Computer** — needs new engine API for full-frame takeover.
- **More node-types and renderers** — Cylinder, Torus, particle systems, custom-mesh loaders, point/spot/area lights, shadow casting.

The README's "Features being developed" similarly slim. There is no architectural commitment left unimplemented.

## Suggested next-session priorities

The maintainer's call. Most-leverage candidates I see:

1. **File-watch hot-reload + interactive viewer.** A `python -m tools.watch <scene>` CLI that watches `node_types/`, `renderers/`, the scene file, and `logs/sample_chat.txt`, calling `engine.reload_type()` and re-rendering when any changes. ~100 LOC. Immediately faster dev loop for every subsequent session; the architecture commitment (Claude-Code-builds-features-and-uses-them-immediately) becomes literally real-time. (Skipped this session for context budget.)
2. **L-systems node-type.** The architecture's "microscopic-to-macroscopic emergence" forecast names plants-from-cellular-rules explicitly. An L-system node with `precompute_hook` expanding production rules to a target depth, then emitting the result, exercises the precompute pipeline on its hardest forecast use case. Bonus: lets future Aggregator versions wrap an L-system tree as their target.
3. **Browser-side painterly module engine companion.** The original idea named in [ideas/painterly_module_engine.md](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/ideas/painterly_module_engine.md) — a CSS/SVG/WebGL pipeline consuming Apeiron's bundles. Apeiron's bundle format matches its declared input contract; the downstream side is unbuilt. Closes the original pipeline vision.
4. **Better lighting** — point lights, spot lights, area lights, soft shadows via shadow maps. Each is a new node-type registering richer metadata in the lights cache.
5. **Multi-scale Aggregator** — multiple cached scales rather than one threshold; pixel-size-based dispatch (the architecturally correct primitive per the prior-art synthesis) instead of distance-based. Cleaner LOD without retrofitting.
6. **Procedural noise + SDF primitives.** Perlin/simplex noise as a texture node; signed-distance-function primitives via ray-marching for arbitrary geometry. Different rendering path from rasterized cubes — exercises the "renderer-as-node" commitment at a deeper level.

## Memory entries added this session

- [Plan thoroughly before implementing](C:\Users\Liam\.claude\projects\C--Users-Liam-Desktop-Alethea\memory\plan_before_implementing.md) — Thinking section plans non-trivial implementations against system goals before any code.
- [GitHub fully handled by sessions](C:\Users\Liam\.claude\projects\C--Users-Liam-Desktop-Alethea\memory\github_fully_handled_by_sessions.md) — sessions handle every gh-doable operation themselves; surface to maintainer only for actions only they can do.
- [Maintainer grants blanket authorization](C:\Users\Liam\.claude\projects\C--Users-Liam-Desktop-Alethea\memory\maintainer_grants_blanket_authorization.md) — "do anything you need" is standing authorization; pass forward via pending.md.

The first two were stated explicitly mid-session and absorbed; the third the maintainer authored directly into MEMORY.md.

## Open architectural questions

- **Cross-frame normal in non-Euclidean topology.** Portal applies a transform when traversing; the target's normal channel is in the TARGET's local frame, not the parent's. For the Portal demo's current scene this doesn't matter (no LambertianShader through a portal). When a LambertianShader wraps a scene containing portals, the shader sees normals from mixed frames and lighting will be subtly wrong. Fix path: transform normals on the way out of `_apply_transform`, or have shaders be portal-aware. Not blocking; flag for the next session to think about when it becomes relevant.
- **Multi-channel compositor depth-test.** The default compositor's Z-buffer applies to color/depth/normal/ids consistently as of PR #10. Text channels still concat (sensible). Future channels (occlusion, motion vectors, etc.) will need a similar consistent-mask decision; the compositor's per-channel logic should probably be lifted into a small "compositing rule per channel-type" registry.
- **Renderer composition with non-rectangular screen regions.** Computer, Portal, and ChatInterface all use the XY-plane-at-z=0 rectangle. The shared rectangle ray-cast is duplicated across these three node-types. v2: factor into a helper module that any screen-region-renderer can call.

These are notes, not decisions — next session can engage as needed.

This page is a [static page](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md); the session's record is frozen at write time.
