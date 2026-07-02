# The supervised painterly evolver loop (GZ-EVOLVE.1)

Status 2026-06-30. Companion to `README.md` (the design law), `COMMUNICATION-ARCHITECTURE.md`
(communication-is-a-module), and `renderers/effect_genome.gd` (the look genome this loop breeds).

> **The directive (Liam, verbatim).** *"Use the node system as a genomic evolver, with the evolver
> itself evolving through your use, and the ability to add new nodes and features that have different
> properties."*

This document is the contract for the **supervised painterly evolver**: a human-in-the-loop GAN-style
loop (mirroring `notes/writing_evolution/v1_design.md` in Wavelet) where Liam is the **fitness
function** — never a detector — expressed by three actions per candidate, and the **Aperture** is the
fitness surface. It breeds **painterly LOOKS** first (the effect-stack genome already in the repo).

The whole loop is a **NODE SYSTEM**, not new engine logic: four new primitive TYPES wired as an
arrangement of DATA. The genomes and the evolver's own parameters live in node `params` (DATA), so the
evolver evolves through use and adding a new gene / operator / button is **additive**, never a
foundation edit.

---

## 1. The loop (exact semantics)

```
EvolverPopulation ──population──▶ Render2D ──rendered──▶ ApertureSurface(push)
                                                              │ cards (X / Evolve / Save)
                                                              ▼
                                                        … Liam decides (human-paced) …
                                                              │
   ◀──population(next)── Breed ◀──readback── ApertureSurface(readback)
        (loop closes back into EvolverPopulation.in as the next generation)
```

1. **SEED** a generation of `N` painterly genomes (`N = meta_genome.population_size`, default 2 — the
   GEN_STEP, a DATA param). Gen-0 is `N` random valid effect stacks.
2. **RENDER** each candidate: `EffectStackCpu.apply(genome.to_stack(), source)` over a FIXED demo
   source image → one real PNG thumbnail per candidate. No 3D path needed; the candidate Liam judges
   is a picture.
3. **SHOW**: push each thumbnail as an Aperture card. The built-in **X** is the skip; plus
   `--action evolve:Evolve --action save:Save`. Record the `card_id ↔ genome` map in the generation
   state.
4. **READ BACK**: poll the card decisions and map each card's action onto a breed disposition.
5. **NEXT GEN**: once **every** card of the generation is decided, **breed**: KEEP survivors
   (evolve + save) + CROSSOVER the bookmarked (saved) pairs + INJECT 1–2 fresh mutated genomes → the
   next generation (append-only lineage: each genome records `parent_ids` + `generation` + `origin`).
   Then GOTO 2 for the new generation.
6. **ASYNC + PERSISTENT**: Liam takes time to press buttons, so the loop is **human-paced** and
   **stateful**. ALL generation / lineage / card-id state persists under a **gitignored** dir
   (`godot/state/evolver/painterly/` for a tracked-repo state-dir, or `user://evolver/painterly/`).
   The `evolver_tick` is idempotent + safe to re-run: it advances only when the current generation is
   fully decided, otherwise it is a no-op.

### The X / Evolve / Save grammar → KEEP / PIN / CULL

| Aperture action | Breed disposition | Meaning |
|---|---|---|
| **Evolve** (`evolve`) | **KEEP** | This look is good — carry it forward AND breed from it (a survivor/breeder). |
| **Save** (`save`)     | **PIN**  | Pin this exact variant (a frozen archive) AND keep it as a breeder. Save = keep + archive; pinned genomes are the pool CROSSOVER mixes. |
| **X / skip** (built-in skip; `skip` / `reject` / `cull` / empty / unknown) | **CULL** | Drop it — does not survive, is not bred from. Unknown actions default to CULL (fail-safe: an unrecognized verb never silently breeds). |

The next generation is composed as:

```
next = KEEP survivors (evolve + save)         ── elite carry-forward (capped to leave inject room)
     + CROSSOVER of pinned (saved) pairs       ── mix the explicitly-loved looks
     + INJECT 1..2 fresh MUTATED genomes        ── new blood, never converge to one
```

sized to `meta_genome.population_size`. A fully-culled generation still recovers (INJECT floor: mutate
a survivor, or a fresh random seed if none survived) — the population is never empty.

---

## 2. Node decomposition (the four new primitives)

All four are registered in `runtime/graph_runtime.gd`. They reuse the existing look genome
(`EffectGenome`) and CPU applier (`EffectStackCpu`) verbatim — **no pixel math or genome operator is
reimplemented**. New FUNCTIONS, here, are an arrangement; the new TYPES are the minimal seam the
arrangement needs.

| Primitive | File | Role | Emits |
|---|---|---|---|
| **EvolverPopulation** | `primitives/prim_evolver_population.gd` | The genome STORE: holds one generation of `EvolverGenome`s + the `meta_genome`, as DATA in `params`. | `population` = `{ population:[genome…], generation, meta_genome }` |
| **Render2D** | `primitives/prim_render2d.gd` | genome → PNG thumbnail via `EffectStackCpu.apply` over a fixed (or supplied) source. | `rendered` = `{ rendered:[{genome, image_path, ok}], generation, meta_genome }` |
| **ApertureSurface** | `primitives/prim_aperture_surface.gd` | The human-in-loop FITNESS seam: `op=push` records cards (X/Evolve/Save) on the Aperture; `op=readback` reads each card's decided action. `mode=live` shells to the real Aperture tools; `mode=mock` is the headless dry-run. | `surface` (push or readback descriptor) |
| **Breed** | `primitives/prim_breed.gd` | A decided generation → the next `population`, via the pure `EvolverBreed.breed` algebra (KEEP/CROSSOVER/INJECT). | `population` (the next generation) |

Supporting **DATA modules** (pure functions over data, no Godot type on the wire — headless +
deterministic):

- `evolver/evolver_genome.gd` — **EvolverGenome**: a lineage-bearing wrapper around `EffectGenome`
  (`id`, `generation`, `parent_ids`, `origin` ∈ seed/keep/pin/crossover/inject). Breeding methods
  return NEW genomes with correct **append-only** lineage; the source is never mutated.
- `evolver/breed.gd` — **EvolverBreed**: the KEEP/CROSSOVER/INJECT algebra (the `disposition_for`
  action map lives here). Pure; called by `PrimBreed`.
- `evolver/evolver_state.gd` — **EvolverState**: load / save / seed / lineage persistence under the
  gitignored dir (atomic `state.json`, append-only `lineage.jsonl`).
- `evolver/evolver_tick.gd` — **EvolverTick**: the idempotent, resumable one-step orchestrator that
  drives the four primitives over the persistent state.

### Driver / tick

- `evolver_tick_cli.gd` — the CLI entrypoint (one human-paced tick), `--mode mock|live`,
  `--state-dir`, `--seed`, `--feedback` (mock), `--pop`, `--inject`, `--source`.
- The tick: load state (seed gen-0 if none) → render → push cards if not yet pushed → read back →
  if **all decided**, breed + advance + render + push the new generation; else leave it (wait for Liam).
  Re-running is a safe no-op for an undecided generation.

---

## 3. State persistence (gitignored — load-bearing)

ALL human-interaction state lives under a **gitignored** dir
(`godot/state/evolver/` is in `godot/.gitignore`; the tick + test default to `user://…`):

```
<state_dir>/state.json      # current generation: {generation, meta_genome, population[], cards[], pushed}
<state_dir>/lineage.jsonl   # APPEND-ONLY: every genome ever born (the full lineage, never rewritten)
<state_dir>/thumbs/         # rendered PNG thumbnails (g<gen>_<id>.png)
<state_dir>/mock/           # mock-mode would-be cards (never written in live mode)
```

This is a **load-bearing** Wavelet lesson (`reset_hard_wipes_uncommitted_user_data`, mistakes #031):
host launchers `git reset --hard` on restart and would wipe accumulated generations + Liam's pins if
they lived in a tracked file. User-interaction state is **never** a git-tracked file.

---

## 4. The meta-evolution SEAM (provided, NOT fully built)

The evolver's OWN params live in DATA as the `meta_genome` on the `EvolverPopulation` node:

```json
{ "population_size": 2, "n_inject": 1, "seed_layers": 3,
  "actions": [ {"id":"evolve","label":"Evolve"}, {"id":"save","label":"Save"} ] }
```

These are the knobs a **future** meta-evolution driver would itself mutate from Liam's selection history
(do MORE of what he keeps, LESS of what he culls; widen/narrow the button set; tune N / mutation pressure).

**The seam, ready to hook:**
- The params are DATA (`params.meta_genome`), merged over `DEFAULT_META` at the single read point
  `PrimEvolverPopulation.meta_genome()`.
- The `meta_genome` rides every descriptor (`population` → `rendered` → `surface` → `population`), so a
  driver that rewrites it is picked up on the next hotload with **zero code change**.

**What is deliberately NOT built here** (no auto-generalization — a sequenced follow-on): the
meta-evolution *policy* itself (the function that reads selection history and mutates `meta_genome`).
This loop only provides the seam + this note. Adding it later is a new driver module, never a
foundation edit.

---

## 5. Extensibility (additive, never a foundation edit)

- **A new gene / effect layer** → one entry in `EffectStackCpu.EFFECT_TYPES` (+ its applier branch).
  The evolver reads the vocabulary from there, so mutate/crossover pick it up automatically.
- **A new breed operator** → a new branch in `EvolverBreed.breed` (e.g. a different crossover mix).
- **A new fitness action** (a new verb beyond X/Evolve/Save) → a new `{id,label}` in
  `meta_genome.actions` + a new branch in `EvolverBreed.disposition_for`. Additive at both the surface
  (a new `--action id:Label`) and the breed map.
- **A new candidate** → a new entry in `params.population`. The nodes are dumb DATA holders.

---

## 6. Live surface (the Aperture session's separate work)

The **data path** is what this work built + verified: `ApertureSurface` pushes via
`G:/Wavelet/Alethea-cc/tools/aperture_push.py` (with `--action evolve:Evolve --action save:Save` and a
`file://` thumbnail URL) and reads back via `aperture_feedback.py` (`latest_decision` by the `apx_` id).

The **live top-row UI** — the pinned "Painterly Evolution" Aperture tile, the actual rendering of the
X/Evolve/Save buttons on the card, and the generation-columns presentation — is the **Aperture
session's** separate work, coordinated separately. This engine-side loop only owns the transport
(push + readback) and the breeding.

---

## 7. How to run + verify

```
# REQUIRED after adding/renaming a class_name script (build the class cache):
godot --headless --path godot --editor --quit-after 120
# the full data-path cycle, headless, mock-only (NEVER touches the live Aperture):
godot --headless --path godot -s res://headless_evolver_test.gd      # RESULT: ALL PASS (nonzero exit on fail)
# one human-paced tick from the CLI (mock dry-run):
godot --headless --path godot -s res://evolver_tick_cli.gd -- --mode mock --state-dir user://evolver/painterly --feedback <fake_feedback.json>
# live (pushes real cards + polls real decisions — the production path):
godot --headless --path godot -s res://evolver_tick_cli.gd -- --mode live --state-dir godot/state/evolver/painterly
```

The headless test proves: seed → render candidates to valid non-empty PNGs → (mock) the three actions
evolve/save/skip → breed → next generation has the right size with KEEP/CROSSOVER/INJECT applied →
every genome renderable → lineage append-only (`parent_ids` present, never mutated) → state persists
under the gitignored dir → a re-run resumes (idempotent). A final guard asserts the live Aperture inbox
contains **no** row tagged by this evolver — the test never touched Liam's live surface.

---

## 8. Genome KINDS — the loop is genome-polymorphic (2026-07-02)

The four primitives + the breed algebra + the tick are **genome-KIND-blind**. `EvolverGenome` (the
lineage wrapper) is the single polymorphic point: it wraps EITHER

- an **`EffectGenome`** (`renderers/effect_genome.gd`) — the painterly post-process stack this
  document was written for (payload key `stack`), or
- a **`TextureGenome`** (`evolver/texture_genome.gd`) — the **procedural-texture genome**: an ordered
  list of mathematical construction ops (`value_noise`, `fbm`, `sine` interference, `stripes`,
  `checker`, `radial`, `voronoi`), each fused with a **palette HANDLE** (into
  `TextureSynthCpu.PALETTES`, the one relinkable palette registry — never raw RGB in a genome), a
  blend op + opacity, and per-op domain warping. Payload key `texture_ops`. Rendered by
  `renderers/texture_synth_cpu.gd` (`synthesize` — pure hash-based, NO RNG in the render layer, so a
  genome is byte-identical across runs).

The serialized **payload key is the discriminator** (`stack` → effect, `texture_ops` → texture) — no
schema change, so every pre-existing painterly lineage loads unchanged. `Render2D` dispatches per
candidate (texture genomes GENERATE their tile; effect genomes post-process the source), and
`meta_genome.genome_kind` ("effect" default | "texture") tells gen-0 seeding + the fully-culled
recovery floor which family to draw fresh seeds from. **Kinds never interbreed**: a mixed-kind
crossover degrades to a clone of parent A (a degenerate one-point cross), so a mixed population is
safe but pointless — run one kind per state dir.

Adding a THIRD genome kind = a new genome class with the same duck contract (`clone/mutate/to_stack/
is_valid` + static `random/crossover/from_stack`), a payload-key branch in `EvolverGenome.from_dict`
+ `random_seed`, and a render delegate branch in `Render2D` — additive, never a foundation edit.

Texture-specific verification: `headless_texture_evolver_test.gd` (full cycle, mock-only, live-inbox
guard). Gen-0 driver for the live surface: `texture_gen0_cli.gd` (renders tiles + prints
`CANDIDATE <genome_id> <png> <caption>` for the Aperture-push driver; pushing stays outside the
engine, exactly like the painterly path's separation of transport and presentation).
