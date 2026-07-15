class_name PlantScatterInCavities
extends RefCounted
## PlantScatterInCavities -- node 12 ("Population tier") of
## notes/planning/underground_halls_plan_2026_07_14.md, Wave 4 item 4.3 (B) of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-6c2dc2f2). REUSE + thin wiring, 3h:
## "In: cavity_instances (from node 8), cavity_cutaway_field. Out: plant_placements. Tunables:
## tree_asset_handle (closest-match default per Liam's instruction), density."
##
## REUSE (no changes to any of these files -- reuse/portability law):
##   - ScatterComposer.sample() (renderers/scatter_composer.gd, Wave 1 item 1.1) -- runs a genuine
##     density-weighted Poisson-disk pass PER CAVITY over that cavity's own local footprint disk, the
##     same "unroll to a small 2D domain, sample, map back" shape cavity_carver.gd and
##     amber_light_cube_scatterer.gd's wall tier already use.
##   - NonOverlappingCavityCarver.carve()'s own `cavity_instances` / `cavity_cutaway_field` output
##     (renderers/cavity_carver.gd, Wave 3 item 3.1) -- consumed as-is, never re-derived.
##   - LSystem.expand()/interpret()/to_scene_node() (renderers/lsystem.gd) -- the plan's own node-12
##     REUSE line ("Tree/plant generator: renderers/lsystem.gd + primitives/prim_lsystem.gd") --
##     produces each plant's procedural geometry as the SAME renderer-neutral scene_node descriptor
##     shape every other primitive already emits.
##
## CC0 ASSET SEAM (swappable socket, not built here per this item's own instruction -- "the CC0 asset
## seam stays a swappable socket, assets not yet fetched -- leave the seam, use L-system trees now"):
## `tree_asset_handle` selects between the two paths. The default handle (`DEFAULT_TREE_ASSET_HANDLE`,
## "lsystem:default") -- or any handle starting with the `"lsystem:"` prefix -- resolves to a built-in
## L-system species (LSYSTEM_SPECIES below) and this module builds the plant's `scene_node` itself. Any
## OTHER handle (e.g. a future `"asset:potted_fern"` CC0 pick-list handle, per the crosscutting plan's
## AssetPickList convention) is passed through UNRESOLVED as `call_target` with `scene_node = null` --
## a later asset-ingestion pass wires the actual mesh, exactly matching ScatterComposer.Placement's own
## `call_target` contract ("this module does not resolve or invoke it").
##
## WHERE PLANTS GO -- floor-level cavities, growing world-up regardless of wall tilt: `cavity_
## cutaway_field` (the `through == true` subset NonOverlappingCavityCarver flags as street-level/
## floor-cutoff -- the SAME set node 10 `DirtFloorInfill` will floor with dirt) is the PREFERRED
## candidate set, since those are the cavities with an actual floor to root in. `cavity_instances`
## (the general set, including ordinary wall niches) is the fallback when no floor-level cavity exists
## yet (e.g. depth < 1.0, no connect_adjacent through-passages carved) so this module still places a
## sensible field of plants rather than emitting nothing. Each candidate cavity gets its OWN small
## Poisson-disk cluster (radius = cavity `size`, biased toward the LOWER half of the local footprint
## plane -- "toward the floor", `v_bias`) so plants root near the cavity's own ground rather than
## floating mid-opening. Growth direction is WORLD-UP (`Basis` built from a random yaw only) -- plants
## do not lean with the wall's own surface normal, matching how vegetation actually grows regardless
## of the rock face it roots against; a small `protrusion` pushes each plant's base off the wall
## surface along the cavity's own +Z (into the corridor interior, the SAME direction cavity_carver's
## and amber_light_cube_scatterer's own "sit proud, visible from the hallway" convention uses) so
## plants read as standing IN the opening, not embedded in the rock.
##
## Every returned placement: {"transform": Transform3D, "cavity_ring": int, "call_target": String,
## "scene_node": Dictionary (or null for an unresolved asset-seam handle), "seed": int,
## "on_floor": bool, "scale": float} -- pure DATA, same "return ready components" pattern
## cavity_instances/amber-cube placements already use.
##
## Tunables (the EXACT two named by the plan -- no more, per no-auto-generalization):
##   tree_asset_handle  (String) -- "lsystem:<species>" for a built-in procedural plant (default
##                                  "lsystem:default"), or any other handle -- passed through as an
##                                  unresolved `call_target` for the future CC0 asset seam.
##   density            (float 0..1) -- per-cavity Poisson-disk field acceptance probability.
## (Implementation-detail defaults below -- e.g. `min_spacing_fraction`, `size_min`/`size_max`,
## `max_per_cavity`, `protrusion` -- are documented decisions overridable via `tunables`, the same
## pattern cavity_carver.gd's DEFAULT_SIZE_FRACTION etc. and ring_scaffold.gd's own extra params use.)

const DEFAULT_TREE_ASSET_HANDLE := "lsystem:default"
const LSYSTEM_PREFIX := "lsystem:"
const DEFAULT_DENSITY := 0.55
const DEFAULT_SEED := 0
const DEFAULT_MIN_SPACING_FRACTION := 0.45   # per-cavity Poisson min-spacing, as a fraction of cavity size
const DEFAULT_SIZE_MIN := 0.6                # plant footprint scale range (world units)
const DEFAULT_SIZE_MAX := 1.4
const DEFAULT_MAX_PER_CAVITY := 6            # safety cap (ScatterComposer's own max_points is far higher)
const DEFAULT_PROTRUSION := 0.05             # world units, offset off the wall surface into the corridor
const DEFAULT_V_BIAS := 0.65                 # [0,1]; higher = candidates cluster harder toward the floor

## Built-in L-system "species" -- a small deterministic library, not exhaustive (REUSE-wiring scope,
## no new plant-authoring tooling). Picked per-plant by a seeded roll so a cavity's cluster reads as
## mixed undergrowth rather than one repeated shape. Rule/turtle shapes are the classic ABOP forms
## LSystem.gd's own docstring already documents (F/+/-/[/]).
const LSYSTEM_SPECIES := {
	"default": {
		"axiom": "X", "depth": 4,
		"rules": {"X": "F[+X][-X]FX", "F": "FF"},
		"turtle": {"step": 0.32, "angle_deg": 24.0, "radius": 0.05, "radius_decay": 0.72, "step_decay": 0.92},
	},
	"fern": {
		"axiom": "X", "depth": 5,
		"rules": {"X": [[0.6, "F-[[X]+X]+F[+FX]-X"], [0.4, "F+[[X]-X]-F[-FX]+X"]], "F": "FF"},
		"turtle": {"step": 0.22, "angle_deg": 22.5, "radius": 0.03, "radius_decay": 0.75, "step_decay": 0.9},
	},
	"shrub": {
		"axiom": "F", "depth": 3,
		"rules": {"F": [[0.5, "F[+F]F[-F]F"], [0.5, "F[+F][-F]F"]]},
		"turtle": {"step": 0.4, "angle_deg": 30.0, "radius": 0.06, "radius_decay": 0.68, "step_decay": 0.95},
	},
}
const LSYSTEM_SPECIES_ORDER := ["default", "fern", "shrub"]  # deterministic pick order for the roll


## Scatter plants across `cavity_instances` (NonOverlappingCavityCarver.carve()'s own output),
## preferring the floor-level subset `cavity_cutaway_field` when it is non-empty. Returns an
## Array[Dictionary] of `plant_placements` (see file header for the exact shape).
static func scatter(cavity_instances: Array, cavity_cutaway_field: Array, tunables: Dictionary = {}) -> Array[Dictionary]:
	var candidates: Array = cavity_cutaway_field if not cavity_cutaway_field.is_empty() else cavity_instances
	var out: Array[Dictionary] = []
	var idx := 0
	for inst in candidates:
		out.append_array(_scatter_one_cavity(inst, idx, tunables))
		idx += 1
	return out


## One cavity's own Poisson-disk plant cluster. `cavity_index` seeds the per-cavity RNG deterministically
## alongside the caller-supplied `seed` tunable (never relies on ScatterComposer.Placement.seed alone --
## same lesson cavity_carver.gd's own docstring records: that field is the RUN's initial seed, constant
## across every point in one sample() call, not a unique per-point id).
static func _scatter_one_cavity(cavity_instance: Dictionary, cavity_index: int, tunables: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not cavity_instance.has("transform"):
		return out
	var transform: Transform3D = cavity_instance["transform"]
	var ring: int = int(cavity_instance.get("ring", 0))
	var on_floor: bool = bool(cavity_instance.get("through", false))

	var density: float = clampf(float(tunables.get("density", DEFAULT_DENSITY)), 0.0, 1.0)
	if density <= 0.0:
		return out
	var handle: String = String(tunables.get("tree_asset_handle", DEFAULT_TREE_ASSET_HANDLE))
	var base_seed: int = int(tunables.get("seed", DEFAULT_SEED))
	var min_spacing_fraction: float = maxf(0.05, float(tunables.get("min_spacing_fraction", DEFAULT_MIN_SPACING_FRACTION)))
	var protrusion: float = float(tunables.get("protrusion", DEFAULT_PROTRUSION))
	var v_bias: float = clampf(float(tunables.get("v_bias", DEFAULT_V_BIAS)), 0.0, 1.0)
	var max_per_cavity: int = maxi(1, int(tunables.get("max_per_cavity", DEFAULT_MAX_PER_CAVITY)))

	var size: float = maxf(0.1, float(cavity_instance.get("size", 0.5)))
	var min_spacing: float = maxf(0.02, size * min_spacing_fraction)
	var cavity_seed := int(hash(Vector3i(base_seed, cavity_index, ring)))

	# Local footprint domain: a square of side 2*size in the cavity's own (right=basis.x, "up-along-
	# wall"=basis.y) plane, biased toward the LOWER half via the field_fn (v_bias) and hard-clipped to
	# the cavity's own radius so accepted points stay within its physical opening -- same disk-from-
	# square trick `_niche_mesh`'s own footprint shapes already rely on (cavity_carver.gd).
	var domain_min := Vector2(-size, -size)
	var domain_max := Vector2(size, size)
	var field_fn := func(p: Vector2) -> float:
		if p.length() > size:
			return 0.0
		# v in [-size, size] -> normalized [0,1], 0 = top of footprint, 1 = bottom.
		var v_norm: float = clampf((p.y + size) / (2.0 * size), 0.0, 1.0)
		var floor_weight: float = lerpf(1.0 - v_bias, 1.0 + v_bias, 1.0 - v_norm)
		return clampf(density * floor_weight, 0.0, 1.0)
	var to_transform := func(p: Vector2, rng: RandomNumberGenerator) -> Transform3D:
		var origin: Vector3 = transform.origin + transform.basis.x * p.x + transform.basis.y * p.y
		origin += transform.basis.z * protrusion
		var yaw := rng.randf_range(0.0, TAU)
		return Transform3D(Basis(Vector3.UP, yaw), origin)

	var placements := ScatterComposer.sample(domain_min, domain_max, min_spacing, field_fn,
		cavity_seed, handle, to_transform, 30, max_per_cavity)

	for p in placements:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(p.seed) ^ int(hash(p.point))
		var scale := _random_scale(rng, tunables)
		var scene_node = _build_scene_node(handle, rng, scale)
		out.append({
			"transform": p.transform,
			"cavity_ring": ring,
			"call_target": handle,
			"scene_node": scene_node,
			"seed": int(p.seed),
			"on_floor": on_floor,
			"scale": scale,
		})
	return out


static func _random_scale(rng: RandomNumberGenerator, tunables: Dictionary) -> float:
	var lo: float = maxf(0.01, float(tunables.get("size_min", DEFAULT_SIZE_MIN)))
	var hi: float = maxf(lo, float(tunables.get("size_max", DEFAULT_SIZE_MAX)))
	return rng.randf_range(lo, hi)


## Build one plant's renderer-neutral `scene_node` via LSystem, or return null when `handle` is NOT
## an `"lsystem:"` handle (the CC0 asset seam -- a later pass resolves `call_target` into real geometry;
## this module never guesses at an asset it hasn't ingested).
static func _build_scene_node(handle: String, rng: RandomNumberGenerator, scale: float) -> Variant:
	if not handle.begins_with(LSYSTEM_PREFIX):
		return null
	var species_name := handle.substr(LSYSTEM_PREFIX.length())
	var species: Dictionary = LSYSTEM_SPECIES.get(species_name, {})
	if species.is_empty():
		# Unknown species name after the "lsystem:" prefix (including the empty string from a bare
		# "lsystem:") -- seeded roll across the known library rather than a hard failure, so a caller
		# can pass "lsystem:" alone to mean "any built-in species".
		species = LSYSTEM_SPECIES[LSYSTEM_SPECIES_ORDER[rng.randi_range(0, LSYSTEM_SPECIES_ORDER.size() - 1)]]

	var plant_seed := rng.randi()
	var symbols := LSystem.expand(String(species.get("axiom", "X")), species.get("rules", {}),
		int(species.get("depth", 4)), plant_seed)
	var turtle: Dictionary = (species.get("turtle", {}) as Dictionary).duplicate()
	turtle["step"] = float(turtle.get("step", 0.3)) * scale
	turtle["radius"] = float(turtle.get("radius", 0.05)) * scale
	var segments := LSystem.interpret(symbols, turtle)
	return LSystem.to_scene_node(segments, "plant_%s" % species_name)
