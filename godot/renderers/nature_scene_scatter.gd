class_name NatureSceneScatter
extends RefCounted
## Closes the loop: TerrainGenerator's Constraint Field -> ScatterComposer's Poisson-disk sampler
## (REUSE, zero changes to that file — the reuse/portability law + "new nodes + connections, never
## edit a primitive") -> LSystem plant instances (REUSE, zero changes). This is the plan's own §3
## architecture diagram (notes/planning/evolving_scene_generator_plan_2026_07_08.md, Wavelet PR
## #815) realized end to end, thinly:
##
##   Terrain(Generator:heightfield) --emits--> ground mesh + Constraint(Field: slope/height/
##                                              moisture/biome)
##                                                 |
##   Scatter(Composer:poisson) <--reads-- Constraint
##      places CALL@Plant(Generator:lsystem)
##
## Reuse map (this file adds NOTHING new to any of these — a thin wiring layer, matching
## renderers/plant_scatter.gd's own precedent for the underground-halls scene):
##   - ScatterComposer.sample() (renderers/scatter_composer.gd) — the field-agnostic Poisson-disk
##     sampler; this module supplies ONLY a `field_fn`/`to_transform` pair, never edits the sampler.
##   - LSystem.expand()/interpret()/to_scene_node() (renderers/lsystem.gd) — plant geometry, the
##     SAME renderer-neutral scene_node shape every other primitive already emits.
##   - TerrainGenerator.sample_bilinear() (renderers/terrain_generator.gd, this plan's own P0 item
##     0.1) — reads height + constraint layers at any world XZ position.
##
## THE CC0/rock ASSET SEAM (matching plant_scatter.gd's own documented convention exactly): a
## `call_target` starting with `"lsystem:"` resolves to a built-in procedural plant and this module
## builds its `scene_node` itself. Any OTHER handle (e.g. a future `"sdf:boulder"` rock CALL —
## SDF.gd's own docstring is explicit that it "STOPS at the distance function + edit-list contract"
## and a sculpt/voxel evaluation pass is separate, visuals-lane work, not built here) passes through
## UNRESOLVED with `scene_node = null` — a later pass wires the actual geometry, exactly matching
## ScatterComposer.Placement's own contract ("this module does not resolve or invoke it").
##
## WHERE PLANTS GO: `field_fn` reads the terrain's own constraint_field (slope/moisture/biome_id at
## the candidate's world position) and rejects candidates that are too steep (`max_slope`), too dry
## (`min_moisture`), or in a biome outside `allowed_biomes` — so a forest naturally thins out on
## cliffs and skips water/alpine by default, without any new field machinery (the SAME [0..1]
## numbers TerrainGenerator already produces). Placement height comes from
## `TerrainGenerator.sample_bilinear()` on the heightfield itself, so every plant roots exactly on
## the ground surface. Growth direction is WORLD-UP (plants don't lean with local terrain slope —
## the same real-vegetation convention plant_scatter.gd's own docstring documents), with a small
## random yaw per instance for visual variety.

const DEFAULT_TREE_ASSET_HANDLE := "lsystem:tree"
const LSYSTEM_PREFIX := "lsystem:"
const DEFAULT_DENSITY := 0.6
const DEFAULT_SEED := 0
const DEFAULT_MIN_DIST := 1.2          # world units between accepted placements
const DEFAULT_MAX_SLOPE := 0.55        # reject candidates on slope steeper than this [0..1]
const DEFAULT_MIN_MOISTURE := 0.0      # reject candidates drier than this [0..1] (0 = no floor)
const DEFAULT_SIZE_MIN := 0.7
const DEFAULT_SIZE_MAX := 1.5
const DEFAULT_MAX_POINTS := 4000
const DEFAULT_K := 30
# biome_id is stored on the constraint field as index/(BIOME_COUNT-1); default excludes water
# (0) and alpine (4) — plants root in grassland/forest/rock-edge, not underwater or above the
# treeline, matching the terrain's own 5-biome classifier (TerrainGenerator._classify_biome).
const DEFAULT_ALLOWED_BIOMES: Array[int] = [
	TerrainGenerator.BIOME_GRASSLAND,
	TerrainGenerator.BIOME_FOREST,
	TerrainGenerator.BIOME_ROCK,
]

## A small deterministic built-in species library (REUSE, LSystem is the only geometry engine
## called — same "F/+/-/[/]" ABOP turtle alphabet LSystem.gd's own docstring documents). Not
## exhaustive by design (no-auto-generalization: two species is enough to prove the loop closes
## for real; a fuller library is an explicit follow-up, not invented here). Branch factor matters:
## an X-rule with 2-way branching ("+X][-X") at depth 4 expands to ~64 F-segments per plant (the
## SAME known-reasonable shape plant_scatter.gd's own "default"/"shrub" species already ship and
## were verified at scatter scale); an earlier 4-way-branching draft ("+X][-X][&X][^X") exploded to
## ~240 segments/plant (F-count roughly quadruples per depth instead of doubling) and rendered as
## an unreadable cylinder thicket in this module's own proof render — caught and fixed before
## commit, kept as the documented reason these two specific rule shapes were chosen.
const LSYSTEM_SPECIES := {
	"tree": {
		"axiom": "X", "depth": 4,
		"rules": {"X": "F[+X][-X]FX", "F": "FF"},
		"turtle": {"step": 0.32, "angle_deg": 24.0, "radius": 0.05, "radius_decay": 0.72, "step_decay": 0.92},
	},
	"shrub": {
		"axiom": "F", "depth": 3,
		"rules": {"F": [[0.5, "F[+F]F[-F]F"], [0.5, "F[+F][-F]F"]]},
		"turtle": {"step": 0.28, "angle_deg": 30.0, "radius": 0.045, "radius_decay": 0.68, "step_decay": 0.94},
	},
}
const LSYSTEM_SPECIES_ORDER := ["tree", "shrub"]


## Scatter plants across a `terrain_result` (TerrainGenerator.build()'s own output — heightfield +
## width + depth + cell_size + constraint_field). Returns an Array[Dictionary] of placements:
## {"transform": Transform3D, "call_target": String, "scene_node": Dictionary|null, "seed": int,
## "biome_id": int, "scale": float} — pure DATA, the same "return ready components" shape
## plant_scatter.gd's own placements already use.
static func scatter(terrain_result: Dictionary, tunables: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var width: int = int(terrain_result.get("width", 0))
	var depth: int = int(terrain_result.get("depth", 0))
	if width < 2 or depth < 2:
		return out
	var heightfield: PackedFloat32Array = terrain_result.get("heightfield", PackedFloat32Array())
	var cf: Dictionary = terrain_result.get("constraint_field", {})
	var slope: PackedFloat32Array = cf.get("slope", PackedFloat32Array())
	var moisture: PackedFloat32Array = cf.get("moisture", PackedFloat32Array())
	var biome_id: PackedFloat32Array = cf.get("biome_id", PackedFloat32Array())
	if heightfield.size() != width * depth or slope.size() != width * depth:
		return out
	var cell_size: float = maxf(0.0001, float(terrain_result.get("cell_size", TerrainGenerator.DEFAULT_CELL_SIZE)))

	var density: float = clampf(float(tunables.get("density", DEFAULT_DENSITY)), 0.0, 1.0)
	if density <= 0.0:
		return out
	var handle: String = String(tunables.get("tree_asset_handle", DEFAULT_TREE_ASSET_HANDLE))
	var seed: int = int(tunables.get("seed", DEFAULT_SEED))
	var min_dist: float = maxf(0.01, float(tunables.get("min_dist", DEFAULT_MIN_DIST)))
	var max_slope: float = clampf(float(tunables.get("max_slope", DEFAULT_MAX_SLOPE)), 0.0, 1.0)
	var min_moisture: float = clampf(float(tunables.get("min_moisture", DEFAULT_MIN_MOISTURE)), 0.0, 1.0)
	var allowed_biomes: Array = tunables.get("allowed_biomes", DEFAULT_ALLOWED_BIOMES)
	var max_points: int = maxi(1, int(tunables.get("max_points", DEFAULT_MAX_POINTS)))
	var k: int = maxi(1, int(tunables.get("k", DEFAULT_K)))

	var domain_min := Vector2(0.0, 0.0)
	var domain_max := Vector2(float(width - 1) * cell_size, float(depth - 1) * cell_size)

	var field_fn := func(p: Vector2) -> float:
		var gx: float = p.x / cell_size
		var gy: float = p.y / cell_size
		var s: float = TerrainGenerator.sample_bilinear(slope, width, depth, gx, gy)
		if s > max_slope:
			return 0.0
		var m: float = TerrainGenerator.sample_bilinear(moisture, width, depth, gx, gy)
		if m < min_moisture:
			return 0.0
		if not biome_id.is_empty():
			var b_norm: float = TerrainGenerator.sample_bilinear(biome_id, width, depth, gx, gy)
			var b: int = int(round(b_norm * float(TerrainGenerator.BIOME_COUNT - 1)))
			if not (b in allowed_biomes):
				return 0.0
		# Density thins smoothly with slope (steeper -> sparser, never a hard cliff of acceptance).
		return clampf(density * (1.0 - s), 0.0, 1.0)

	var to_transform := func(p: Vector2, rng: RandomNumberGenerator) -> Transform3D:
		var gx: float = p.x / cell_size
		var gy: float = p.y / cell_size
		var h: float = TerrainGenerator.sample_bilinear(heightfield, width, depth, gx, gy)
		var yaw := rng.randf_range(0.0, TAU)
		return Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, h, p.y))

	var placements := ScatterComposer.sample(domain_min, domain_max, min_dist, field_fn, seed,
		handle, to_transform, k, max_points)

	for p in placements:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(p.seed) ^ int(hash(p.point))
		var scale := _random_scale(rng, tunables)
		var scene_node = _build_scene_node(handle, rng, scale)
		var gx: float = p.point.x / cell_size
		var gy: float = p.point.y / cell_size
		var b: int = TerrainGenerator.BIOME_GRASSLAND
		if not biome_id.is_empty():
			var b_norm: float = TerrainGenerator.sample_bilinear(biome_id, width, depth, gx, gy)
			b = int(round(b_norm * float(TerrainGenerator.BIOME_COUNT - 1)))
		out.append({
			"transform": p.transform,
			"call_target": handle,
			"scene_node": scene_node,
			"seed": int(p.seed),
			"biome_id": b,
			"scale": scale,
		})
	return out


static func _random_scale(rng: RandomNumberGenerator, tunables: Dictionary) -> float:
	var lo: float = maxf(0.01, float(tunables.get("size_min", DEFAULT_SIZE_MIN)))
	var hi: float = maxf(lo, float(tunables.get("size_max", DEFAULT_SIZE_MAX)))
	return rng.randf_range(lo, hi)

## Build one plant's renderer-neutral `scene_node` via LSystem, or return null when `handle` is NOT
## an `"lsystem:"` handle (the CC0/rock asset seam — a later pass resolves `call_target` into real
## geometry; this module never guesses at an asset/SDF-rock it hasn't built).
static func _build_scene_node(handle: String, rng: RandomNumberGenerator, scale: float) -> Variant:
	if not handle.begins_with(LSYSTEM_PREFIX):
		return null
	var species_name := handle.substr(LSYSTEM_PREFIX.length())
	var species: Dictionary = LSYSTEM_SPECIES.get(species_name, {})
	if species.is_empty():
		# Unknown species name after the "lsystem:" prefix -- seeded roll across the known library
		# rather than a hard failure (same fallback plant_scatter.gd's own resolver uses).
		species = LSYSTEM_SPECIES[LSYSTEM_SPECIES_ORDER[rng.randi_range(0, LSYSTEM_SPECIES_ORDER.size() - 1)]]

	var plant_seed := rng.randi()
	var symbols := LSystem.expand(String(species.get("axiom", "X")), species.get("rules", {}),
		int(species.get("depth", 4)), plant_seed)
	var turtle: Dictionary = (species.get("turtle", {}) as Dictionary).duplicate()
	turtle["step"] = float(turtle.get("step", 0.3)) * scale
	turtle["radius"] = float(turtle.get("radius", 0.05)) * scale
	var segments := LSystem.interpret(symbols, turtle)
	return LSystem.to_scene_node(segments, "plant_%s" % species_name)
