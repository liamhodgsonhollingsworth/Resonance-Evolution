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
Space jump · Shift sprint · Esc release mouse · click recapture.

## What you'll see

Every asset ingested by the pipeline, laid out in a row on the floor at walk-up scale. Out of
the box that is the two CC0 Khronos sample models (Avocado, Corset). Add more by running the
ingest pipeline (below) and relaunching — the scene auto-discovers
`res://assets/ingested/*.arrangement.json`.

## Populate it with assets — the ingestion pipeline

```
py Alethea-cc/tools/asset_ingest_gltf.py ingest --src <dir-of-glb-or-gltf> --license "CC0 1.0 Universal"
py Alethea-cc/tools/asset_ingest_gltf.py ingest --url https://.../model.glb --license "CC0 1.0 Universal" --title "My Model"
```

Idempotent (keyed by content sha256), no LLM. Per asset it writes: the vendored GLB, a
`scene_node` descriptor + a drop-in `Model` arrangement under `assets/ingested/`, and an
append-only license-tracked Wavelet node under `Alethea-cc/nodes/asset_<id>.md`.

## Headless smoke test

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_walkabout_test.gd
```

## Licensing

The first-person controller (`fps_controller.gd`) is written in-house from scratch (no vendored
third-party controller) to keep the project's licensing posture uncomplicated. The demo assets
are CC0 1.0 Universal (Khronos glTF Sample Assets).
