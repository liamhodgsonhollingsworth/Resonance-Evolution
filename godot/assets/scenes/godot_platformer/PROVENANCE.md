# Godot Engine — 3D Platformer demo stage (vendored, baked to GLB)

- **Slug:** `godot_platformer`
- **Source URL:** https://github.com/godotengine/godot-demo-projects/tree/master/3d/platformer
- **Author / creator:** Godot Engine contributors (godotengine/godot-demo-projects)
- **License:** MIT — see `LICENSE.txt` (the godot-demo-projects repository LICENSE.md).
- **Attribution required:** MIT requires the copyright + permission notice be retained; `LICENSE.txt` carries it. No in-scene credit is required, but the card names the source.
- **Download date:** 2026-07-05

## What is vendored — and the substitution note

The upstream 3D-platformer level is **not** distributed as a GLB. Its geometry lives in a Godot
`GridMap` backed by engine-native `.res`/`.tres` mesh + collision resources (`stage/grid_map.scn`,
`stage/meshes/*.res`). Importing those raw resources into this repo would drag in a web of
interdependent native binaries and is brittle across the editor/runtime class-cache boundary
(mistake #046).

So the stage was **baked to a single self-contained GLB** headlessly: the platformer project was
imported once with a fresh `.godot`, `stage.tscn` was instantiated, every used `GridMap` cell was
emitted as a `MeshInstance3D` at its world transform (2923 instances), and the result was written via
`GLTFDocument.write_to_filesystem` to `glb/stage.glb` (an 88 x 18 x 56 m level). This is a
**format substitution, not an asset substitution** — the geometry is the upstream MIT-licensed
platformer stage, unchanged, just serialized to GLB so the explorer can load it uniformly (and
auto-wrap its meshes in trimesh colliders so its walls/floor are solid). The bake script is preserved
in the arc's scratch history; re-running it against a fresh clone reproduces the GLB.
