# Walkabout — a navigable 3D demo scene

A first-person scene you can launch and **walk/look around** in. It is built entirely on the
existing renderer-neutral seam: it loads an arrangement of `Model` → `Transform` primitives
(DATA), evaluates it through `GraphRuntime` to renderer-neutral `scene_node` descriptors, and
hands those to `GodotSceneRenderer` (the only Godot-coupled delegate). The only thing it adds
over `main.gd` is a floor, lights, and a first-person controller so a human can move.

## Launch (windowed, walkable)

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://walkabout/walkabout.tscn
```

(run from the Resonance-Evolution repo root). **Controls:** WASD move · mouse look ·
Space jump · Shift sprint · **E pick up / use** the nearest object you're standing next to ·
Esc release mouse · click recapture.

## What you'll see

Every **modular CC0 kit** ingested by the pipeline, laid out as a buildable set on the floor at
real-world (1:1 meter) scale — each kit in its own zone. Out of the box that is the **Kenney
Nature Kit** (24 GLBs: beds, bridges, fences, …) and a **Quaternius Nature Kit** (10 GLBs: trees,
pines, rocks). Add more by running the ingest pipeline (below) and relaunching — the scene
auto-discovers `res://assets/ingested/kit_*.arrangement.json` (combined kits) and
`*.arrangement.json` (single assets).

## Pick up / interact — the proximity Context handler

Every laid-out object is **walk-up-pickable**. Walk up to an object and press **E** to pick it
up (it disappears from the world and is added to your inventory). The "you can only interact when
you're close enough" gate is the engine's **`proximity` Context handler** (`primitives/prim_context.gd`)
used as-is: each object owns a `Context(handler="proximity")` whose two implicit `vector` inputs
are fed the player position + the object position each frame, with the interaction range as the
Context's static `radius`. The scope is live (emits an "available" signal) only while the two
positions are within range. Spatial state is just an INPUT a handler reads — no bespoke gating
code. The interactor lives in `walkabout/pickup_interactor.gd`; headless test
`headless_pickup_test.gd`.

## Populate it with assets — the ingestion pipeline

```
# a MODULAR KIT from a Kenney-style ZIP (auto-picks the GLTF-format GLBs inside):
py Alethea-cc/tools/asset_ingest_gltf.py ingest-kit --kit-id kenney_nature --title "Kenney Nature Kit" \
  --license "CC0 1.0 Universal" --source-name "Kenney" \
  --zip-url "https://kenney.nl/.../kenney_nature-kit.zip" --limit 24
# a MODULAR KIT from Poly Pizza model permalinks (Quaternius CC0 set):
py Alethea-cc/tools/asset_ingest_gltf.py ingest-kit --kit-id quaternius_nature --title "Quaternius Nature Kit" \
  --license "CC0 1.0 Universal" --source-name "Quaternius" --polypizza 8oraKn9m0x 7PDBpElkQr ...
# a single asset (URL or local dir), unchanged from before:
py Alethea-cc/tools/asset_ingest_gltf.py ingest --src <dir-of-glb-or-gltf> --license "CC0 1.0 Universal"
py Alethea-cc/tools/asset_ingest_gltf.py ingest --url https://.../model.glb --license "CC0 1.0 Universal" --title "My Model"
```

Idempotent (keyed by content sha256), no LLM. Per **kit** it writes: each member GLB vendored
under `assets/vendor/<kit_id>/`, a per-member `scene_node` + `Model` arrangement, a **combined
`kit_<id>.arrangement.json`** (the whole buildable set), an append-only license-tracked Wavelet
**kit node** (`Alethea-cc/nodes/asset_kit_<id>.md`) grouping the members, plus a per-member
provenance node. Approved CC0 kit sources: **Kenney, Quaternius, Poly Pizza, ambientCG**.

### Scaling to more kits

Each `ingest-kit` call adds one independent kit zone with zero scene edits — the walkabout
auto-discovers `kit_*.arrangement.json`. To add the rest of a catalog, loop more `ingest-kit`
calls (one per pack): for Kenney, point `--zip-url` at each kit's stable ZIP; for Quaternius,
pass each pack's Poly Pizza permalink ids (CC0-only is enforced). Drop `--limit` to ingest a
full pack (the Kenney Nature Kit alone has 329 GLBs). FBX/OBJ-only packs are a deferred follow-up
(a converter step prepends to the same pipeline).

## Headless smoke tests

```
# scene assembles + renders + FPS controller is sound:
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_walkabout_test.gd
# proximity-gated pickup/interaction:
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_pickup_test.gd
```

## Licensing

The first-person controller (`fps_controller.gd`) is written in-house from scratch (no vendored
third-party controller) to keep the project's licensing posture uncomplicated. The demo assets
are CC0 1.0 Universal: the **Kenney Nature Kit** (kenney.nl, CC0) and a **Quaternius Nature Kit**
(via poly.pizza, CC0). Each asset + kit carries its own append-only, license-tracked provenance
node under `Alethea-cc/nodes/`.
