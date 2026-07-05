# Explore-a-scene — a walkable premade environment with grab-into-inventory

Aperture demo #17. **Liam verbatim (2026-07-05, item 3):** *"explore around a premade scene that
you find on the internet and load in … go into them and pick up and collect assets using the
sandbox grab feature and store them in my inventory … walk around a scene and run into solid
walls."*

## What it is

A first-person **explorer** you launch and walk around in:

- **WASD move · mouse look · Space jump · Shift sprint** — the in-house `FpsController`
  (`walkabout/fps_controller.gd`, a `CharacterBody3D`), reused as-is.
- **SOLID walls you run into.** The environment's walls are `StaticBody3D` + a box collider, so
  `move_and_slide` stops the player — you can't walk through them. A premade GLB scene's meshes are
  auto-wrapped in trimesh colliders so its geometry is solid too.
- **Pick up / collect with the sandbox GRAB feature.** Every scattered collectible is a walk-up
  pickable registered through `ExploreGrabAdapter`, a thin wrapper over the sandbox grab + inventory
  API (`walkabout/pickup_interactor.gd` + `walkabout/build_hud.gd`) — imported **read-only** from the
  peer lane. Walk up, press **E**, it's in your inventory (the bottom-left HUD). Same grab used
  everywhere else, not a re-implementation.
- **In-scene feedback.** Press **F1** to open a note box; what you type is appended to
  `Alethea-cc/state/sandbox/notes.jsonl` keyed to this scene id — the same feedback substrate as
  Aperture card feedback.

## Controls

| key | action |
|---|---|
| WASD | move |
| mouse | look |
| Space | jump |
| Shift | sprint |
| **E** | pick up the nearest collectible you're standing next to |
| Q · Tab | place / cycle inventory (from the grab feature) |
| **F1** | leave a note about this scene |
| Esc | release mouse · click to recapture |

## Launch

```
# windowed, walkable (from the Resonance-Evolution repo root):
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://examples/explore/explore_scene_demo.tscn
# headless smoke test:
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_explore_test.gd
```

It also opens from the **Aperture board** as a `scene_link` card (the same click-to-open path as the
other demos).

## The environment: premade scene, or a portable fallback

The demo prefers a **vendored CC0 premade scene** at `res://assets/scenes/<name>/` (set `SCENE_GLB`
in `explore_scene_demo.gd`). Until one is approved + imported, it builds a **procedural walled room**
(four solid primitive walls + two pillars) dressed with the already-imported Kenney/Quaternius CC0
nature props — so the explore + collide + collect loop is provable with **zero downloads**. When Liam
approves a scene, dropping its GLB in and setting `SCENE_GLB` is the only change; the mechanic is
unchanged.

### Candidate premade scenes (pushed to the Aperture for approve/deny)

Researched, license-verified, ranked best-first. Approve on the Aperture and the winner is imported +
wired as the `SCENE_GLB`:

| # | scene | license | format | demos |
|---|---|---|---|---|
| 1 | KayKit Dungeon Remastered | **CC0** | GLB | 200+ dungeon pieces — walls to run into, props to grab; matches the imported low-poly style |
| 2 | Godot 3D Platformer demo | MIT | .tscn native | turnkey playable — player + wall collision + collectible coins already wired |
| 3 | Kenney Mini Dungeon | **CC0** | GLB | small dungeon room; weapons/shields as collectibles; same Kenney family already imported |
| 4 | Quaternius Modular Dungeon (poly.pizza GLB mirror) | **CC0** | GLB | walls + pillars + furniture; same Quaternius family already imported |
| 5 | Sketchfab low-poly dungeon environment | CC-BY 4.0 (attribution) | GLB | a single pre-assembled explorable dungeon — corridors + rooms |

## The grab dependency (read-only import + adapter)

The grab + inventory feature is **owned by the sandbox lane**. This demo imports it read-only and
talks to it only through `explore_grab_adapter.gd`, so a later interface change there is a one-file
fix here. The methods the adapter depends on — `.set_player`, `.set_world_root`, `.register`, the
`inventory_changed` signal, `.held_total`, `.pickable_count`, and `BuildHud.bind` — are each exercised
by the peer's own headless tests, so they are stable contract.

> Note on the dispatch brief: the brief named `godot/runtime/sandbox_items.gd` as the grab API. In
> the current tree the grab + inventory live in `walkabout/pickup_interactor.gd` (+ `build_hud.gd`);
> the adapter targets those. If the sandbox lane later consolidates into `sandbox_items.gd`, only the
> two `preload(...)` paths at the top of `explore_grab_adapter.gd` change.

## Files (this lane owns all of these)

- `explore_scene_demo.gd` / `.tscn` — the explorer scene.
- `explore_grab_adapter.gd` — the read-only adapter over the sandbox grab/inventory API.
- `../../headless_explore_test.gd` — headless smoke test (explore + walls + grab + feedback).
- `assets/scenes/<name>/` — a vendored premade scene + its `LICENSE` + `PROVENANCE.md` (added on
  approval).

## Licensing

The FPS controller and the grab/inventory feature are in-house. The collectibles are the CC0
Kenney/Quaternius kits already vendored under `assets/vendor/`. Any premade scene added later carries
its own `LICENSE` + `PROVENANCE.md` (source URL, license, date) alongside the vendored GLB.
