# Handoff — architecture pivot: "no fundamental primitives"

Status 2026-06-20. Worktree `vibrant-elion-937d68`. **A v0 of the fractal-primitives layer is now
BUILT + VERIFIED here** (see "## v0 BUILT" below) — a minimal, additive, opt-in core change; default
behavior (no store / budget 0) is byte-identical, so it merges cleanly with the other session
(`clever-hellman-e85337`, the canvas-chat thread, which added a Chip depth guard + `Message`). The
authoritative statement of the new law is the user's (below). This doc is analysis + a grounded map +
the now-built v0; the deeper generalization (a richer frame, Chip/decomposition unification) is still
open and partly the in-flight session's territory — coordinate per the open questions.

## The new law (user's words, verbatim)
> Everything in this system should be based around how there are no fundamental primitives. I need a
> system where primitives can be retroactively decomposed, or things can be treated as primitives based
> on a particular reference frame, but there is no absolute universal reference frame.

Three claims: (1) **no fundamental/absolute primitives**; (2) **retroactive decomposition** — what was
used as a primitive can later be given an internal definition and existing usages gain it; (3)
**frame-relative primitiveness** — "primitive" means "atomic *at this reference frame*"; there is **no
privileged universal bottom frame**.

## v0 BUILT — the minimal, additive, opt-in fractal-primitives layer (verified)
Shipped this session in `vibrant-elion-937d68` (additive; default path byte-identical):
- **`runtime/definitions.gd`** (`class_name Definitions`) — the DEFINITION STORE. A type carries a
  mandatory **leaf** (operational behavior + I/O contract at the base frame) and an **optional
  decomposition** (an arrangement + a Chip-shaped port map). `descend(type, inputs, budget)` runs a
  sub-runtime over the decomposition, carrying the store + remaining budget so inner types keep
  unfolding. Decompositions are attachable at runtime → **retroactive**.
- **`runtime/graph_runtime.gd`** — two opt-in fields (`definitions`, `descend_budget`), a
  store-preferring branch in `_instance` (store leaf supersedes `_registry`; registry untouched), and
  the **frame-relative descent** in `evaluate()`: `if descend_budget > 0 and the type has a
  decomposition → descend (budget−1) else → leaf`. With no store / budget 0 it is the classic path.
- **`headless_fractal_test.gd`** (12/12) — proves all three claims on a faithful tower
  `Quad ⊃ Double ⊃ Math.add`: **value invariant** across frames 0/1/2/3/5 (all = 20) while the
  **firing primitive moves with the frame** (Quad → 2×Double → Math); **retroactive** (decompositions
  attached after load, no arrangement edit); **no privileged bottom** (graceful bottoming where no
  decomposition exists); plus a faithfulness check (decomposition ports == leaf ports) and a no-store
  byte-identical check. Full existing headless suite still green (no regression).

**Also proven on the SCENE / glTF substrate** (`headless_scene_fractal_test.gd`, 10/10 — closes the
law's claim #5 / open-Q #6 "same machinery for behavior AND scene graphs"). Same `Definitions.descend`
(it's value-agnostic Dict pass-through, so NO core change). A store-only `Body` leaf renders as ONE box
mesh at the origin (atomic); a decomposition attached RETROACTIVELY — a real arrangement of EXISTING
primitives `Model → Transform → Group` — makes the SAME loaded graph dissolve, at a deeper frame, into
TWO part-meshes at A=[-1.5,0,0] and B=[1.5,0,0]. The invariant is RENDERED GEOMETRY (both frames built
through `GodotSceneRenderer`, mesh world-positions compared — not a structural echo of the arithmetic
test), faithfulness measured honestly (parts present at their declared positions), graceful bottoming
across frames 1/2/5, and the decomposed scene round-trips through `GltfExporter` → glTF → reimport with
both parts intact (lands on the portability spine). This was chosen by a 4-architect / 3-judge design
panel (unanimous: Option A), as the minimal, zero-collision, highest-law-leverage next step.

**Adversarially reviewed** (11-agent workflow, 4 lenses, each finding independently verified): 7
confirmed findings, **all nits**, 12 praise. Verified-good: descent is leak-free, strictly bounded by
the budget countdown (no MAX_DEPTH needed for the store channel), smuggles in NO real primitive types
(Double/Quad are store-only test fixtures), and `descend_budget` is a per-branch countdown that does
**not** secretly reintroduce a universal frame. Nits applied: deleted two speculative methods, clarified
the leaf-is-mandatory contract, labeled the scalar budget a v0 uniform-depth model, American spelling.

### Deferred / coordinate (NOT done in v0 — on purpose)
- **Chip ↔ decomposition unification.** `PrimChip` does not propagate the store/budget into its
  sub-runtime, so frame descent does **not yet cross a Chip boundary** (a Chip's interior evaluates at
  its own base frame). The handoff direction ("Chip stops being special; every node Chip-like") = fold
  both channels into ONE shared nested-eval mechanism. Touches `prim_chip.gd` (the other session's
  file) → **coordinate**. Documented in `definitions.gd`.
- **MAX_DEPTH across the descent boundary (merge note).** The other session's `GraphRuntime.depth` /
  `PrimChip.MAX_DEPTH` guard isn't threaded through `Definitions.descend` (their `depth` field doesn't
  exist on this branch yet). Post-merge: add a `depth` param to `descend()` and set `sub.depth` so the
  Chip-nesting cap stays global (≤64 total) rather than per-descent-layer. Finite either way (the
  budget bounds descent); a one-line reconciliation when the branches land.
- **Richer frame model.** v0 is a single uniform descent-depth integer. The law's "no absolute
  universal frame" + heterogeneous observation point toward a per-type / per-observer (camera/orb zoom
  = the README's "distance-as-recursion-depth") / per-region descent policy. `descend()` already takes
  a plain budget, so generalizing is a local change. **Direction fork for the user.**
- **Decomposition keying granularity.** v0 keys by TYPE; behavior-by-params types (Math op=add vs mul)
  can't share one type-keyed decomposition (v0 sidesteps this with param-free fixture types). Fork:
  key by type vs type+params vs per-instance.
- **Definitions as single source of truth.** v0 is an opt-in overlay beside `_registry`; the law's
  spirit (leaves are entries, not the floor) suggests it could eventually replace `_registry`. Fork.
- **Perf.** `descend()` uses a throwaway sub-runtime per eval (no diff-hotload caching) — a cost only
  if a decomposition holds a live `Model`. Cache the sub-runtime (like `PrimChip._sub`) when that lands.

### Merge with `clever-hellman-e85337` (the other session)
One trivial keep-both conflict only: the adjacent var insertions after `var _external` (mine:
`definitions`+`descend_budget`; theirs: `depth`). Their `_init` `Message` registration, my `_instance`
branch, and my `evaluate()` descent branch all auto-merge (one-sided additions). New files don't collide.

## What the engine does TODAY (the thing to dissolve)
- `GraphRuntime._registry` hardcodes a fixed set of GDScript primitive classes (`Const, Math, Log,
  Model, Transform, Chip, Group`) as the **absolute, irreducible bottom**. A node's `type` resolves to
  exactly one GDScript class. That fixed leaf level **IS an absolute universal reference frame** — the
  exact thing the new law forbids.
- An arrangement is a graph of these instances + typed wires; `evaluate()` runs the dataflow with the
  leaf classes as the unquestioned ground.

## The seam that already points the right way (reuse, don't reinvent)
- **`PrimChip`** (`primitives/prim_chip.gd`): a node whose `params.arrangement` is a sub-graph, evaluated
  by a recursive `GraphRuntime`. This is *already* "a composite treated as one primitive, decomposable on
  descent." The pivot = make **every** node potentially Chip-like, and demote the leaf classes to *one
  kind of definition among others*, none privileged.
- **Orb / zoom / scope-in + "distance-as-recursion-depth"** (PROGRESS.md roadmap): the spatial model of
  **reference-frame traversal** — descend = decompose into the internal arrangement (new frame); ascend =
  treat-as-primitive. "Enter an orb" = descend a frame.
- **The capability-ratchet content-addressed library** (`[[capability-ratchet]]`): the natural home for
  **definitions** — which can be retroactively attached + versioned (append-only).

## Proposed generalization DIRECTION (a proposal — defer to the in-flight session on specifics)
1. **type → definition, resolved as DATA and frame-relative.** A node's `type` references a DEFINITION in
   a store. A definition is either a **leaf behavior** (today's GDScript impl) OR an **arrangement**
   (sub-graph, like a Chip). The store is the content-addressed library; leaf classes are entries, not
   the floor.
2. **reference frame = how deep observation/evaluation descends.** At a frame, a node is treated as a
   primitive (use its leaf behavior or cached/aggregated output) UNLESS the frame descends into its
   definition-arrangement (then recurse — exactly `PrimChip.evaluate`). No bottom: leaf-ness is
   frame-relative.
3. **retroactive decomposition = attach an arrangement-definition** to a type/instance that previously had
   only a leaf (or none). Because functionality is DATA, this is adding a (content-addressed, versioned)
   definition record; existing instances become descendable.
4. **operational primitives still exist PER FRAME** (something must actually compute a number) — but they
   are NOT absolute: any leaf may in principle be redefined as an arrangement over other leaves, and the
   engine never assumes a privileged universal bottom. **Crucial clarity: "no fundamental primitives" =
   "no privileged/absolute primitives," NOT "no leaves during a given evaluation."** Don't let the law be
   misread as "evaluation has no ground" — it means the ground is chosen by frame and is replaceable.
5. **applies to BOTH graphs the engine has:** behavior arrangements (Const/Math/…) AND scene graphs (a
   `Model`/mesh decomposes into parts/sub-meshes — the L-system "parts" idea + `Group` already gesture at
   this). Frame-relative primitiveness unifies them under one rule.

## Migration impact map (where the work lands — the in-flight session's territory)
- `runtime/graph_runtime.gd`: `_registry` → a **definition resolver** (leaf-class OR arrangement-def);
  `_instance` + `evaluate` become definition/frame-aware. Core edit.
- `primitives/prim_chip.gd`: its recursive-runtime logic generalizes into the **default** "descend on a
  decomposed node" path (Chip stops being special).
- `primitives/primitive.gd`: base may gain definition/decomposition awareness.
- `schema/arrangement.schema.json`: a node carries/references a decomposition; "primitive type" becomes a
  "definition reference."
- The library/ratchet: becomes the **definition store** (versioned, retroactive).

## What this means for the COMPATIBLE work already shipped (no rework, gains generalization)
- **Renderer-delegate seam + `scene_node`/glTF portability + `Group` + three.js parity + primitive mesh
  source** (committed, engine `4b89a98`): all DATA; definitions are data → fully compatible. Gains the
  frame-relative view (a `scene_node` decomposes into child `scene_node`s = a frame descent).
- **Evolver connection (`domain_node`) + cross-substrate parity harness** (website `e7e7f80`, `2dc47ce`):
  compatible — the evolver evolves definitions/arrangements at any frame; parity (`[[cross-substrate-parity]]`)
  still applies since definitions are portable data.
- **Live Claude-Code loop**: verified end-to-end (hotload + screenshot + scene switch via the bridge).

## PAUSED work — live workflow surface (resume AFTER the architecture lands; reframe under it)
Researched + planned this session, **not built** (see `[[workflow-surface-decisions]]`). Decisions made:
**D1** defer `godot-cef` but keep an instant-integration renderer seam; **D2** areas = **separate
processes** + the user wants transparent see-through windows + instant macro/page switching (**user has
SPECS coming**); **D3** mechanics = data run-checks + `emit_signal` + windowed `push_input` (no RCE).
Verified-feasible plan exists (transparent windows via per-pixel + win32 `WS_EX_LAYERED|TRANSPARENT`
needs a GDExtension; global hotkey + `SetForegroundWindow`+Alt bypass needs a small native layer;
multi-process bridge = one project + N processes via `--area=<id>`, `user://areas/<id>/…` namespacing,
`?area=` routing + fix the `_p()` path-traversal hole; per-area screenshot/input/run-checks).
**Reframe under the new architecture before building:** an "area" is naturally a **reference frame /
observed definition**, and "arrangement per area" = "definition per frame" — the workflow surface likely
gets *simpler* once frames are first-class. Do not build it until (a) the architecture lands and (b) the
user's window/macro specs arrive.

## Open questions to settle with the user / the in-flight session
1. Exact data representation of a **definition** and a **reference frame**.
2. How leaf behaviors and arrangement-definitions coexist (dispatch order; can a type have both, chosen by
   frame?).
3. Cross-frame **evaluation strategy** (lazy descend? per-frame caching? interaction with the existing
   content-hash diff-hotload).
4. How content-addressing/versioning handles **retroactive decomposition** (append-only definitions; do
   existing instances auto-gain a new decomposition or opt in?).
5. Is "treat-as-primitive at frame F" **per-observer** (the camera/orb) or **per-evaluation-context**?
6. Does the scene-graph (mesh/parts) decomposition share the SAME machinery as behavior-graph
   decomposition, or a parallel one?

## Repo state at handoff
Committed (verified): engine `4b89a98` (Chip + editor + renderer-delegate seam + scene_node/glTF +
Group + three.js oracle + primitive source), website `e7e7f80` + `2dc47ce` (domain_node + parity harness).
Uncommitted in this worktree: `.claude/launch.json` (a `parity-web` preview entry — **machine-specific
absolute path, do not merge as-is**), `godot/test_null_dict*.gd` (**scratch, not this session's — safe to
delete**), a stray `.uid`. Nothing half-built; all green.
