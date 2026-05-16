# Stress-test — dream-features skeleton (2026-05-16)

Applied [stress-test-design](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/skills/stress-test-design.md) v1 to the dream-features skeleton landed in [Apeiron PR #13](https://github.com/liamhodgsonhollingsworth/Apeiron/pull/13). Findings below; mitigations in three shapes — fix-in-design (do now or queue with concrete plan), document-the-limit (acknowledge and record), defer-to-future (explicit trigger condition).

## Design frame

A planning + skeleton-implementation pass for eleven proposed dream-mode features in the Apeiron engine. Adds four additive engine extensions (View fields, input.py, inverse.py, sim_precompute), seven new node-types (DimensionN, Seed, Generator, GravityField, KeyBindings, SimulationProbe, ChatInterpreter), one new renderer (ProjectorN), three demo scenes. Claims that future full implementation drops in as modules without rewriting.

## Ranked vulnerabilities

Score = severity × likelihood, severity 1–3 (minor → architectural rewrite), likelihood 1–3 (edge → routine).

| # | Vulnerability | Score | Pass |
|---|---|---|---|
| V1 | `Engine.invert_edit` mutates the Seed's state dict in place, violating the append-only meta-convention. Every edit destroys the prior Seed version. | 9 (3×3) | Inversion |
| V2 | Scale-based LOD migration named in the design doc but NOT applied to the existing Aggregator implementation. The next session attempting zoom+aggregator will surface the gap. | 6 (2×3) | Inversion |
| V3 | `ChatInterpreter` claude_connected=false silently does nothing for novel commands; the design doc says it should write "not yet learned" responses. Design-implementation mismatch. | 4 (2×2) | Inversion |
| V4 | A Generator nested inside a Computer never re-precomputes when the Computer's internal view changes. Generator output is stale at all but the outermost render. | 4 (2×2) | Composition |
| V5 | `DimensionN` edge generation is O(V²). At dims≥8 (256 vertices) it gets slow; at dims≥12 (4096 vertices) it's pathological. The hypercube neighbor structure can be generated combinatorially in O(V×N). | 4 (2×2) | Scaling |
| V6 | An Aggregator wrapping a Generator finds zero cubes when walking the target sub-graph, because Generator inline-rasterizes rather than spawning child Cube nodes. The far-view impostor is empty. | 4 (2×2) | Composition |
| V7 | The invert_edit edit shape `{"target": "cube_position", "index": int, "new_value": [x,y,z]}` requires the caller to already know which index they want to edit. In real interactive use (click on a cube, drag it), the click→index resolution is missing. | 4 (2×2) | Inversion |
| V8 | `Engine.precompute` and `Engine.sim_precompute` ordering is implicit. A `sim_precompute_hook` reading regular cache depends on `precompute()` running first; nothing enforces it. | 3 (3×1) | Adjacency |
| V9 | A DimensionN placed as a direct child of a Group (without ProjectorN wrapping it) emits N-D-only channels; the default compositor ignores them; the result is silently empty. Confusing failure mode rather than a crash. | 2 (1×2) | Composition |
| V10 | Two `ChatInterpreter` nodes watching the same log file both write back "requested:" lines and both increment their own `parsed_offset`. Race condition; possible double-request. | 2 (2×1) | Composition |
| V11 | Multiple `KeyBindings` nodes in one scene — first-registered wins silently, others ignored. The architecture promised "per-mode/per-region control schemes" but the implementation can't realize it without further mechanism. | 2 (2×1) | Composition |
| V12 | `ProjectorN.select_children` returns `["source"]` only — single source. Composing multiple N-D shapes into one projection requires either Group composition (broken — Group can't propagate N-D channels) or a multi-source variant of ProjectorN. | 2 (2×1) | Composition |
| V13 | `engine/input.py` defines surface types but doesn't wire to any input source. The windowing-library decision affects which `InputEvent` fields make sense (gamepad? touch? speech?). Decision deferred — but the existing event dataclass may not be extensible enough for the eventual choice. | 2 (2×1) | Adjacency |
| V14 | `Generator.invert_hook` assumes the connection name "seed" — silently breaks for Generators with multiple seeds (e.g. terrain seed + decoration seed) or non-standard naming. | 2 (2×1) | Composition |
| V15 | Test suite covers each new node-type and the three new scenes individually, but no test composes a NEW node-type into an EXISTING scene (e.g. ProjectorN inside the showcase scene). Regression surface untested. | 2 (1×2) | Adjacency |

## Meta-pass — what the four passes missed

Original four passes: scaling, adjacency, composition, inversion. The meta-pass surfaced a fifth that v1 of the skill should add:

- **Intent fidelity pass.** Does the design produce the experience the maintainer described, not just the architectural capability to support it? Example: the topology demo renders correctly, but does walking through portals feel "dreamlike" or just "warped-coordinate"? The 4D hypercube projects correctly, but does zooming-in produce the maintainer's described inside-out "you-are-the-thing-becoming-the-world" experience? Architectural capability is necessary but not sufficient for intent fidelity. The pass: re-read the maintainer's described experience for each feature; compare to what the implementation actually does; surface gaps.

Intent-fidelity findings applied to the dream-features design:
- The user described, for feature 6 (seed sphere): "your visual field outside the sphere zooms IN to the sphere, but the visual field inside the sphere zooms out to show you the 'infinite world'". The skeleton has Seed + Generator + (existing Sphere + Computer + Portal) — the compose-them claim is plausible but the actual visual effect is unverified.
- The user described, for feature 5 (gravity toggle): "looking around can change your orientation on spherical coordinates in any arbitrary vector". The skeleton's `apply_mutation` in free mode does this, but the user wanted three sub-modes for the reset-to-gravity behavior — only two were captured ("snap_to_region", "snap_to_viewer"); the "choose-between-them" mode wasn't implemented.
- The user described, for feature 7 (pre-simulation): "Any arbitrary interaction is pre-simulated using simulations within simulations to work out emergent behavior beforehand". The skeleton's SimulationProbe runs `step()` calls but only at the surface level — nested simulation (simulations within simulations) isn't tested or designed.

The Intent fidelity pass should be the next addition to the stress-test-design skill's v2.

## Mitigations

**Apply now** (small fixes, in-scope):
- V3: add the missing "not yet learned" output line to ChatInterpreter when claude_connected=false. ~1 line of code.
- V5: replace O(V²) hypercube edge generation with O(V×N) combinatorial generation. ~5 lines.

**Queue as a tracked follow-up** (real fixes that need their own session):
- V1: redesign invert_edit to honor append-only. Path: invert_edit creates a new Seed-version node and updates the Generator's `seed` connection to point at it; the old Seed remains. Engine convention: "every Seed mutation creates a new Seed node alongside." Builds on per-edit-creates-new-node from meta-conventions.
- V2: apply the projected_size = world_size × scale / distance formula migration to aggregator.py. Update tests so aggregator dispatch correctness against view.scale is verified.
- V4: design a per-view-id precompute cache for Generators that need to re-emit at different views. Hashable view key; cache eviction policy TBD.
- V7: design a click→index resolution mechanism. Likely shape: the renderer's `ids` channel already carries per-pixel node IDs; an interactive editor reads the pixel under the cursor → node ID → which generated index. Wire-up is mechanical once the interactive renderer exists.
- V13: defer the windowing-library decision but document the InputEvent extension surface explicitly so v1 fields don't need to be removed.

**Document the limit** (acknowledge, don't fix in v1):
- V6: Aggregator-over-Generator returns an empty impostor in v1. Note in Generator's manifest description. Mitigation: when a future Generator subtype spawns real child nodes (the "alternative implementation path" already named in the dream_features.md design doc), Aggregator composes correctly.
- V8: `sim_precompute_hook` implementations are responsible for not depending on regular cache being already populated, OR for calling `engine.precompute()` themselves before reading. Document in the engine docstring.
- V9: DimensionN's manifest description should warn that it only composes with N-D-capable renderers (ProjectorN currently; future N-D renderers when they exist). Adding a `describe()` warning would surface the failure mode to debugging.
- V10: ChatInterpreters need unique log_path values; document.
- V11: KeyBindings: first-registered wins is the v1 semantics; document. The per-mode/per-region promise depends on a future "active KeyBindings selection" mechanism.
- V12: ProjectorN is single-source in v1; document.
- V14: Generator's invert_hook reads connection "seed" exclusively; multi-seed Generators are a future Generator subtype.

**Defer with trigger** (future work, but only when triggered):
- V15: add a regression test that adds ProjectorN (or another new node-type) to the existing showcase scene and verifies it renders, when the showcase scene next gets meaningful edits.

## v2 of the stress-test-design skill

Three updates surface from this application:

1. **Add the Intent fidelity pass.** A fifth named pass beyond scaling/adjacency/composition/inversion. Will land in the skill's evolution notes when this finding is committed.
2. **The meta-pass produces new passes; record both the pass name and the conditions under which the pass fires.** Future applications check whether the new pass is relevant before running it. Some passes (scaling) always fire; some (intent fidelity) only fire when the design has a stated experiential goal beyond mechanical correctness.
3. **Score the skill's own findings.** A vulnerability without a likelihood is just speculation. The severity × likelihood scoring forces explicit reasoning about prevalence; the pre-v1 version of the skill didn't have it.

Updates land in the skill file's evolution notes alongside the next commit.
