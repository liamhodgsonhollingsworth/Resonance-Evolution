# Gallery — a turntable showcase scene (the second sample scene)

A **second sample scene** built on the exact same renderer-neutral seam as `walkabout/`. Its only
job is to prove the seam is **scene-agnostic**: both scenes run the identical
`load_arrangement → evaluate → render` dance through `GraphRuntime` + `GodotSceneRenderer`; only the
**layout** they emit differs. No engine or foundation code is touched — a scene is just a different
arrangement of `Model → Transform` DATA plus a camera.

Where `walkabout` lays the ingested CC0 assets out as a **walkable grid on a floor**, the gallery
arranges them as a **circular turntable**: every ingested asset is placed evenly around a ring facing
a central camera, and the whole ring slowly **auto-orbits** so each asset rotates into view.

## Launch (windowed, auto-orbiting showcase)

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://gallery/gallery.tscn
```

(run from the Resonance-Evolution repo root). The camera is fixed at the center; the ring of assets
orbits past it. There are no controls — it is a passive showcase (contrast walkabout's WASD/look/pick-up).

## What you'll see

Every ingested asset (de-duplicated by GLB path across single + kit-combined arrangements) ringed
around the center at 1:1 meter scale, slowly turning. Out of the box that is the Kenney Nature Kit +
Quaternius Nature Kit ingested for `walkabout`. Add more by running the ingest pipeline (see
`walkabout/README.md` → *Populate it with assets*) and relaunching — the gallery auto-discovers the
same `assets/ingested/*.arrangement.json` files.

## Headless smoke test

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_gallery_test.gd
```

Asserts the gallery assembles a non-empty arrangement, evaluates to `scene_node` DATA, renders a live
node per ringed asset, the layout is genuinely circular (every asset at ~`RING_RADIUS` from center,
positions spread not stacked), and the scene instances cleanly (center camera + orbiting ring pivot).

## CI one-shot capture

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://gallery/gallery.tscn -- --shot
```

Renders ~15 frames, writes `res://live/gallery_shot.png`, and quits — the windowed proof that the
scene renders (the `live/` dir is gitignored, so the shot is a dev artifact, never committed).

## Why a second scene

The walkabout was the first concrete scene over the `scene_node` seam. The gallery is the increment
that demonstrates the seam carries **any number of scenes**, each a pure data layout — the same way a
Context handler demonstrates the runtime carries any number of communication disciplines. Adding a
third scene is the same move: a new layout over the same `Model → Transform → render` pipeline, zero
engine edits.
