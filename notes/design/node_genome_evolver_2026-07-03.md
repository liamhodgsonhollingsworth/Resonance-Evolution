# NodeGenome — the node-collection genome kind with concentrating adaptive distributions

**Date:** 2026-07-03 · **Lane:** node-genome-evolver-core (coordinator 53e5c832) · **Spec:** Liam verbatim,
`G:\Wavelet\specifications\verbatim\2026-07-03_aperture_feedback_batch_liam_verbatim.md` §2 paragraphs 2–5.

**Code:** `godot/evolver/node_genome.gd` (the kind), `godot/evolver/param_dist.gd` (the distribution math),
`godot/evolver/node_genome_helpers.gd` (the helper-node seam), `godot/evolver/evolver_genome.gd` (kind dispatch).
**Acceptance:** `godot/headless_node_genome_test.gd` (48 checks, includes the convergence harness).

## 1. The model

An **artifact is a collection of nodes** in which **connections between nodes are also nodes**: a
connection-node carries `from`/`to` endpoint refs *and* its own params + distribution states — a wire has
genes (weight, gate) and evolves like any other node. Every node is flagged **fixed** (never touched:
params byte-stable, never dropped, never rewired, structurally undropable anchors) or **variable**.

**Evolving = genomic reshuffling of the variable parts:**

- `mutate(rng)` — one evolution step: every variable param's distribution **concentrates** on the parent's
  realized value, matching **helper nodes** transform it further, then the child's value is **redrawn**;
  plus an occasional structural op (`add` / `drop` / `rewire` / `swap`) at `config.p_structural`.
- `recombine(parents[], rng)` — **combinational reshuffling** across MULTIPLE evolutions of a generation
  (multi-parent): a base parent donates structure; each variable node's params take a **per-param donor**
  among all parents carrying that node (value AND distribution state travel together, so a donated gene
  keeps its concentration history); nodes unique to non-base parents splice in at `config.splice_p`.
  `crossover(a, b)` — the 2-parent contract the existing breed algebra calls — is `recombine([a, b])`.

The node **vocabulary is a schema carried as data on the genome** (`DEFAULT_SCHEMA` is a small generic
demo domain). Real domains — texture ops, effect stacks, canvas pages — wire in their own schema dict;
no code change. The genome serializes under the payload key `"node_graph"` (the kind discriminator,
next to `"stack"` = effect and `"texture_ops"` = texture); **kinds never interbreed** (mixed crossover
degrades to a clone of `a`, lineage still recorded).

## 2. The distribution math (the choice + why)

Per **scalar** gene over `[lo, hi]`, a **two-component mixture**:

```
draw ~ (1 − tail_w) · TruncNormal(mu, sigma)  +  tail_w · Uniform(lo, hi)

concentration transform (once per evolution, inherited by the child):
    mu'    = parent's realized value
    sigma' = max(sigma_min, sigma · gamma)          sigma_min = sigma_min_frac · range  > 0
    depth' = depth + 1
```

Defaults (all overridable as data): `sigma0 = 0.25·range`, `gamma = 0.7`, `sigma_min = 0.01·range`,
`tail_w = 0.10`.

Why this shape (a shrinking-scale core + a fixed-weight wide component):

- **"More evolution ⇒ smaller typical change"** — sigma decays geometrically with lineage depth, so the
  typical draw distance from the parent shrinks per generation.
- **"Change probability never reaches zero"** — two independent guarantees: `sigma_min > 0` (zero variance
  forbidden — asserted after 200 concentrations) and `tail_w` **never decays**.
- **"Can even still dramatically change as you move outward"** — the tail is uniform over the WHOLE range
  at constant weight, so from ANY depth the probability of a move of any size `d` is
  ≥ `tail_w · (range − d)/range` — a hard, depth-independent escape floor. This is what defeats the
  premature-concentration trap (measured below).

Per **categorical/enum** gene over `n` options — concentrating weights with a uniform floor:

```
sampling p_i = (1 − tail_w) · w_i + tail_w / n            (every option forever has p ≥ tail_w/n)
concentration: w' = normalize((1 − eta) · w + eta · onehot(realized)),  eta = 0.4
```

Boundary handling: core draws clamp into `[lo, hi]` (deterministic; small mass at the bounds — accepted
and documented). Int-typed genes round after sampling. All randomness flows through the caller's seeded
`RandomNumberGenerator` ⇒ **evolution is deterministic + reproducible** (asserted: identical mutations
AND identical whole convergence runs under one seed).

## 3. Granularity / approximation layer (resolution as data)

The distribution state is deliberately **compressed**: `{mu, sigma, depth}` / `{weights, depth}` — no PDF
tables, O(1) per draw, O(genes) per generation. On top of that, draws may be **snapped to a grid**
(`config.grid`, serialized with the genome):

- `mode: "off"` — exact continuous math.
- `mode: "fixed", bins: N` — fixed resolution (asserted: 500 draws land on ≤ N+1 distinct values).
- `mode: "adaptive"` — `step = clamp(sigma · step_frac, min_step, range/4)`: the grid is **coarse while
  the distribution is wide** (cheap, compressed early exploration) and **refines automatically as
  evolution concentrates sigma** — fine detail exactly when the search needs it (measured: step
  0.0625 → 0.0025 over 20 concentrations). This is the "behavior changes in granularity depending on how
  much fine detail is needed" knob, and it is pure data.

## 4. The convergence harness (the acceptance metric)

`headless_node_genome_test.gd` §6: pick a target genome inside the possibility space, simulate supervised
selection (elitist best-of-K=8 per generation, greedy nearest-to-target via `NodeGenome.distance` —
normalized mean gene distance; structure mismatches cost 1/gene), measure generations + wall-time, and
compare against a **non-adaptive uniform-mutation baseline** (`tail_w = 1.0` ⇒ every draw uniform, no
concentration ever influences a draw). Numbers from the shipping run (eps = 0.06, cap = 200):

| seed | adaptive | uniform baseline |
|---|---|---|
| 101 | **12 gens**, dist 0.058, 35 ms | 200-gen cap, dist 0.130, 580 ms — NOT converged |
| 202 | **9 gens**, dist 0.059, 35 ms | 200-gen cap, dist 0.114, 716 ms — NOT converged |
| 303 | **8 gens**, dist 0.050, 35 ms | 200-gen cap, dist 0.068, 663 ms — NOT converged |

Adversarial results (same suite):

- **Premature-concentration trap** — converge on target A, over-concentrate 30 more generations until a
  scalar core sits at the variance floor (sigma = 0.0100 normalized, asserted), then MOVE the target:
  distance 0.517 → 0.096 in **10 generations** — the fixed-weight tails escape, and selection re-centers
  `mu` on each accepted tail jump so escape compounds.
- **Zero variance forbidden** — 200 concentrations floor sigma at `0.01·range` exactly, never 0; a fully
  concentrated categorical still draws non-modal options (floor `tail_w/n`).
- **Seed determinism** — two identical-seed convergence runs produce identical generation counts and
  byte-identical final genomes.

## 5. Conditional convergence-helper nodes (the seam)

A per-parameter **evolution method is itself a node** in the artifact's collection: a schema type with
`is_helper: true`, a `when` condition (`param` / `node_type` / `depth_gte`, AND semantics), and
hyperparams as node params (themselves evolvable if the helper is flagged variable). During `mutate`,
after the standard concentration transform, every matching helper transforms the distribution state
further. Adding a method = one function in `NodeGenomeHelpers` + a schema entry — additive, reusable
whenever its condition applies, never a foundation edit. Unknown helper types are a fail-open no-op.

Shipped example — `helper_momentum` (momentum-toward-improvement):

```
vel' = beta · vel + (realized − previous_center)      (EMA of realized displacement)
mu'  = clamp(mu + gain · vel', lo, hi)                (bias the next draw along the improvement direction)
```

Asserted: it transforms ONLY the condition-matched param (`gain` gains a `vel` state, `bias` does not),
the velocity state serializes with the genome, and a helper-carrying genome converges under selection.

## 6. Wiring into the existing evolver (zero new plumbing)

`EvolverGenome` gained the third kind at its four dispatch points only: `random_seed(kind="node")`,
`kind()`, same-kind `crossover`, `from_dict` on payload key `"node_graph"`. Because `EvolverBreed` and
`EvolverState` already pass `meta_genome.genome_kind` through, **the entire existing loop — the four
primitives `EvolverPopulation → Render2D → ApertureSurface → Breed`, persistence, lineage — drives kind
"node" unchanged** (asserted: fully-culled recovery reseeds node genomes; keep/pin/crossover/inject stays
all-node). Effect + texture suites still ALL PASS — the change is additive.

## 7. How the evolution-on-canvas UI (peer lane) drives it

The peer lane puts evolution ON a 2D canvas page where "the page simply has the evolver as the logic for
generating new nodes on the page". The contract this core hands that lane:

- **A candidate is `EvolverGenome.to_dict()`** with a `"node_graph"` payload — nodes + connection-nodes
  are literally the things a canvas page renders (connection-nodes drawn as edges *with their own
  clickable body*, since they carry params). Fixed nodes render locked; variable nodes render live.
- **A generation on the page** = one `EvolverBreed.breed` tick with `meta_genome.genome_kind = "node"` —
  actions map exactly as today (evolve = keep, save = pin, skip = cull).
- **Combinational reshuffling in the UI** = the user multi-selects several candidates from a generation
  and the page calls `NodeGenome.recombine(selected, rng)` — the multi-parent API exists precisely so the
  canvas can offer more-than-two-parent mixes. (Follow-up: an `EvolverBreed` action verb for "recombine
  selected" so multi-parent goes through the breed algebra + lineage record too.)
- **Per-page taste knobs are `config`** (gamma / tail_w / grid mode / p_structural) — plain data on the
  genome, safe to expose as page controls, serialized with every candidate.
- **"Evolve toward" mode** = `NodeGenome.distance(candidate, target)` — the same metric the harness uses,
  so a page can auto-rank candidates against a pinned target.
- **Domain fit** = a schema dict per page. The demo schema is generic; a texture-flavored or
  effect-flavored schema wires those vocabularies into the node-genome model without touching the kinds
  that already ship.

## 8. Follow-ups (enqueued for the coordinator)

1. Breed-algebra verb for multi-parent recombine (surface action + lineage `origin: "recombine"`).
2. A `Render2D`-style delegate for node genomes (render the node graph itself as the card thumbnail) so
   the Aperture loop can show kind-"node" candidates without the canvas page.
3. Domain schemas: express `TextureGenome`/`EffectGenome` vocabularies as node-genome schemas (one
   evolver model over all three, superseding per-kind operators when the canvas UI lands).
4. More helper nodes as real cases appear (bounded-oscillation damper; per-param annealing schedules);
   the registry + condition matcher are already general.
5. Optional: momentum-aware concentration for categorical genes (currently scalar-only).
