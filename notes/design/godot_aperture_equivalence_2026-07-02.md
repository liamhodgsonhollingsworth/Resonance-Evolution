# Godot Aperture ↔ web Aperture equivalence — readiness note

**Status 2026-07-03:** SHIPPED (branch `feat/godot-aperture-v1`). The Aperture lives inside the
engine as two scenes, with full read/write equivalence to the web board and to the (peer-lane)
web evolution API. Liam's steer this arc: *"Focus on getting in game live iteration and aperture
working, as the evolution pages and things should be equivalently compatible with godot."*

## What "equivalent" means here (the invariant)

Two surfaces, ONE substrate. Neither surface is a port of the other; both are dumb views over
the same files/endpoints, so a decision made in either is indistinguishable to every consumer:

| Layer | Substrate (shared) | Web view | Engine view |
|---|---|---|---|
| Inbox cards | `Alethea-cc/state/aperture/inbox/inbox.jsonl` (+ `GET /api/aperture/inbox`) | board | `aperture_3d.tscn` arc of 3D panels |
| Decisions | `feedback.jsonl` rows `{artifact_id, action, decided_at, by}` (+ `POST /api/aperture/feedback`) | ✕/evolve/save buttons | X/E/V keys on the aimed panel |
| Bookmarks | `bookmarks.jsonl` rows `{tile_id, saved_at, by, ...}` (+ `POST /api/aperture/bookmark`) | ★ | B key |
| Evolution index | `godot/state/evolver/textures/*_cards.jsonl` + `lineage.jsonl` (+ `GET /api/aperture/evolver`) | evolution page, generation columns | `evolution_3d.tscn`, generation columns in 3D |
| Branches | `godot/state/evolver/textures/branches.jsonl` (append-only, 10-key record) | save-as-branch button | aim + G in the detail view |
| Live params | arrangement JSON on disk → LiveHost content-hash hotload | (web GUI edits the same file) | `[`/`]` keys edit the aimed tile's gene |

Channel selection is DATA: the engine tries the server (`:8770`) first and falls back to reading
the substrate files directly with the server's own semantics (last-wins id collapse,
latest-action hide on the board, decided-cards-kept on the evolution page).

## Schema decisions shared with the web lane (Resonance-Website `feat/aperture-evolution-pages`)

- `EvolverSubstrate` (godot/aperture/evolver_substrate.gd) mirrors
  `static/aperture/endpoints/evolver.py` field-for-field. State dir: the web's
  `APERTURE_EVOLVER_STATE_DIR` default IS the engine's `res://state/evolver/textures` in the
  main checkout — one dir, two readers.
- Branch record (append-only `branches.jsonl`): exactly the web's 10 keys —
  `branch_id ("br_"+8hex)`, `card_id`, `source_genome_id`, `off_generation`, `genome`
  (lineage-ready: `id "gen_<usec>_br"`, `parent_ids=[source]`, `origin "branch"`, `stack`),
  `image|null`, `note|null`, `created_at` (ISO-8601Z), `by "liam"`, `origin "branch"`.
- Media URLs (`/api/aperture/media?path=...`) are a serving detail; the LOCAL path is identity.
  The engine maps URLs back to local paths when consuming the http channel (mirror-inverse of
  the web's `media_url_for`), same rule the web's branch handler applies inbound.
- **Additive extension (engine-only, no web gap):** none needed — the engine consumes and
  produces the web schema unchanged. Branch preview PNGs land under
  `<state_dir>/branches/*.png`, which the web serves via its media route without code changes.
- Cross-lane proof in CI: `headless_evolution3d_test.gd` extracts the REAL web module from the
  peer branch (`git show`) and imports it with the real python against the fixture dir Godot
  wrote — `card_genome_map()` and `read_branches()` read back Godot's rows byte-compatibly.

## Live-iteration proof (Liam's #1 ask)

Inside one running instance, no restart: `[`/`]` on an aimed wall tile edits a texture gene ON
DISK (schema-aware clamp) → the standard LiveHost content-hash watcher hotloads → the tile
re-synthesizes visibly. T runs a mock evolver tick (gen-0 seed → in-engine E/V/X decisions →
next T breeds gen+1 in place). Headless state-transition proof: `headless_aperture3d_test.gd`
sections 5–6 (pixel-hash change on hotload, generation advance from in-engine decisions).
Windowed proofs: `godot/docs/aperture_3d.png`, `godot/docs/evolution_3d.png`.

## First-wave tool matrix — how each surfaces in-engine

| Tool (PR) | In-engine surface today | Gap to full Aperture equivalence | Effort |
|---|---|---|---|
| Textures (#130, #135) | FULL: evolver candidates as generation columns; live gene nudge; in-engine variants + save-as-branch; renders via `TextureSynthCpu` (same code the render CLI uses) | — (this lane) | done |
| Painterly (effect stacks) | Genome kind already polymorphic (`EvolverGenome` effect kind); evolver primitives drive it | Detail-view variant rendering dispatches on texture kind only; add `EffectStackCpu.apply` branch to `_card_image`/variants | ~0.5 h |
| WFC (#133) | Runs as primitives; outputs render in scenes | No genome/card map writer yet → cards can't join to a WFC genome on the evolution page; define a WFC genome `stack` payload (rules+weights) and reuse the same `*_cards.jsonl`/`lineage.jsonl` shapes | ~2 h |
| Projection (#126) | Scene-level demo | Surface = pushing preview cards (works today via aperture_push); param iteration via the same arrangement-file hotload the wall uses | ~1 h wiring |
| Stereogram (#128) | `StereoRender` primitive; stereo modes are DATA | Same as projection: push cards + expose the stereo descriptor as a live-nudgeable arrangement | ~1 h |
| Sandbox (#127/#131) | Hotloading sandbox + TextureApply node | Aperture-in-sandbox: instance `aperture_3d.tscn` as a sub-scene (it is self-contained); block-texture genomes already share the texture substrate | ~1–2 h |

## Failure modes found while building

- `look_at` before `add_child` crashes (node not in tree); panels also need a PI flip (`look_at`
  aims −Z). Fixed in v1 tail.
- The web `/api/aperture/evolver` endpoint is not live yet (peer branch unmerged) — the room's
  http fetch correctly falls back to files; when the web lane merges, the engine consumes their
  endpoint with zero changes (parse verified against the module's exact response shape).
- Godot 4.6 `.uid` files must be committed or every checkout regenerates them as churn.
- Stale worktree registrations (the peer lane's worktree dir was deleted with the host death)
  — `git show <branch>:<path>` is the reliable way to read a peer lane's files.
