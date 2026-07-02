# Creative-mode buildable sandbox — MVP + Fable-5 handoff

**Date:** 2026-07-02
**Branch:** `feat/creative-sandbox-mvp` (PR against `origin/main`)
**Liam's ask (verbatim, 2026-07-02):** "give this instance a basic minecraft style visual inventory with
the same layout and controls as minecraft creative mode. See if you can find some basic blocks and
placement systems to implement and start iterating right away, perhaps a voxel based system or something
else ... Include as well some basic 3D asset building blocks that are untextured but can be textured using
tools in the game engine."

## What was built (files + exact run command)

A runnable, hotloadable **Minecraft-creative-style buildable sandbox** in the RE Godot engine.

| File | What it is |
|---|---|
| `godot/examples/sandbox_creative.tscn` | The openable scene (stable path — a peer's desktop shortcut points here). |
| `godot/examples/sandbox_creative.gd` | The whole sandbox: free-fly cam, grid placement, MC inventory, material seam. |
| `godot/examples/sandbox_params.json` | The ONE file you edit to iterate the world (auto-written on first run). |
| `godot/headless_sandbox_test.gd` | Headless verification of the DATA core (18/18 PASS). |
| `godot/docs/sandbox_creative.png` | Proof render — the seeded build + hotbar + status line. |
| `godot/docs/sandbox_creative_inventory.png` | Proof render — the inventory panel open (tabs + block grid). |

**Open it (live, first-person creative build):**
```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --path godot res://examples/sandbox_creative.tscn
```
**Headless proof PNG then quit:** `... res://examples/sandbox_creative.tscn -- --shot`
(`-- --shot --inv` grabs the inventory-open proof instead.)
**Run the test:** `... --headless --path godot -s res://headless_sandbox_test.gd`

### Controls (MC creative parity)
- **W A S D** move (flattened to horizontal, relative to look), **Space / Shift** up/down, **Ctrl** sprint.
- **Mouse** look (pointer captured; **ESC** releases; click to recapture).
- **1–9** (or mouse wheel) select the hotbar slot.
- **Left-click** place the active block on the grid cell adjacent to the face you point at; **right-click** remove.
- **E** opens/closes the paged inventory (category tabs + block grid); click a block → active hotbar slot.

### How it works (the design, briefly)
- **World = DATA.** A plain `Dictionary` keyed by `Vector3i` grid coord → a block record
  `{type, shape, params, material, node}`. This is the simple, in-engine, universal "voxel-ish" store —
  **no external voxel library was ported** (per the approval gate). Each placed block is one `MeshInstance3D`.
- **Blocks = the engine's own primitive vocabulary.** The 14-entry palette maps onto the 13 primitive shapes
  the renderer already builds (`GodotSceneRenderer._primitive_mesh` is reused verbatim as a static call):
  box/sphere/cylinder/cone/torus/plane/capsule/prism/wedge/pyramid/tube + composite stairs/arch. Generic,
  **untextured**, original blocks — no Minecraft assets; only the UX convention is replicated.
- **Hotloadable/openable.** `_process` watches `sandbox_params.json` by mtime (the `live_demo`/`painterly_scene`
  pattern) — edit the seeded `blocks`, `fly_speed`, `grid_size`, `camera_start` and SAVE → the world re-applies
  live, no restart. `blocks` entries are `{cell:[x,y,z], block:"Cube"}` (a grid coord + a palette block name).

## Where the seams are

### THE live-texturing seam (the main Fable-5 attachment point)
Blocks start UNTEXTURED. Every block carries a per-block **`material` DATA slot** in its record, and ALL
material application funnels through ONE function:

```
func _apply_material(mi: MeshInstance3D, material_desc: Dictionary)   # in sandbox_creative.gd
```

Today `material` is just `{"albedo":[r,g,b]}` → a plain `StandardMaterial3D` (untextured). `_apply_material`
already reads (but is not yet fed) `albedo_texture`, `roughness`, `metallic`. **A future node-based
live-texturing system only has to write a richer `material` descriptor into the block record and call
`_apply_material` — the placement / removal / world / seed code never changes.** That is the clean seam;
it is the single choke point by design.

### Other seams
- **Palette is DATA** (`_build_palette()`): add a block = one row `{name, shape, params, material, category}`.
  New categories appear as inventory tabs automatically.
- **Params file is the world-as-DATA seam**: Claude Code / the coordinator can rewrite `sandbox_params.json`
  on disk to author a build; it hotloads. This is the hook for an "arrangement JSON" driven by the graph
  runtime later (today the sandbox owns its own store rather than routing placement through GraphRuntime —
  deliberately minimal per "do as little as possible / start iterating right away").

## OPEN Fable-5 pieces (not built here — deliberately deferred)

1. **Node-based LIVE-TEXTURING system** — the deep in-engine texturing tool that writes the per-block
   `material` descriptor (paint / procedural / node-graph → `albedo_texture`/`normal`/`roughness`). Attach at
   `_apply_material` + the block record's `material` slot. **This is the headline handoff piece.**
2. **Transparent, auto-arranged separate-windows harness** — the sandbox currently draws its HUD in a single
   window. The multi-window / transparent-overlay harness (2nd-monitor Aperture-style) is a separate arc.
3. **More blocks** — the palette is the 13 primitives; add slabs/stairs variants, half-blocks, curved parts,
   or wire the parts-catalog `params` sliders into the inventory for parametric blocks. Trivial (DATA rows).
4. **Placement polish** — face-accurate normal-based placement (currently a stepped grid ray), multi-block
   drag, undo/redo, save/load a build back out to `sandbox_params.json` from in-game.
5. **Optional external voxel-engine port (PENDING LIAM APPROVAL).** If a chunked greedy-meshed voxel engine
   (e.g. Zylann's `godot_voxel`) is ever wanted for large worlds / performance, that is a non-obvious
   dependency — do NOT port without Liam's explicit approval (a recommendation note was left for the
   coordinator to surface as an Aperture approval card). The current Dictionary store is fine for MVP-scale
   creative builds.

## Verification
- Headless test `headless_sandbox_test.gd`: **18/18 PASS** — palette completeness, all shapes build meshes,
  every block untextured, hotbar validity, grid round-trip, place/replace/remove write path, material seam
  present, default-params seed (40 blocks), hotload re-seed replaces the world.
- Render proofs: `docs/sandbox_creative.png` (build + hotbar + crosshair + status line),
  `docs/sandbox_creative_inventory.png` (inventory panel: tabs + block grid, MC-creative layout).
