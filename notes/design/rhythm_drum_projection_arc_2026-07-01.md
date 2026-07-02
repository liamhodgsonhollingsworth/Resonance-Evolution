# Rhythm-game drum projection-teaching arc — in-engine simulation design

**Status:** research + design (no engine build this stage).
**Date:** 2026-07-01. **Author:** design subagent (coordinator session 143b110f).
**Spec source (verbatim):** Liam 2026-07-01, Aperture chat U11 — captured in Wavelet memory `project-rhythm-drum-projection-arc-2026-07-01`.
**Companion diagram:** [`rhythm_drum_projection_nodegraph.svg`](rhythm_drum_projection_nodegraph.svg) (the simulation node graph).

> **One-line thesis.** A drum kit 3D model in the engine + a *simulated* overhead projector that projection-maps each upcoming drum hit as a **shrinking circle converging onto a target point** on the specific drum/rim/cymbal zone. The circle timeline is generated **procedurally from raw music** (MIDI drum track / MusicXML) — no hand-authoring. Practice slowdown and dynamic BPM ride a **wired real-value knob** (the already-designed `TuningKnobNode`). The projector and its calibration are simulated with the **same projection-mapping + camera-feedback-loop nodes** the modular-laser-projector / website-projection-and-audio-sync arcs use — one substrate, not a fork. Optional osu-style reactive scoring is *allowed by the node design* but not required.

---

## 0. How this composes with the sibling projection arcs (read first)

Liam asked to **move the two sibling arcs up in the queue** because this rhythm-drum arc *rides their substrate*:

| Sibling arc | Charter | What the drum arc reuses |
|---|---|---|
| **Projection and audio-sync** | `G:\Wavelet\notes\projects\projection_audio_sync.md` | The master-clock + per-device **ms-offset** node pair (shipped: `projection/sync/`), the timeline-source to sync to output-adapter node family, and the wall-clock-anchored resync (never "time since connected"). A *projector* is just another **output adapter** on the shared timeline. |
| **Modular laser projector** | `G:\Wavelet\notes\projects\modular_laser_projector.md` | The **universal-bridge seam** (`design_laser_universal_bridge_seam`): one internal point/frame protocol to thin edge adapters, **simulation-first** as the default safe dev surface. The projector in this arc is a simulated video projector rather than a galvo, but the seam pattern is identical. |

**The shared missing piece both charters name but neither has built yet is the CAMERA-FEEDBACK CALIBRATION LOOP** (projection_audio_sync names auto-calibration seeding "from available signals"; the laser charter names simulation-first galvo preview). This arc is the natural place to *formalize that loop as a reusable node*, because a drum kit is a small, static, well-lit rig where closed-loop optical calibration is tractable and testable in-engine. So the deliverable is: **the drum-teaching feature AND a `ProjectionCalibration` node the whole projection family inherits.**

This obeys the node-wiring-simplicity law and the "one substrate, cross-functionality" principle in Wavelet memory (`feedback-node-wiring-simplicity-law`).

---

## 1. Prior-arc synthesis — the "buried" arc, found

The concept Liam remembered is **not** a fully-designed prior arc; it is a **founding feature from the very first Notion entry (2026-05-21)** that was catalogued and given a substrate contract, then parked at `Could`/`Won't` priority. Three layers of prior work exist and must be built on, not reinvented:

### 1a. The origin feature — F102 / F062 "Iterated instrument-practice method"
- **Where:** `G:\Wavelet\notes\website_planning_arc\feature_index_from_notion.md` (F101–F104 block, "Q. Practice-by-iteration system"); catalogued as **F062** in `G:\Wavelet\notes\website_planning_arc\deep_scan_results.md`; session-intent line in `G:\Wavelet\notes\session_intent\24770905_first_message_notion_entry_5_21_2026.md`.
- **Liam verbatim (Notion 2026-05-21):** *"Begin learning an instrument, according to the system's best current understanding of those resources, and update the understanding of those resources and methods. This also relates to a new method of practicing I am developing, the iterated and evolving method: every practice session uses the results of the last to figure out how to structure the next..."* — the full method: warm-up (scales/chords/theory) then unstructured tuning-in then **structured speed-laddered piece-practice** then **per-session BPM tracking with a regression algorithm predicting the next-most-likely BPM**, with mutations getting gradually more drastic.
- **Framing:** delivered as a **self-improvement game element / side-quest** (alongside career-planning, party-planning, minecraft-modding), all through the GUI builder.

### 1b. The substrate contract — SPEC-229 "Iterated-instrument-practice contract"
- **Where:** `G:\Wavelet\Alethea-cc\nodes\spec_229_iterated_instrument_practice_contract.md` (status: pending, priority: could). Source Brief 13 Decision G5; cites N-F102, DS-F062.
- **What it fixes:** a per-session node `practice_session_<id>.md` carrying `{warm_up, unstructured_tuning, structured_speed_ladder, maintenance_state}`. **Each session's INPUT loads the prior session's `outputs` + `maintenance_state`; each session's OUTPUT extends `structured_speed_ladder`.** A Phase-2 predictor reads the chronological history and predicts next-most-likely-BPM. This is the **evolving-practice loop** the drum arc plugs into: the projected-circle timeline for a given piece is generated at the BPM the predictor recommends for *this* session.

### 1c. The music + hardware substrate — Brief 14 + the tuning-knob extension
- **Brief 14 (music + visualization + visi-sonor):** already contracts `MusicNode` (per-note-as-node, Decision M7), `scroll-music-binding` (M8), `AudioPlayerNode` (M3), painterly module-graph (M4), and — critically — a **`visi-sonor` `HardwarePortNode` (Decision M6)**: the pre-existing abstraction for "MIDI/LED/launchpad hardware in and visual-sound out." Referenced from `G:\Wavelet\notes\claude_ai_sessions_index.md` and `notes/website_planning_arc/planning_briefs/14_music_visualization_visi_sonor.md`. The **"Visi-sonor" deferred item** (LED keyboard / launchpad for visual-sound output, `notes/session_intent/...`) is the hardware sibling of this drum arc — same "music to projected/lit visual instruction" shape.
- **The dynamic-BPM knob already exists as a designed primitive.** `G:\Wavelet\notes\website_planning_arc\architectural_extensions\music_and_tuning_knob.md` designs **`TuningKnobNode`** (SPEC-286) + **`temporal-dynamics-program`** (SPEC-287): a single real-valued dial that binds to *any* parameter on any node, with an equilibrium and forward/back semantics. **Liam's "dynamic BPM knob on the projector's computer" is a `TuningKnobNode` bound to the timeline's `bpm` / `time_scale` parameter — a node-add, not a new mechanism.** The temporal-dynamics curve (bigger changes when held longer/farther) is a nice-to-have for "scrub tempo," not required for v1.

**Net:** the prior arc gives us (i) the *pedagogy* (evolving speed-ladder practice, SPEC-229), (ii) the *music-as-nodes* substrate (MusicNode / HardwarePortNode, Brief 14), and (iii) the *tempo control* primitive (TuningKnobNode). This design contributes the missing middle: **music to per-drum hit-timeline to projected shrinking-circle instructions to simulated calibrated projector.**

---

## 2. Music-format research — raw music to per-drum hit timeline

The generator must ingest the **most universal machine-readable drum representations** and emit a neutral hit-timeline. Two input formats cover ~everything; a third (osu) is the optional reactive hookup.

### 2a. Standard MIDI File (SMF) — the primary, most-universal drum source
- **Percussion lives on MIDI channel 10** (zero-indexed 9) under the **General MIDI Percussion Key Map**: each *note number* is a *drum piece*, not a pitch. Verified numbers ([General MIDI, Wikipedia](https://en.wikipedia.org/wiki/General_MIDI)):

  | GM note | Piece | Default projected zone |
  |---|---|---|
  | 35 / 36 | Acoustic / Electric **Bass (Kick)** | kick pedal-beater target (or a floor marker) |
  | 38 / 40 | Acoustic **Snare** / Electric-Rimshot | snare head center / snare rim |
  | 42 | **Closed Hi-Hat** | hi-hat top, center |
  | 46 | **Open Hi-Hat** | hi-hat top, outer ring |
  | 44 | **Pedal Hi-Hat** | hi-hat foot marker |
  | 41 / 43 / 45 / 47 / 48 / 50 | **Toms** (low-floor to high) | each tom head center |
  | 49 / 57 | **Crash 1 / Crash 2** | crash bow / edge |
  | 51 / 59 | **Ride 1 / Ride 2** | ride bow |
  | 53 | **Ride Bell** | ride bell (small target) |
  | 55 | Splash, 52 China, 39 Clap ... | mapped as available |

- **Parsing to events:** read `note-on` events with `velocity > 0` on channel 10. Each event to `{ t_seconds, gm_note, velocity }`. **`t_seconds`** comes from the SMF **tick-to-seconds** conversion using the file's `division` (ticks-per-quarter) and the running `set-tempo` (microseconds-per-quarter) meta events — so tempo maps and mid-song tempo changes are honored natively. Velocity to circle emphasis (size/opacity), giving dynamics "for free."
- **Why universal:** every DAW, drum-machine, notation app, and e-drum module exports/consumes GM-mapped MIDI; e-drum kits (Roland/Alesis) emit it live over USB-MIDI. This is also the natural **live-input** path (a real e-kit becomes a `HardwarePortNode` per Brief 14 M6).

### 2b. MusicXML — the sheet-music path
- **MusicXML** is the universal notation interchange (Finale/Sibelius/MuseScore/Dorico). Drum notation uses **`<unpitched>`** note elements plus a **`<instrument>` to MIDI `<midi-unpitched>`** mapping in the part's `score-instrument`/`midi-instrument` — i.e. it *already carries the GM note number*, so it collapses onto the same event schema as MIDI once you resolve `<divisions>` + `<sound tempo="...">`.
- **Role:** the "sheet music" input Liam named. Slightly heavier to parse (measures, divisions, repeats, tempo directions) but yields the *same* neutral `{t_seconds, gm_note, velocity}` stream. Recommend MIDI-first (v1), MusicXML as the second adapter behind the same port (the universal-bridge seam again).

### 2c. osu! / osu!mania (or an isomorphic beat-map) — the OPTIONAL reactive hookup
- **`.osu` file format** ([osu! wiki](https://osu.ppy.sh/wiki/en/Client/File_formats/osu_%28file_format%29)): `[TimingPoints]` lines are `time,beatLength,meter,...,uninherited,effects` — an *uninherited* point's `beatLength` (ms per beat) gives **BPM = 60000 / beatLength**. `[HitObjects]` lines are `x,y,time,type,hitSound,...` — each hit is a **screen position + millisecond time + type**. osu!mania uses columns (x maps to a lane) — an exact analogue of "which drum."
- **The osu "approach circle" IS Liam's shrinking circle.** In osu!, a ring spawns large around a hit-circle and **shrinks to meet it at the exact hit time**; you click on convergence. Our projected shrinking-circle-onto-a-drum-point is the *same mechanic, projected onto physical drums* instead of a screen. This is a strong validation that the instruction model is a known-good rhythm-teaching pattern.
- **Isomorphism (the "or isomorphic functionality" in the spec):** a beat-map is just `(lane/target, time_ms, [type])`. Our neutral hit-timeline `(gm_note to target_zone, t_seconds, velocity)` is **isomorphic to a mania beat-map**. So: (i) we can *import* a `.osu` map as an alternative source, and (ii) we can *export* our generated timeline as a `.osu`/beat-map for a scoring engine. The node design keeps this optional by making "scoring" a *separate downstream node* that consumes the same timeline the projector consumes — presence of a scorer never changes the instruction generator.

### 2d. The neutral hit-timeline (the format everything converges to)
All three sources normalize to one portable, renderer-neutral descriptor on a wire (the engine's "data on a port, never a live object" law):

```json
{
  "kind": "hit_timeline",
  "source": "midi|musicxml|osu",
  "ppq_or_divisions": 480,
  "tempo_map": [ { "t_seconds": 0.0, "bpm": 120.0 }, { "t_seconds": 41.0, "bpm": 132.0 } ],
  "hits": [
    { "t_seconds": 0.500, "target_zone": "snare_head", "gm_note": 38, "velocity": 100 },
    { "t_seconds": 0.500, "target_zone": "kick",       "gm_note": 36, "velocity": 112 },
    { "t_seconds": 0.750, "target_zone": "hihat_closed","gm_note": 42, "velocity": 78 }
  ]
}
```
Note two hits at `t=0.500` — **simultaneous limb hits are first-class**, not a special case (see section 5). `target_zone` is a *logical* name resolved against the specific kit model's calibration map (section 4), so the same timeline plays on any kit layout.

---

## 3. The projection-teaching model — shrinking circles converging to points

### 3a. Geometry of one instruction
For each hit `h`, the generator emits a **`circle_instruction`**: a ring that spawns at `t = h.t_seconds - lead_time` at radius `R0`, **shrinks linearly (or ease-in) to `R_target` at exactly `t = h.t_seconds`**, centered on the target point `p` in the *drum surface's* local UV space (rim, bow, bell, head-center — authored once per kit in the calibration map). Strike-on-convergence: the player hits the drum when the ring meets the target dot.
- `lead_time` (a.k.a. "approach rate"): how far ahead the ring appears — the single biggest readability/difficulty knob. Default ~1.0–1.5 s; a `TuningKnobNode` can bind it.
- `R0`, `R_target`, ring thickness, colour-by-`target_zone` (palette-by-handle, per maximal-compatibility) are style params.
- **Velocity to emphasis:** louder hits (higher `velocity`) to thicker ring / brighter fill / a small "accent" pip, so dynamics are taught, not just timing.
- **Sustains / rolls / flams:** consecutive same-zone hits within a short window render as a **short track/slider** (osu-slider analogue) rather than N separate rings — readability mitigation for fast passages.

### 3b. Procedural generation is PRIMARY; scoring is SECONDARY
Per the spec, the system is *"mainly a procedural way to convert raw musical information ... and automatically generate the visual indications as instructions."* So the pipeline's spine is **timeline to circle_instructions to projected**, with **no player-input dependency**. Reactive scoring (did the strike land in the window?) is an *optional* branch: a `HitDetector` node compares an input event stream (from an e-kit `HardwarePortNode`, or a mic-onset detector, or the sim) against the timeline and emits accuracy — but the instruction generator neither knows nor cares whether a scorer is attached. This satisfies *"would not necessarily have to be reactive and accuracy based ... though the node capabilities should allow for the connection."*

### 3c. Practice slowdown + dynamic BPM knob (reuse, don't invent)
- **Time-scale:** a single `time_scale` real value multiplies the timeline's playback rate. `time_scale = 0.5` to half-speed practice; the *pattern is identical*, only spacing dilates. Because generation is a pure function of `(timeline, time_scale, lead_time)`, slowdown is exact and reversible.
- **Dynamic BPM knob = a `TuningKnobNode` (SPEC-286) bound to `time_scale`** on the projector's computer. Liam's "knob on the computer that the projector is connected to." Turning it live re-derives the shrink schedule continuously — no regeneration, just a scalar into the same function. The `temporal-dynamics-program` (SPEC-287) optionally makes "hold to scrub tempo further" feel natural, but v1 can bind a plain slider.
- **This closes the loop with SPEC-229's practice pedagogy:** the *starting* `time_scale`/target-BPM for a session is what the SPEC-229 next-BPM predictor recommends from the prior session's speed-ladder; the knob lets the player deviate live; the achieved BPM is written back as this session's ladder output. **The knob is the manual override on top of the evolving-practice recommendation.**

---

## 4. In-engine simulation design — node graph (reusing the projection substrate)

Everything is an **arrangement of already-loaded primitives wired as data** (the engine's design law, `PLAN.md`). No new *code paths* for the feature; a small number of new *primitive types* + one shared calibration node, then the feature is an arrangement.

### 4a. The scene (what's simulated)
- **`Model` (drum kit GLB)** — a drum-kit 3D model loaded at runtime via the existing `Model` primitive (`GLTFDocument`), each drum/cymbal a named sub-mesh so target zones resolve. (Sourced or generated; asset choice is a separate approval-gated step per the engine's approval gate.)
- **`Model` (projector rig)** — a simple projector body mounted **above/behind/beside** the kit, carrying a **`View`** (the engine's renderer-neutral glTF camera descriptor, `prim_view.gd`) that represents the projector's **frustum** (a projector is optically a camera run backwards). Position per spec: vertically above, offset behind or to the side of the player.
- **`Model` (witness camera)** — a simulated camera looking at the kit, feeding the calibration loop (section 4c). Also a `View`.
- **Room/lighting** — existing lighting nodes; ambient kept low so projected circles read (an in-sim analogue of the real-world "dim the room" constraint).

### 4b. The generation + projection pipeline (data flow)
```
MusicSource(midi|musicxml|osu)         <- file or live HardwarePortNode (e-kit)
   -> HitTimeline            (neutral {t, target_zone, velocity} stream; section 2d)
   -> CircleInstructionGen   (timeline x lead_time x time_scale -> per-frame ring set in kit-UV space; section 3)
   -> ProjectionMap          (kit-UV -> projector-image pixels via the calibration homography; section 4c)  -- SHARED NODE
   -> SimulatedProjector     (rasterize ring image into the projector View's frustum; cast onto kit meshes as a decal/light-cookie)
   -> [render]               (the GodotSceneRenderer delegate draws it on the physical kit surfaces)
```
Parallel/optional branches off the same `HitTimeline`:
```
HitTimeline -> AudioPlayer            (play the piece in sync; reuses Brief 14 AudioPlayerNode + the sync master-clock/offset pair)
HitTimeline -> HitDetector -> Scorer  (OPTIONAL osu-style accuracy; consumes input events; never gates generation)
```
Control inputs (wired real values):
```
TuningKnob(bpm/time_scale) -> CircleInstructionGen.time_scale     (the dynamic-BPM knob; section 3c)
TuningKnob(lead_time)      -> CircleInstructionGen.lead_time       (approach-rate / difficulty)
SPEC-229 predictor         -> CircleInstructionGen.time_scale seed (session-start target BPM)
```

### 4c. The shared projection-mapping + camera-feedback calibration node
This is the piece Liam explicitly requires be **the same nodes as the main arc**, and the piece the sibling charters left unbuilt.
- **`ProjectionMap`** holds a **homography / mesh-warp** from *content UV* (kit surface coordinates) to *projector image pixels*. It is the reusable projection-mapping primitive for the whole family (video projector here; galvo point-warp in the laser arc — same node, different output adapter).
- **`ProjectionCalibration` (camera-feedback loop)** — the closed loop that *finds and maintains* that homography, entirely in-sim:
  1. `SimulatedProjector` projects a **known structured pattern** (checkerboard / Gray-code / ArUco fiducials) onto the kit.
  2. The **witness `View` camera** renders what lands on the surfaces (the "camera" in "camera feedback").
  3. A **`Detect`** step finds the pattern's imaged corners; comparing *projected* vs *observed* corner correspondences **solves for the homography/warp** and writes it into `ProjectionMap`.
  4. **Feedback:** re-project, re-observe, measure residual reprojection error, iterate until under threshold — then hold. On drift (kit nudged, projector bumped) the residual rises and the loop re-runs. This is the "camera feedback loop to ensure calibration" verbatim.
- **Why sim-first is load-bearing:** in simulation the projector frustum, the kit meshes, and the witness camera are all *ground-truth known*, so we can (a) validate the calibration solver against the exact answer, (b) inject synthetic error (misalignment, lens distortion, latency) and prove the loop recovers, all before any real projector exists. Mirrors the laser arc's simulation-first discipline and the "simulate as realistically as possible" spec line.

### 4d. Primitive inventory (what's genuinely new vs reused)
| Node | New? | Notes |
|---|---|---|
| `Model`, `View`, `Transform`, `Group`, lighting, `GodotSceneRenderer` | **reuse** | already shipped primitives; kit + projector-rig + witness-cam + room are arrangements |
| `AudioPlayer`, sync master-clock + ms-offset | **reuse** | Brief 14 M3 + `projection/sync/` (shipped) |
| `TuningKnob` (+ `temporal-dynamics-program`) | **reuse (designed)** | SPEC-286/287 — the BPM + lead-time knobs |
| `MusicSource` / `HitTimeline` (MIDI, MusicXML, osu adapters) | **new** | thin parser primitives to neutral timeline; MIDI first |
| `CircleInstructionGen` | **new** | pure function `(timeline, lead_time, time_scale) -> ring set` |
| `ProjectionMap` | **new — SHARED** | the reusable projection-mapping primitive for the whole family |
| `ProjectionCalibration` | **new — SHARED** | the camera-feedback calibration loop; the family's missing piece |
| `SimulatedProjector` | **new — SHARED** | projector-as-inverse-camera output adapter (video); sibling of the laser galvo adapter |
| `HitDetector` / `Scorer` | **new — optional** | osu-style reactive branch; off the critical path |

Six new primitive *types* (three of them shared substrate the sibling arcs inherit); the drum-teaching *feature* is then an **arrangement** of these — exactly the engine's "new function = new arrangement, not new code" law.

---

## 5. Adversarial failure modes + mitigations

Enumerated in the "try to break it" posture (Wavelet `feedback-iterating-means-adversarial-break-finding`). These are the design's real risks; each has a mitigation carried into the phased plan.

1. **Timing / end-to-end latency.** Real projectors add 1–2 frames; the audio path, the input path, and the display path each add latency, so the *shown* circle can converge before the *heard* beat. Mitigation: ride the **already-built per-device ms-offset node** (the sync arc's whole reason to exist): calibrate a single visual-vs-audio offset once, applied to the whole timeline; wall-clock-anchored so it never drifts on reconnect. In-sim we can inject known latency and prove the offset cancels it.
2. **Calibration drift / projector-or-kit movement.** A bumped cymbal or nudged projector invalidates the homography; circles land off-target. Mitigation: the **`ProjectionCalibration` feedback loop** monitors reprojection residual continuously and re-solves on drift; a residual over threshold raises a visible "recalibrate" state rather than silently teaching wrong positions. Structured-light fiducials on a couple of static kit points give a cheap continuous check.
3. **Occlusion — sticks, hands, arms block the projection.** The player's own body sits between projector and drum, casting shadows exactly where the instruction needs to be. Mitigation: (a) **projector placement is a first-class design variable** (above/behind/side per spec) chosen in-sim to minimise self-occlusion for a seated player; (b) render the target **dot on the drum** as the ground truth and let the *ring* approach from an un-occluded direction; (c) simulate an articulated player/stick rig and *measure* shadowed area per placement to pick the mount — a concrete deliverable of the sim.
4. **Multi-limb simultaneous hits.** Kick+snare+hat together is normal drumming; N rings converging at one instant can visually collide/clutter. Mitigation: simultaneous hits are **first-class in the timeline** (section 2d). Spatial separation (different drums) usually de-clutters naturally; for same-region coincidences, distinct per-zone colours (palette-by-handle) + the accent-pip disambiguate. Stress-test with dense double-kick + blast-beat MIDI in the sim.
5. **BPM-change discontinuities + live-knob scrubbing.** Native tempo maps (section 2a) and the live BPM knob both change spacing mid-stream; a naive regen could stutter or drop an in-flight ring. Mitigation: `CircleInstructionGen` is a **pure function of `(timeline, time_scale, lead_time)` evaluated per frame**, not a stateful scheduler — a tempo change just re-evaluates future rings; in-flight rings finish their current shrink using their spawn-time schedule (no teleport). Tempo *ramps* interpolate. Test: yank the knob mid-fill and assert continuity.
6. **Fast passages exceed readable ring density.** 32nd-note rolls spawn more rings than the eye can parse. Mitigation: roll/flam **coalescing into short tracks/sliders** (section 3a); a readability cap that degrades gracefully (merge or thin) rather than flashing noise; and the whole point of **slowdown** — practise at `time_scale 0.5`, then ladder up (SPEC-229).
7. **Format edge cases.** Non-GM drum maps, MusicXML percussion without a MIDI-unpitched mapping, multi-track MIDI with drums off channel 10. Mitigation: a **mapping-resolution layer** with a GM default + a per-file override table; unknown notes route to a generic "unmapped" target and are logged (plug-and-play default no-op, per the substrate convention), never crash generation.
8. **Sim-to-real gap.** A perfect in-sim calibration may not transfer (real lens distortion, surface reflectance, ambient light). Mitigation: sim-first is explicitly a *design/validation* stage; the calibration loop is built to *measure and correct* from a real witness camera later, so the same node graph moves to hardware with the camera swapped from simulated to real. No hardware claims are made this stage.

---

## 6. Phased plan

Design/sim only; each phase is in-engine, node-based, commit-per-step. Rough P50 hours (calibrated ~0.37 h/session-unit; these are build estimates for a later implementation session, not this design pass).

- **Phase A — timeline spine (MIDI to neutral hit-timeline).** `MusicSource(midi)` + `HitTimeline` primitives; GM percussion map + tempo-map handling; unit-tested against a known drum MIDI. Emits the section-2d descriptor. (~4 h)
- **Phase B — circle-instruction generator + static scene.** `CircleInstructionGen` (pure fn); load a drum-kit GLB + author the per-zone target-point calibration map; render rings in kit-UV space with a *fixed* identity projection (no projector yet). Verify circles converge on the right zones at the right times, headless + one windowed demo. (~6 h)
- **Phase C — simulated projector + `ProjectionMap`.** Add the projector-rig `Model` + `View` (frustum), the `SimulatedProjector` output adapter (ring image to light-cookie/decal on kit meshes), and the `ProjectionMap` homography node (fed a hand-set warp first). Screenshot: rings land on physical drum surfaces from an overhead frustum. (~6 h)
- **Phase D — camera-feedback calibration loop (the shared deliverable).** `ProjectionCalibration`: structured-pattern projection to witness-`View` render to corner detect to solve homography to write `ProjectionMap` to residual feedback. Validate against ground-truth in-sim; inject synthetic misalignment and prove recovery. (~8 h)
- **Phase E — control knobs + practice loop.** Bind `TuningKnob` to `time_scale` (dynamic BPM) and to `lead_time`; wire the SPEC-229 predictor as the session-start `time_scale` seed and write the achieved BPM back to the speed-ladder. Slowdown + live-scrub tested for continuity (failure mode 5). (~4 h)
- **Phase F — adversarial hardening + optional reactive branch.** Occlusion measurement across projector placements (failure mode 3), dense multi-limb stress test (4), fast-passage coalescing (6); add the optional `HitDetector`/`Scorer` branch + a `.osu` import/export adapter to prove the isomorphism without making it required. (~6 h)
- **Phase G — MusicXML adapter.** Second `MusicSource` behind the same port (sheet-music path). (~4 h)

**Sequencing note for the queue:** Phases C–D produce the **shared `ProjectionMap` + `ProjectionCalibration` + `SimulatedProjector` nodes** that the modular-laser-projector and website-projection/audio-sync arcs both need. Doing this arc *first* is what "moves those arcs up" concretely — it builds their common substrate under a tractable, safe (no laser) test rig.

### Composition with the wider system
- **Sync arc:** projector = output adapter on the shared timeline; visual/audio latency = the existing ms-offset node.
- **Laser arc:** `SimulatedProjector` (video) and the galvo adapter are two output adapters behind the *same* `ProjectionMap`/universal-bridge seam; the calibration loop is shared.
- **Render/generation arc (GZ-RENDER):** rings/tracks are procedurally generated visuals — natural fit for the math/L-system generation substrate and continuous-LOD (a ring is a trivially truncatable recursive shape).
- **Evolver loop (GZ-3D / engine evolver):** difficulty/readability params (lead_time, ring style, coalescing thresholds) are exactly the kind of thing the supervised evolver + Aperture-as-fitness can tune later.
- **Visi-sonor (deferred):** the LED-keyboard/launchpad sibling is the same "music to lit/projected instruction" shape through the Brief 14 `HardwarePortNode`; this arc's timeline + instruction generator port to it directly.

---

## 7. Open questions for Liam (surfaced, not assumed)

Not blocking this design; flag for the build stage.
1. **Drum-kit model source** — generate parametrically (fits GZ-RENDER) vs. import a CC-licensed GLB? (Approval-gated asset choice per the engine's approval gate.)
2. **Default projector placement** — the sim will *measure* self-occlusion across above/behind/side; is there a preferred mount to optimise for first (e.g. overhead-behind for a seated player)?
3. **Real hardware later** — is a physical projector + witness webcam an intended eventual target (so the calibration node is built camera-swappable from day one), or is in-engine simulation the terminal deliverable?

These route to a brief Q/A at build time, not the Aperture (no decision cards on the Aperture).

---

*Provenance: prior arc found at `notes/website_planning_arc/feature_index_from_notion.md` (F102) + `deep_scan_results.md` (F062) + `Alethea-cc/nodes/spec_229_iterated_instrument_practice_contract.md` (SPEC-229) + `notes/website_planning_arc/architectural_extensions/music_and_tuning_knob.md` (TuningKnobNode SPEC-286/287, Brief 14 visi-sonor M6). External formats verified: [General MIDI](https://en.wikipedia.org/wiki/General_MIDI), [osu! .osu file format](https://osu.ppy.sh/wiki/en/Client/File_formats/osu_%28file_format%29). Sibling charters: `notes/projects/projection_audio_sync.md`, `notes/projects/modular_laser_projector.md`.*
