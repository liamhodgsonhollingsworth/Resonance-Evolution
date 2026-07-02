# Generalized Probabilistic Wave-Function-Collapse

**A strict generalization of the deterministic `wfc` Context handler to weighted (non-uniform) and *evolving-distribution* rules — preserving the base case exactly.**

**Date:** 2026-07-01
**Status:** research + design (no engine edits). Companion diagram: `generalized_probabilistic_wfc_nodegraph.svg`.
**Base case:** `godot/primitives/prim_context.gd`, the `wfc` handler (`_evaluate_wfc` → `_wfc_collapse` → `_wfc_weighted_pick` / `_wfc_min_entropy_cell` / `_wfc_propagate`).
**Prior art in-repo:** `notes/research/wfc_editor_ux_patterns_2026-07-01.md` (DeBroglie constraint taxonomy, backtracking, Townscaper local re-collapse). Evolver substrate: `prim_state.gd`, `prim_breed.gd`, `prim_evolver_population.gd`, the `tick`/`sim` Context handlers.

---

## 0. Liam's spec (verbatim, 2026-07-01)

> "Start researching and iterating on specs and a design for a more generalized wavefunction collapse engine that uses not just deterministic rules but also probabilistic rules. This means that the possibilities are not equally weighted, and some possibilities are based not just on static rules but also evolving distributions (so, for example, the probability of generating node A next to node B is based on the number of other instances of that). It doesn't have to work exactly like this, but I just want to find a way that generalizes the WFC algorithm that allows for more flexible node functionalities and systems, meaning that I can implement more complex behaviors into the same system while preserving all the functionality of the base case where probabilities all equal 1 or everything is static."

The one non-negotiable, restated: **all-weights-uniform / all-rules-static must reduce EXACTLY to the current deterministic handler.** Everything below is a superset that collapses onto today's code when the new fields are absent or trivial.

---

## 1. The generalization model

### 1.1 What "probabilistic WFC" actually decomposes into

The classic observe/propagate loop has exactly two decision points, and *both* are already probabilistic hooks hiding in plain sight:

1. **OBSERVE — which cell to collapse next?** Today: minimum *domain size* (`_wfc_min_entropy_cell`), ties broken by lowest row-major index. This is un-weighted "entropy" (a count of options). The weighted generalization is **Shannon entropy over the cell's weighted domain**.
2. **COLLAPSE — which tile does the chosen cell become?** Today: a seeded *weighted* draw (`_wfc_weighted_pick`) over the cell's domain, using a **global per-tile weight**. The generalization is a draw over a **context-dependent, possibly evolving weight** `w(tile | cell, neighborhood, generation-state)`.

So the base handler is *already* a weighted collapser — it just uses the degenerate weight function `w(tile) = tiles[tile].weight` (default `1.0`, i.e. uniform). The whole generalization is: **replace the constant weight lookup with a weight *function* evaluated per (cell, tile) at draw time**, and **make the entropy heuristic weight-aware** so the two stay consistent. No new phase, no new loop — the same observe/propagate skeleton with a richer weight oracle.

This is the elegant framing: **WFC is already probabilistic; determinism is the special case where every legal option has weight 1 and the tie-break is lexicographic.** We are not bolting probability *on*; we are *un-hiding* the weight oracle and letting it be a function instead of a constant.

### 1.2 The weight oracle — three tiers of one function

Define a single weight oracle `W(tile, cell, ctx) → float ≥ 0`, where `ctx` carries the neighborhood (already-collapsed neighbors of `cell`) and the **generation-state counters** (running tallies accumulated as cells collapse). Every rule tier is a way of *supplying* `W`:

| Tier | `W(tile, cell, ctx)` is… | Base-case value | Example |
|---|---|---|---|
| **T0 — static uniform (base case)** | `tiles[tile].weight` (a constant, default 1.0) | this is what runs today | every legal tile equally likely |
| **T1 — static conditional** | a constant that depends on `(tile, neighbor-in-direction)` | reduces to T0 when all conditional weights equal | "grass is 5× more likely to the right of grass than to the right of stone" |
| **T2 — evolving distribution** | a *function of generation-state counters* recomputed as cells collapse | reduces to T1/T0 when the function is constant in the counters | "P(A next to B) ∝ f(count of existing A-B pairs)" — Liam's example |

**T2 is the heart of the spec.** The weight of placing tile `A` is no longer fixed: it is read from a **live counter** that other collapses have been incrementing. `P(A | neighbor=B) ∝ f(n_AB)` where `n_AB` = number of A-B adjacencies already committed this generation. Choosing `f` chooses the *global statistical character*:

- `f(n) = 1` → **T0/T1** (no feedback — the base case).
- `f(n) = 1 + k·n` → **rich-get-richer / clustering** (positive feedback: A-B pairs beget more A-B pairs → clumps, veins, biomes).
- `f(n) = 1 / (1 + k·n)` → **saturation / anti-clustering** (negative feedback: once you have enough A-B pairs, stop — even spread, quotas, "at most N of these").
- `f(n) = max(0, target − n)` → **hard-ish quota** (a soft Count constraint: weight decays to 0 as the target count is reached — this is DeBroglie's `Count` constraint expressed as an evolving weight, not a separate constraint engine).

The single insight worth holding: **a static weight is a distribution that ignores its own history; an evolving weight is a distribution that reads a running tally the collapse itself is writing.** Both flow through the *same* `_wfc_weighted_pick` call site — the only change is *where the number comes from*.

### 1.3 Weighted entropy (the OBSERVE step)

To keep observe and collapse consistent, the min-entropy heuristic must become **weighted Shannon entropy**:

```
H(cell) = -Σ_{t ∈ domain} p_t · log(p_t),   where p_t = W(t, cell, ctx) / Σ_{t'} W(t', cell, ctx)
```

- When all weights are equal, `H` is monotonic in domain *size* (a k-option uniform cell has entropy `log k`), so **the argmin of weighted entropy equals the argmin of domain size** — exactly today's heuristic. Base case preserved.
- With unequal weights, weighted entropy correctly prefers to collapse the *most-determined* cell (a cell that is 99% going to be grass has low entropy even with 5 options), which is the standard WFC improvement and matches mxgmn/DeBroglie.
- Ties (equal entropy) still break by lowest row-major index → determinism preserved under the seed.

**Numerical note (adversarial, §4):** with evolving weights, a cell's entropy changes every time a counter it depends on changes. Recomputing `H` for *every* cell on *every* collapse is O(cells · domain) per step. Mitigation: only recompute entropy for cells whose `ctx` actually changed (the collapsed cell's neighbors + any cell whose weight function reads a *global* counter that moved). See §4.3.

### 1.4 Seeding & determinism under randomness

Determinism is **not lost** by going probabilistic — it is *parameterized by the seed*, exactly as the base case already is (`_wfc_collapse` seeds one `RandomNumberGenerator`). The contract is unchanged:

> **Same `(ruleset, seed)` → identical grid, every run, every machine.**

This holds for T0/T1/T2 *provided* the RNG is drawn in a fixed sequence and the weight oracle is a **pure function of committed state**. Concretely:

- One seeded `RandomNumberGenerator`, drawn once per collapse in scan order (as today).
- The weight oracle reads only **committed** counters (never in-flight/partial state), so its value at draw time is a deterministic function of "which cells collapsed before this one" — which the seed fully determines.
- Weight-function *evaluation order* is fixed (domain sorted by tile name, as `_wfc_weighted_pick` already does), so floating-point accumulation is reproducible.

The evolving-distribution counters make the draw **history-dependent but still seed-deterministic**: the history is itself a deterministic function of the seed. This is the same property `prim_breed.gd` already relies on ("RNG seeded from `params.seed` + generation index → same decided generation always yields the same next generation").

### 1.5 Contradiction & backtracking

The base handler is **fail-soft**: a wiped domain flags `contradiction`, leaves the cell `""`, and continues (`_wfc_collapse`). Probabilistic weights **change the contradiction *rate*** but not the mechanism:

- **T0/T1** cannot make a *satisfiable* ruleset contradict more often than the base case — weights only reorder *which* legal tile is drawn, never make a legal tile illegal. Contradiction is still purely an *adjacency* (hard-constraint) phenomenon. So the fail-soft path is untouched.
- **T2** *can* raise the contradiction rate if a `f` drives a weight to **0** (a soft quota that saturates). A 0-weight tile is still *legal* (in the domain) but *never drawn* — so it can be forced by propagation onto a cell where every *positively-weighted* option was exhausted, producing an ugly-but-legal grid, or (worse) a `f` that zeroes *every* option of a cell → a soft contradiction.

**Design decision:** keep **fail-soft as the T0/T1 default** (backward-compatible, no behavior change) and add **optional backtracking** (`params.wfc.backtrack: true`, default `false`) that the T2 tier and the instance-editor pin loop (per the research note) turn on. Backtracking = "on a wiped domain, roll back the most recent collapse and redraw with that tile excluded" (DeBroglie's model). Crucially, **weights make backtracking cheaper**: the redraw simply re-samples the same weighted distribution minus the failed tile, and evolving weights naturally *steer away* from the choice that caused the contradiction (a saturating counter down-weights the over-used tile). Backtracking is a §5 phase-3 concern, specified but not required for T0/T1/T2-basic.

---

## 2. Base-case preservation proof-sketch

**Claim:** with the extended schema, if every rule is static and every weight is uniform, the generalized collapser produces the **byte-identical grid** the current `_evaluate_wfc` produces for the same `(ruleset, seed)`.

**The reduction, field by field.** The current `params.wfc` is `{ width, height, tiles, adjacency }` where `tiles` is `[{name, weight}]` (or the string shorthand) and `adjacency` is per-direction allow-lists. The extended schema (§3) is a **strict superset**: every new field is *optional* and defaults to the base behavior.

1. **Tile selection.** The generalized draw calls `W(tile, cell, ctx)`. When `params.wfc.weights` (the conditional/evolving block) is **absent**, `W` degrades to `tiles[tile].weight` — literally the current `weight` dict passed to `_wfc_weighted_pick`. Same numbers → same seeded draw → same tile. ∎ (collapse)
2. **Entropy / cell choice.** Weighted Shannon entropy with all-equal weights is a strictly increasing function of domain size (`H = log(size)` for a uniform cell). `argmin H` = `argmin size`, ties by lowest index — identical to `_wfc_min_entropy_cell`. Same cell chosen every step. ∎ (observe)
3. **Propagation.** Unchanged. Hard adjacency constraints (`adjacency`) are orthogonal to weights; `_wfc_propagate` runs exactly as today. Weights never enter propagation (they bias *choice*, not *legality*). ∎ (propagate)
4. **RNG.** One seeded `RandomNumberGenerator`, one draw per collapse, domain sorted by name — all identical to `_wfc_weighted_pick`. When weights are uniform, the draw is the same uniform draw the base case makes. ∎ (determinism)
5. **Contradiction.** With `backtrack` absent/false and no 0-weight-forcing `f`, the fail-soft path is byte-identical (no rollback ever triggers). ∎ (fail-soft)

**Data-shape subset proof.** The current `params.wfc` is a **valid instance** of the extended schema with `weights` omitted and `backtrack` omitted. The parser (§3.3) reads the extended schema and, on encountering a base-case `params.wfc`, constructs a `W` that is *definitionally* the current `weight` lookup. Therefore **every existing arrangement, test, and saved ruleset runs unchanged** — the generalization is additive, `headless_wfc_test.gd` still passes verbatim, and the engine law ("new functionality is DATA, not new code paths for the old case") holds: the old case *is* a data subset.

**One subtlety to honor (already true in the base case):** `_wfc_tiles` clamps every weight to `≥ 0.000001` so a tile in the alphabet is always minimally pickable. The generalized `W` must preserve this **only for the base/T0/T1 tiers**; the T2 tier deliberately *allows* weight → 0 (soft quotas), which is why T2 opts into backtracking. This is a *documented behavioral divergence gated behind an opt-in field*, not a change to the base case.

---

## 3. Data schema

The design keeps **one handler** (`wfc`) and extends `params.wfc` additively — no `wfc_prob` fork. (Rationale in §3.4.) Weights are **DATA**: either a literal number, a small conditional table, or a **wired expression** referencing generation-state counters — so the whole thing stays node-wireable per the node-wiring simplicity law.

### 3.1 The extended `params.wfc`

```jsonc
{
  "width": 4, "height": 3,
  "tiles": [ { "name": "A", "weight": 1.0 }, { "name": "B", "weight": 1.0 } ],   // base case, unchanged
  "adjacency": { "right": { "A": ["B"], "B": ["A"] } },                          // base case, unchanged (hard constraints)

  // --- NEW, all optional ---
  "weights": {                    // the weight ORACLE. Absent => base case (per-tile `weight` above).
    "mode": "conditional",        // "uniform" (=base) | "conditional" (T1) | "evolving" (T2). Absent => "uniform".
    "rules": [
      // T1 — static conditional: bias a tile by what's already in a direction.
      { "tile": "A", "given": { "dir": "right", "neighbor": "B" }, "weight": 5.0 },

      // T2 — evolving: weight is an EXPRESSION over generation-state counters (§3.2).
      { "tile": "A", "given": { "dir": "any", "neighbor": "B" },
        "weight_expr": { "op": "linear", "base": 1.0, "k": 0.5, "counter": "pair:A:B" } }
    ],
    "default_weight": 1.0         // fallback when no rule matches a (tile, cell) — the base per-tile weight.
  },

  "counters": {                   // declares the generation-state tallies the evolving weights read (§3.2).
    "pair:A:B": { "track": "adjacent_pair", "a": "A", "b": "B", "directed": false },
    "count:A":  { "track": "tile_count", "tile": "A" }
  },

  "entropy": "weighted",          // "size" (=base, domain-count) | "weighted" (Shannon over weights). Absent => "size".
  "backtrack": false,             // opt-in rollback for T2 / pins. Absent => false (fail-soft, base behavior).
  "backtrack_limit": 10000        // safety cap on rollback attempts (§4.1). Only read when backtrack=true.
}
```

**Every base-case ruleset is a valid instance of this schema** (all NEW fields omitted → `weights.mode="uniform"`, `entropy="size"`, `backtrack=false`), which is the §2 subset proof made concrete.

### 3.2 Generation-state counters — the evolving substrate

A **counter** is a named running tally updated as cells collapse. The declared `track` kinds are a small, closed vocabulary (no arbitrary code — DATA):

- `tile_count` — how many cells hold tile `X` so far (drives global quotas / rarity).
- `adjacent_pair` — how many committed A-B adjacencies exist (directed or undirected) — **Liam's exact example**.
- `region_count` — tile count within a declared sub-rectangle (borders, biomes).
- `run_length` — current consecutive run of a tile along an axis (drives DeBroglie's Max-Consecutive as an evolving weight).

Counters are **incremented at commit time** (when a cell collapses to a definite tile, and — for `adjacent_pair` — when both endpoints of an adjacency become definite). They are **read-only to the weight oracle** (the oracle never writes them; the collapse loop does), which is what keeps the oracle a *pure function of committed state* (§1.4, determinism).

### 3.3 `weight_expr` — weights as a tiny wired sub-graph

`weight_expr` is a **closed, data-only expression language** (not eval'd code) so it is safe, deterministic, and node-wireable. Each is `{ op, ...args }` over counters and constants:

| `op` | meaning | reduces to base when… |
|---|---|---|
| `const` | `{ op:"const", value:1.0 }` | always a static weight |
| `linear` | `base + k · counter` | `k = 0` => `const(base)` |
| `inverse` | `base / (1 + k · counter)` (saturation) | `k = 0` => `const(base)` |
| `quota` | `max(0, target − counter)` (soft cap) | `target = ∞` => unbounded |
| `sum` / `product` | combine sub-exprs | single child => that child |
| `ref` | read another declared weight rule (composition) | — |

**Node-wireable form (the real target):** in the GraphEdit surface (research note §6), a `weight_expr` is literally a small arrangement — a **Counter node** (a `State`-backed tally) → a **Math node** (`linear`/`inverse`) → the **weighted-collapse** node's weight port. The JSON above is the *serialized* form of that sub-graph; the two are interconvertible (homoiconic). So "wire a weight function" and "write a `weight_expr`" are the same act from two directions — matching the engine's DATA-is-the-program law. The diagram (`.svg`) shows this wiring explicitly.

### 3.4 Why extend `params.wfc`, not fork a `wfc_prob` handler

- **Subset proof is trivial** when it's the same handler reading optional fields (§2). A fork would duplicate the collapse loop and risk drift.
- **The base case is genuinely the degenerate case** — there is no clean seam to split on. `w=1` and `w=f(n)` differ only at the weight-lookup call site.
- **Engine law:** "new primitive TYPES are rare." A new handler *arm* is heavier than an extended param block; the param block is pure DATA, which is the preferred axis of growth.
- **One authoring surface** (research note) feeds one schema — no "which WFC do I target?" ambiguity.

---

## 4. Adversarial failure modes (iterate)

Per the "iterating = adversarial break-finding" directive, here is how this *breaks*, ranked by how likely + how damaging, each with a mitigation.

### 4.1 Non-convergence / infinite backtracking
**Break:** an evolving weight that zeroes options faster than propagation can satisfy them → the solver rolls back, redraws, hits the same wall, rolls back again → livelock. A `quota` that's mathematically unsatisfiable (target < forced count) guarantees it.
**Mitigation:** hard `backtrack_limit` (default 10000 rollbacks) → on exceed, **fall back to fail-soft** (emit the best partial grid + `contradiction=true` + a new `exhausted=true` flag). Never hang. Additionally, a static **satisfiability pre-check** for `quota` counters (sum of maxima ≥ grid cells for mandatory tiles) surfaces obviously-impossible quotas at parse time.

### 4.2 Runaway positive feedback (one tile eats the grid)
**Break:** `f(n) = 1 + k·n` with large `k` → the first A-B pair makes A-B *much* likelier → the next collapse is almost surely A-B → the grid degenerates into a monoculture (the "rich get richer" pathology; a preferential-attachment blow-up). This is a *quality* failure, not a crash — the grid is legal but boring/degenerate.
**Mitigation:** (a) **cap the multiplier** — `linear` supports an optional `cap` (`min(cap, base + k·n)`) so feedback saturates; (b) **normalize per-cell** — weights are always normalized to a probability *within a cell's domain* (§1.3), so a globally-huge weight can't exceed probability 1 for a single draw, bounding per-step dominance; (c) **document the `inverse`/`quota` ops as the anti-clustering counterweights** and recommend pairing positive feedback on one axis with saturation on another. This failure is *intended* to be reachable (clustering is a feature) but must be *tunable*, which the `cap` + normalization give.

### 4.3 Performance — recomputing distributions every step
**Break:** naive T2 recomputes `W` for every (cell, tile) and re-derives weighted entropy for every cell on every collapse: O(cells² · domain) worst case. On a 100×100 grid that's ~10⁸ evaluations — unshippable for the Townscaper "instant" feel.
**Mitigation:** (a) **dirty-set entropy** — only recompute entropy for cells whose `ctx` changed: the collapsed cell's neighbors, plus (for *global* counters like `tile_count`) a lazy "counter-generation" stamp so a cell re-derives its entropy only when a counter it depends on has moved since it was last evaluated; (b) **incremental counters** — counters are O(1) to update at commit (increment), never rescanned; (c) **local weights are free** — T1 and neighborhood-only T2 weights depend only on the local `ctx`, so they cost the same as the base case; only *global*-counter weights need the dirty-stamp. (d) The **Townscaper local-recollapse** pattern (research note §4) bounds work to the affected neighborhood for the instance editor. Base case (T0) has **zero** added cost — the dirty machinery is skipped entirely when `mode="uniform"`.

### 4.4 Determinism vs. RNG under evolving weights
**Break:** if the weight oracle ever reads *in-flight* (uncommitted) state, or if counter-update order is unspecified, two runs with the same seed could diverge → the core determinism contract shatters silently.
**Mitigation:** the oracle reads **only committed counters** (§1.4); counters update in the **fixed scan/commit order**; weight-expr evaluation sorts its domain by tile name (as the base case already does). A **determinism regression test** (extend `headless_wfc_test.gd`) asserts byte-identical grids across two runs for a T2 ruleset — same contract, new tier.

### 4.5 Contradiction-rate cliff
**Break:** T2 with `quota`/`inverse` can zero *every* option of a cell (all its legal tiles saturated) → a soft contradiction that the base fail-soft path leaves as an empty cell, quietly degrading grid quality without the user noticing *why*.
**Mitigation:** (a) distinguish **hard contradiction** (domain wiped by *adjacency* — a real impossibility) from **soft starvation** (domain non-empty but all weights 0) in the output: a new `starved` count beside `contradiction`; (b) **starvation floor** — an optional `min_weight` (default 0 for T2, but settable) that keeps a saturated tile minimally drawable, trading strict-quota for guaranteed-fill; (c) surface starved cells to the authoring UI as a distinct color (the research note's "red contradiction cell" gets a sibling "amber starved cell").

### 4.6 Weight-expr authoring footguns
**Break:** a `weight_expr` referencing an undeclared counter, a cyclic `ref`, or a negative `base` → garbage weights or a crash.
**Mitigation:** parse-time validation: undeclared counter → weight treated as `const(default_weight)` + a surfaced warning (fail-soft, base-case-preserving); `ref` cycles detected and broken (use `default_weight`); negative results clamped to 0 (or `min_weight`). All *warnings*, never throws — matching the handler's fail-soft posture.

### 4.7 Interaction with `abstract`/`observer` caching
**Break:** the `abstract`/`observer` handlers cache pure scopes by content-hash. A T2 WFC scope's output depends on evolving counters — but the counters are *internal* to one collapse, so the scope is still a pure function of `(ruleset, seed)`. **No break** — T2 stays content-addressable (§1.4). But if a future variant let counters *persist across* generations (a living, cross-run distribution), that scope would become impure and must **not** be cached. Documented now to prevent a future silent-cache-of-a-side-effect bug (the same purity gate `_scope_is_cacheable()` already enforces).

---

## 5. Phased implementation plan

Smallest-first, each phase shippable and independently testable, each preserving the base case. Estimates are P50 hours for a focused implementation session.

### Phase 1 — Static conditional weights (T1) + weighted entropy  ·  ~2.5 h
- Parse `params.wfc.weights` with `mode ∈ {uniform, conditional}` and `entropy ∈ {size, weighted}`.
- Replace the constant lookup in `_wfc_weighted_pick` with a `W(tile, cell, ctx)` that consults conditional `rules` (neighborhood only — no counters yet).
- Implement weighted Shannon entropy in `_wfc_min_entropy_cell`; assert it equals domain-size ordering under uniform weights.
- **Tests:** extend `headless_wfc_test.gd` — (a) base-case regression (uniform => byte-identical to today), (b) a conditional rule measurably biases output frequency, (c) weighted-entropy = size-entropy under uniform.
- **Ship gate:** every existing test passes verbatim (the subset proof, mechanized).

### Phase 2 — Evolving distributions (T2) via declared counters  ·  ~3.5 h
- Add the `counters` block + the closed `track` vocabulary (`tile_count`, `adjacent_pair`, `region_count`, `run_length`).
- Increment counters at commit time; wire `weight_expr` (`const/linear/inverse/quota/sum/product`) into `W`.
- Add dirty-set entropy recomputation (§4.3) + the counter-generation stamp.
- Add the `starved` output + `min_weight` floor (§4.5).
- **Tests:** Liam's example — `P(A|B) ∝ f(n_AB)` — with `linear` producing clustering and `inverse` producing anti-clustering, both **seed-deterministic** (byte-identical across two runs, §4.4). A `quota` counter respects its cap.
- **Tie to the evolver:** a T2 counter-driven distribution **is a genome-over-time** — the weight function's parameters (`base`, `k`, `target`) are exactly the kind of scalar genes `prim_breed.gd` / `EvolverGenome` already crossover + mutate. A WFC ruleset with `weight_expr` parameters becomes an **evolvable artifact**: the Aperture human-fitness loop (`EvolverPopulation → Render2D → ApertureSurface → Breed`) can breed *ruleset distributions*, not just static seeds. This is the deepest payoff — "evolving distributions" folds into the existing supervised evolver with no new machinery.

### Phase 3 — Backtracking + the pin/instance loop  ·  ~3 h
- Implement optional backtracking (`backtrack=true`): on a wiped domain, roll back the most recent collapse, exclude the failed tile, redraw. `backtrack_limit` + fail-soft fallback (§4.1).
- Wire **pins** (fixed cells = allowed-set of one) per the research note's Townscaper/DeBroglie loop — a pin is just a pre-collapsed cell the solver re-solves around.
- **Tests:** a pinned over-constraint that fail-soft would leave contradicted now backtracks to a valid grid; `backtrack_limit` exceed → clean fail-soft fallback, never a hang.

### Phase 4 — The `prim_wfc` authoring surface (staged, supervised)  ·  ~6 h+ (GUI, supervised)
- The GraphEdit rule/instance editors (research note §3–§6): paint-side-labels adjacency, the DeBroglie constraint palette as rule-nodes, **weight-expr as a wired Counter→Math→collapse sub-graph** (§3.3), live weighted-entropy preview.
- This is **supervised GUI work** (gated per the Gizmo/GUI rule) — specified here, built under Liam's supervision, not autonomously.

**Sequencing rationale:** Phase 1 is a pure superset with a mechanized subset proof (lowest risk, unblocks measurement). Phase 2 is the spec's heart and the evolver tie-in (highest leverage). Phase 3 is required only for pins/hard-quotas (bounded scope). Phase 4 is the authoring payoff and is supervised. Phases 1–3 are engine-internal DATA-schema work; only Phase 4 touches the GUI.

---

## 6. Illustrative code sketch (design only — NOT an engine edit)

The *only* change to the hot loop is the weight lookup. Sketch of the generalized draw (conceptual — real impl lands in Phase 1–2, not in this note):

```gdscript
# BASE CASE (today, prim_context.gd _wfc_weighted_pick):
#   var w := weight.get(tile, 1.0)          # constant per-tile weight

# GENERALIZED (design): a weight ORACLE evaluated per (tile, cell):
func _weight(tile: String, cell: int, ctx: Dictionary) -> float:
    var rule = _match_weight_rule(tile, ctx)        # neighborhood + counters
    if rule == null:
        return _base_weight(tile)                   # <- degrades to the base case EXACTLY
    if rule.has("weight"):
        return float(rule["weight"])                # T1 static conditional
    return _eval_expr(rule["weight_expr"], ctx["counters"])   # T2 evolving

# _eval_expr is a pure fold over a closed op set (const/linear/inverse/quota/sum/product).
# ctx["counters"] are read-only committed tallies -> deterministic under the seed.
```

Everything else — the observe/propagate skeleton, the seeded RNG, the fail-soft path, the port enumeration — is **unchanged**. That is the whole design: *un-hide the weight oracle, let it be a function, keep the constant as its degenerate case.*

---

## 7. Summary — the three-bullet model

1. **WFC is already a weighted collapser; determinism is the special case where every weight is 1.** The generalization replaces the constant per-tile weight lookup with a *weight oracle* `W(tile, cell, ctx)` at the single existing draw site, and makes the entropy heuristic weight-aware so observe + collapse stay consistent — no new phase, no new loop.
2. **Three tiers of one oracle, each a strict superset of the last:** T0 static-uniform (today's code), T1 static-conditional (`P(A|neighbor=B)`), T2 evolving-distribution (weight = a pure function of generation-state counters the collapse itself writes — Liam's `P(A|B) ∝ f(n_AB)`). All fields optional; a base-case `params.wfc` is a valid subset, so `headless_wfc_test.gd` passes verbatim (mechanized subset proof).
3. **Evolving distributions ≈ genome-over-time:** a T2 weight-function's parameters (`base`, `k`, `target`) are evolvable genes, so a WFC ruleset folds into the *existing* supervised evolver (Breed/EvolverPopulation/Aperture human-fitness) with no new machinery — and the whole weight-function is authored as a wired Counter→Math→collapse sub-graph (node-wiring simplicity law), keeping it DATA, not code.


---

## 8. Implementation appendix — adversarial findings from the build (2026-07-02)

Phases 1–3 (minus pins) landed in `godot/primitives/wfc_generalized.gd` + the dispatch seam in
`prim_context.gd` (branch `feat/wfc-probabilistic`, 2026-07-02; suite `godot/headless_wfc_prob_test.gd`
21/21 ALL PASS, base suite `headless_wfc_test.gd` untouched and green).
The §2 subset proof is mechanized: uniform/static configs routed through the generalized path are
byte-identical to the base handler across 4 rulesets × 5 seeds (grid + contradiction + collapses).
Findings from the adversarial pass, beyond what §4 predicted:

1. **Propagation-forced cells must feed the counters.** A cell decided by *propagation* (domain
   reduced to 1 without an observe) is committed state, and Liam's `n_AB` must see it — otherwise
   the evolving weight lags the visible grid. The implementation commits via a post-propagate
   ascending-index sweep, so counter order is deterministic and each adjacency edge is counted
   exactly once (when its second endpoint commits). A naive "increment at observe" would have
   silently undercounted on constrained rulesets.
2. **Starved cells must not consume RNG draws.** The soft-starvation fallback (§4.5) returns before
   the `randf()` call — matching the base handler's zero-total early-return — so a starved draw does
   not shift the RNG stream. Getting this wrong breaks nothing visibly on the starved run but
   de-syncs *later* draws, a reproducibility hazard that only shows up as "same seed, different
   grid" two features later.
3. **Weighted entropy collapses starving cells EAGERLY.** A cell whose every option has weight 0
   reports H = 0 (maximally determined), so `entropy:"weighted"` observes it next and starved-fills
   it immediately. This is deterministic and arguably correct (the cell has no probabilistic future)
   but it front-loads quota-violating fills instead of leaving them to the end — documented as
   intended behavior; `min_weight > 0` avoids it entirely.
4. **Backtracking memory is O(n² · |tiles|), not O(n).** Each frame snapshots all domains, so a
   50×50 backtracking run holds up to 2500 full-grid copies. Fine for the opt-in small/medium grids
   it targets (pins, hard-ish quotas); a bounded-depth trail (keep last K frames, blame beyond it
   falls back to fail-soft) is the natural follow-up if large backtracking grids ever matter.
5. **Root exhaustion ≠ budget exhaustion.** A genuinely unsatisfiable ruleset exhausts the *trail*
   (every root option tried) long before a sane budget — that run reports `contradiction=true,
   exhausted=false`. `exhausted=true` is reserved for the budget cap (§4.1 livelock guard), proven
   by the `backtrack_limit:1` test. Conflating the two would make "raise the limit" look like a fix
   for impossible rulesets.
6. **`run_length` wants to be an at-read counter, not a commit tally.** "Current consecutive run"
   is a property of the cell being weighed; implementing it as a global commit-time tally is
   ill-defined (which run?). Reading the adjacent committed run at draw time gives DeBroglie's
   Max-Consecutive exactly (quota target 3 → no run of 4 can ever complete, proven in the suite)
   and stays a pure function of committed state, so determinism holds. Its generation stamp bumps
   on every commit of its tile (conservative) so weighted-entropy caches never go stale.
7. **Performance (measured, GDScript, headless, 2026-07-02).** 30×30: base 217 ms vs
   generalized-uniform 231 ms (≈6% overhead — the T0 zero-cost claim holds; the O(n) observe scan
   dominates both). 50×50: base 1633 ms vs generalized-uniform 1548 ms (within run-to-run noise).
   Worst case wired — T2 pair-feedback + weighted entropy, 30×30 — 4684 ms (~20× base): the
   `adjacent_pair` counter moves on nearly every commit, so the per-counter stamps (§4.3) still
   invalidate most cells' H every step; the dirty-set only pays off for T1/local rules and
   slow-moving counters. Acceptable at current sizes; the documented hotspot if editor-scale
   interactivity is ever needed — Townscaper local-recollapse (research note §4) remains the plan
   there, not micro-optimizing the global recompute.

Deferred exactly as staged: **pins** (Phase 3's second half — tied to the instance-editor loop) and
the **Phase 4 authoring GUI** (supervised). The evolver tie-in (§ Phase 2, "a T2 ruleset is a
genome") needs no engine work — `base`/`k`/`target`/`cap` are already scalar genes in DATA.
