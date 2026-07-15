class_name ProceduralRockTexture
extends RefCounted
## ProceduralRockTexture -- node 3 ("Texture / material tier") of
## notes/planning/underground_halls_plan_2026_07_14.md §4, Wave 3 item 3.2 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-2e1202ca). Noise-driven wall
## material for the underground-halls ring scaffold, EXPLICITLY folded into the painterly
## texture-field methods per Liam's own instruction (underground_halls_plan §2, 18:15:57 -- "the
## texture reads as abstract, not photoreal rock").
##
## REUSE, no primitive-internals edit: this is a thin FOLD-IN wiring layer over
## renderers/texture_synth_cpu.gd (TextureSynthCpu) -- the plan's own named reuse target (plan
## §3's substrate-inventory row: "Procedural rock/noise texture ... fold into
## library/procedures/painterly_texture_field"). TextureSynthCpu already IS that texture-field
## generator (deterministic hashed noise / fbm / voronoi ops, palette-by-handle, domain warping --
## see its own header). `ProceduralRockTexture` adds nothing to TextureSynthCpu's OP_TYPES registry;
## it only composes a FIXED, hand-tuned op list (layered fbm base-relief + voronoi cell-wall ridges,
## warped) that reads as rock, and wraps the synthesized Image into a Godot StandardMaterial3D.
##
## In (plan): `wall_surface_uv` (RingScaffoldGenerator.wall_surface_uv(), used ONLY to size the
## world-scale tiling -- the actual per-vertex UV coordinates a mesh samples this material through
## already live on RingScaffoldGenerator.build_wedge_mesh()'s own vertices, PR #190; this node never
## needs to re-derive them), `detail_field` (LOD budget in -- wired here as an optional `detail`
## [0,1] scalar that scales the synthesized tile's resolution, cheap textures far away).
## Out (plan): `wall_material_descriptor` -- here, a ready-to-use `StandardMaterial3D`.
##
## Tunables (plan §4 node 3, the EXACT three named -- no more, per no-auto-generalization):
##   noise_seed    (int)   -- drives every op's seed, so the whole tile reshuffles deterministically.
##   noise_scale   (float) -- shared frequency multiplier across every layered op (bigger = finer
##                            detail per tile).
##   palette_handle(String)-- one of TextureSynthCpu.PALETTES' handles (into `style_nodes`, per the
##                            plan's own wording -- TextureSynthCpu's palette registry IS that
##                            handle-resolution point, the Wavelet one-relinkable-palette convention).

const DEFAULT_NOISE_SEED := 4177
const DEFAULT_NOISE_SCALE := 5.0
const DEFAULT_PALETTE := "slate"          # rock-toned; "sandstone"/"earth" also fit, swap via tunable

# Documented, non-headline implementation decisions (same pattern cavity_carver.gd / ring_scaffold.gd
# use beyond their own plan-named tunables -- overridable via `tunables`, never silently hardcoded).
const DEFAULT_TILE_PX := 256              # synthesized Image resolution at detail = 1.0
const MIN_TILE_PX := 64                   # floor for detail = 0.0 (far-LOD cheap tiles)
const DEFAULT_WORLD_UNITS_PER_TILE := 3.0 # how many world-units (mesh UV's u is world arc-length,
                                           # per ring_scaffold.gd) one synthesized tile spans -- this
                                           # is what actually controls "does the rock look zoomed in
                                           # or tiny", independent of `noise_scale` (the FIELD's own
                                           # internal frequency).
const DEFAULT_ROUGHNESS := 0.9            # rock reads matte/rough, not glossy -- the deliberate
                                           # contrast against ReflectiveFloorMaterial's low roughness.
const CROSS_SECTION_TILE_REPEATS := 3.0   # v (cross-section angle) is already normalized [0,1) per
                                           # ring_scaffold.gd's UV convention (one full loop around
                                           # the ellipse) -- unlike u this is NOT in world units, so
                                           # it gets its own small fixed repeat count rather than
                                           # world_units_per_tile.


## Compose the fixed "rock" op list: an `fbm` base-relief coat (broad tonal variation) with a
## `voronoi` cell-wall-ridge layer multiplied over it (the cracked/faceted rock-face read) plus a
## fine `value_noise` grain pass -- all warped, all seeded off `noise_seed`, all scaled by
## `noise_scale`. Every op is an EXISTING TextureSynthCpu.OP_TYPES entry; nothing new is registered.
static func build_texture_ops(tunables: Dictionary = {}) -> Dictionary:
	var seed_value: int = int(tunables.get("noise_seed", DEFAULT_NOISE_SEED))
	var scale: float = maxf(0.1, float(tunables.get("noise_scale", DEFAULT_NOISE_SCALE)))
	var palette: String = String(tunables.get("palette_handle", DEFAULT_PALETTE))
	if not TextureSynthCpu.PALETTES.has(palette):
		push_warning("ProceduralRockTexture: unknown palette_handle '%s', falling back to '%s'" % [palette, DEFAULT_PALETTE])
		palette = DEFAULT_PALETTE

	return {
		"texture_ops": [
			# Base relief: broad, low-frequency tonal variation -- the rock face's overall shading.
			{ "type": "fbm", "params": {
				"scale": scale * 0.6, "octaves": 4, "lacunarity": 2.0, "gain": 0.5,
				"seed": seed_value, "palette": palette, "blend": "replace", "opacity": 1.0,
				"warp_amp": 0.12, "warp_scale": scale * 0.4, "warp_seed": seed_value + 11,
			} },
			# Cell-wall ridges: voronoi F2-F1 mode reads as cracked/faceted rock-face fracture lines,
			# multiplied over the base coat so ridges darken rather than replace the base tone.
			{ "type": "voronoi", "params": {
				"cells": maxi(2, int(round(scale))), "mode": 1, "seed": seed_value + 101,
				"palette": palette, "blend": "multiply", "opacity": 0.6,
				"warp_amp": 0.08, "warp_scale": scale * 0.5, "warp_seed": seed_value + 23,
			} },
			# Fine grain: a small high-frequency value-noise pass, softly mixed in, for surface detail
			# at close range (this is the layer `detail`/tile-resolution scaling most affects).
			{ "type": "value_noise", "params": {
				"scale": scale * 2.2, "seed": seed_value + 211,
				"palette": palette, "blend": "mix", "opacity": 0.25,
			} },
		],
	}


## Synthesize the rock tile as a raw Image (deterministic, byte-identical for the same tunables --
## inherits TextureSynthCpu.synthesize's own reproducibility invariant). `detail` in [0,1] scales
## the tile resolution (LOD budget wiring, node 3's `detail_field` input): 1.0 = DEFAULT_TILE_PX,
## 0.0 = MIN_TILE_PX. A cheap, honest way to spend less synthesis/GPU-upload cost on far wedges
## without touching TextureSynthCpu itself.
static func synthesize(tunables: Dictionary = {}, detail: float = 1.0) -> Image:
	detail = clampf(detail, 0.0, 1.0)
	var px := int(round(lerpf(float(MIN_TILE_PX), float(DEFAULT_TILE_PX), detail)))
	return TextureSynthCpu.synthesize(build_texture_ops(tunables), px, px)


## Build the ready-to-use StandardMaterial3D ("wall_material_descriptor", plan's Out port).
## `wall_uv` (optional): a RingScaffoldGenerator.wall_surface_uv() descriptor (node 3's plan-named
## `wall_surface_uv` input) -- accepted for interface parity with that port and so a caller with
## real ring geometry on hand can pass it straight through; today's tiling math (below) only needs
## `tile_units`/`CROSS_SECTION_TILE_REPEATS`, both already independent of any specific ring's
## radius (u is world-unit arc length regardless of which ring it came from -- see ring_scaffold.gd's
## own UV convention), so `wall_uv` is currently unused beyond that documentation role. Kept as a
## real parameter (not silently dropped) so a future per-ring override (e.g. varying tile density by
## ring radius) is a pure addition here, never a signature change.
static func build_material(tunables: Dictionary = {}, wall_uv: Dictionary = {}, detail: float = 1.0) -> StandardMaterial3D:
	var tile_units: float = maxf(0.05, float(tunables.get("world_units_per_tile", DEFAULT_WORLD_UNITS_PER_TILE)))
	var image := synthesize(tunables, detail)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.roughness = clampf(float(tunables.get("roughness", DEFAULT_ROUGHNESS)), 0.0, 1.0)
	mat.metallic = 0.0
	mat.uv1_triplanar = false
	# u (mesh UV.x) is world-unit arc length -> divide by tile_units for a sensible repeat count.
	# v (mesh UV.y) is already normalized [0,1) -> a small fixed repeat count, not a world-unit ratio.
	mat.uv1_scale = Vector3(1.0 / tile_units, CROSS_SECTION_TILE_REPEATS, 1.0)
	return mat
