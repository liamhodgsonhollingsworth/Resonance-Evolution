# Explore-a-scene — walk any of 5 premade dungeons, run into walls, grab props

Aperture demo #17. **Liam verbatim (2026-07-05, item 3):** *"explore around a premade scene that
you find on the internet and load in … go into them and pick up and collect assets using the
sandbox grab feature and store them in my inventory … walk around a scene and run into solid
walls."* — and (2026-07-05) Liam **approved all 5 candidate scenes**, so they are now vendored and
explorable.

## What it is

A first-person **explorer** you launch and walk around in, now over **any of 5 vendored scenes**:

- **WASD move · mouse look · Space jump · Shift sprint** — the in-house `FpsController`
  (`walkabout/fps_controller.gd`, a `CharacterBody3D`), reused as-is.
- **SOLID walls you run into.** A pre-assembled scene's meshes are auto-wrapped in trimesh colliders;
  a kit-assembled room has solid boundary walls + solid structure pieces. `move_and_slide` stops the
  player — you can't walk through.
- **Pick up / collect with the sandbox GRAB feature.** Every scattered collectible is a walk-up
  pickable registered through `ExploreGrabAdapter`, a thin read-only wrapper over the sandbox grab +
  inventory API (`walkabout/pickup_interactor.gd` + `walkabout/build_hud.gd`). Walk up, press **E**,
  it's in your inventory (bottom-left HUD).
- **In-scene feedback.** Press **F1** to open a note box; the text is appended to
  `Alethea-cc/state/sandbox/notes.jsonl` keyed to the scene — the same substrate as Aperture feedback.

## The 5 scenes

All approved 2026-07-05; each is vendored under `assets/scenes/<slug>/` with a `LICENSE`/`ATTRIBUTION`
+ `PROVENANCE.md`.

| slug | scene | license | how it's built |
|---|---|---|---|
| `kaykit_dungeon` | KayKit Dungeon Remastered | CC0 | kit assembled into a walled dungeon room; props are grab collectibles |
| `godot_platformer` | Godot 3D Platformer level | MIT | the platformer stage baked to a single GLB, loaded + auto-collided |
| `kenney_mini_dungeon` | Kenney Mini Dungeon | CC0 | kit assembled into a walled room + props |
| `quaternius_dungeon` | Quaternius Modular Dungeon | CC0 | kit assembled into a walled room + props |
| `sketchfab_dungeon` | Sketchfab dungeon environment | CC-BY 4.0 | login-gated on Sketchfab (not vendored); uses the fallback room with the CC-BY credit surfaced in-scene |

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
# the SELECTOR (choose one of the 5 scenes):
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://examples/explore/explore_scene_demo.tscn
# a specific scene directly:
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://examples/explore/explore_scene_demo.tscn -- --scene-params={"scene":"kaykit_dungeon"}
# headless smoke test:
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_explore_test.gd
```

It also opens from the **Aperture board** as a `scene_link` card (one card per scene, each passing its
slug in the link `params`), the same click-to-open path as the other demos.

## The scene registry (data-driven)

`explore_scenes.gd` maps each slug to a config: `kind` (`glb` pre-assembled | `assembled` kit),
`license`, `attribution`, and the vendored glb dir. `explore_scene_demo.gd` reads the requested slug
from `--scene-params={"scene":…}`, builds that scene, and falls back to a procedural walled room if a
scene's assets are missing — so the demo never hard-fails. **Adding a 6th scene is one dictionary
entry + a vendored asset dir; the explorer mechanic is unchanged.**

## The grab dependency (read-only import + adapter)

The grab + inventory feature is **owned by the sandbox lane**. This demo imports it read-only and
talks to it only through `explore_grab_adapter.gd`, so a later interface change there is a one-file
fix here.

## Files (this lane owns all of these)

- `explore_scene_demo.gd` / `.tscn` — the explorer scene + scene selector.
- `explore_scenes.gd` — the 5-scene registry (data only).
- `explore_grab_adapter.gd` — the read-only adapter over the sandbox grab/inventory API.
- `../../headless_explore_test.gd` — headless smoke test (selector + explore + walls + grab + feedback
  + every-scene-solid + provenance-present).
- `../../assets/scenes/<slug>/` — the vendored scenes + their `LICENSE`/`ATTRIBUTION` + `PROVENANCE.md`.

## Licensing

The FPS controller and the grab/inventory feature are in-house. Vendored scenes carry their own
license: KayKit / Kenney / Quaternius are CC0 (no attribution required); the Godot platformer stage is
MIT (`LICENSE.txt` retained); the Sketchfab environment is CC-BY 4.0 (attribution recorded and
surfaced in-scene; the file itself is login-gated and not vendored). Every scene dir has a
`PROVENANCE.md` with source URL, author, license, and download date.
