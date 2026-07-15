class_name AmberLightCubeScatterer
extends RefCounted
## AmberLightCubeScatterer -- Wave 4 item 4.1 (A) of DQ-60f088f7 (notes/planning/
## scene_projects_comparison_2026_07_14.md §5's Wave 4, first item of Project B's underground-halls
## light-cube tier). Liam's own words (verbatim, underground_halls_plan_2026_07_14.md's amber-cube
## spec): "cubes of glowing amber... translucent orange glass," varying sizes within a range, placed
## ON WALLS AND INSIDE CAVITIES, "you should focus on getting these right to the image in general
## aesthetic and coloration because they compose the whole vibe of the image." AESTHETIC-CRITICAL.
##
## REUSE, no primitive-internals edit (reuse/portability law):
##   - ScatterComposer.sample() (renderers/scatter_composer.gd) -- the density-weighted Poisson-disk
##     placement for the WALL-EMBEDDED tier (`scatter_wall`), consuming a
##     RingScaffoldGenerator.wall_surface_uv() domain exactly like NonOverlappingCavityCarver does.
##   - NonOverlappingCavityCarver.carve()'s own `cavity_instances` output (renderers/cavity_carver.gd)
##     for the CAVITY-INTERIOR tier (`scatter_cavities`) -- a seeded per-cavity Bernoulli draw decides
##     which carved niches/through-passages get a cube, placed at the cavity's own transform offset
##     toward the corridor interior (+Z, per wall_surface_uv's own convention) so the cube sits IN the
##     opening, visible from the hallway.
##
## Two placement tiers, ONE shared material family + size-range (`build_material`/tunables) so both
## tiers always read as the SAME light-cube family:
##   scatter_wall(wall_uv, tunables)              -- cubes set directly into flat wall surface,
##                                                    Poisson-spaced.
##   scatter_cavities(cavity_instances, tunables)  -- cubes set into carved niches/through-passages.
##   scatter(wall_uv, cavity_instances, tunables)  -- convenience: both tiers combined.
##
## Every returned placement: {"transform": Transform3D, "size": float, "mesh": BoxMesh,
## "in_cavity": bool} -- pure DATA + a ready BoxMesh per placement (same "return ready components"
## pattern cavity_carver.gd's `cavity_instances` uses); the material is built ONCE
## (`build_material()`) and shared by the caller across every placement (matches
## wave3_rock_floor_proof.gd's single-material-instance batching note) unless the caller opts into
## per-placement `jittered_material()` for visible hue variation across the field.
##
## Tunables (the EXACT ones named -- no more, per no-auto-generalization; Liam's spec text quoted
## inline where it drives a specific field):
##   density                  (float 0..1) -- wall-tier Poisson-disk field acceptance probability.
##   min_spacing               (float)     -- wall-tier hard minimum spacing, world units.
##   size_min / size_max       (float)     -- cube edge length range, world units ("varying sizes
##                                            within a range").
##   hue                       (float 0..1)-- amber hue center (HSV wheel fraction; ~0.085 = warm
##                                            orange-amber).
##   hue_jitter                (float 0..1)-- per-cube hue variation (`jittered_material` only) so a
##                                            field of cubes doesn't read as one flat repeated color.
##   saturation / value        (float 0..1)-- HSV S/V for the base albedo.
##   emission_energy           (float)     -- inner-glow strength ("glowing amber").
##   glass_alpha                (float 0..1)-- translucency ("translucent orange glass").
##   cavity_fill_probability   (float 0..1)-- per-cavity chance of getting a cube.
##   protrusion                 (float)     -- how far a cube sits proud of the wall surface along its
##                                            normal (world units) -- reads as an INLAID object, not a
##                                            flush decal.
##   seed                       (int)

const DEFAULT_DENSITY := 0.35
const DEFAULT_MIN_SPACING := 1.1
const DEFAULT_SIZE_MIN := 0.10
const DEFAULT_SIZE_MAX := 0.30
const DEFAULT_HUE := 0.085
const DEFAULT_HUE_JITTER := 0.02
const DEFAULT_SATURATION := 0.72
const DEFAULT_VALUE := 0.98
const DEFAULT_EMISSION_ENERGY := 2.6
const DEFAULT_GLASS_ALPHA := 0.55
const DEFAULT_CAVITY_FILL_PROBABILITY := 0.55
const DEFAULT_PROTRUSION := 0.04
const DEFAULT_SEED := 0


## Build the ONE shared material every placed cube uses by default ("emissive translucent
## orange-glass"). StandardMaterial3D transparency mode ALPHA is Godot's cheap glass approximation --
## same escalation-ladder discipline reflective_floor_material.gd's SSR-first choice uses: a real
## refractive glass shader is a later escalation rung if the flat-alpha read isn't convincing enough
## on its own (refraction_enabled adds a light bend on top, cheaply, without a bespoke shader).
static func build_material(tunables: Dictionary = {}) -> StandardMaterial3D:
	var hue: float = clampf(float(tunables.get("hue", DEFAULT_HUE)), 0.0, 1.0)
	var sat: float = clampf(float(tunables.get("saturation", DEFAULT_SATURATION)), 0.0, 1.0)
	var val: float = clampf(float(tunables.get("value", DEFAULT_VALUE)), 0.0, 1.0)
	var alpha: float = clampf(float(tunables.get("glass_alpha", DEFAULT_GLASS_ALPHA)), 0.0, 1.0)
	var emission_energy: float = maxf(0.0, float(tunables.get("emission_energy", DEFAULT_EMISSION_ENERGY)))

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(hue, sat, val, alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = Color.from_hsv(hue, clampf(sat * 0.6, 0.0, 1.0), 1.0)
	mat.emission_energy_multiplier = emission_energy
	mat.roughness = 0.15
	mat.metallic = 0.0
	mat.refraction_enabled = true
	mat.refraction_scale = 0.05
	return mat


## One placement's hue-jittered material variant -- OPTIONAL per-placement material so a field of
## cubes reads as "varying sizes AND a warm hand-placed range of amber tones," not one flat repeated
## color. `build_material()` remains the single SHARED default for callers that want one batched
## material (cheaper: one draw-call family); a caller picks per its own perf/aesthetic tradeoff.
static func jittered_material(tunables: Dictionary, rng: RandomNumberGenerator) -> StandardMaterial3D:
	var hue: float = clampf(float(tunables.get("hue", DEFAULT_HUE)), 0.0, 1.0)
	var jitter: float = clampf(float(tunables.get("hue_jitter", DEFAULT_HUE_JITTER)), 0.0, 1.0)
	var t := tunables.duplicate()
	t["hue"] = clampf(hue + rng.randf_range(-jitter, jitter), 0.0, 1.0)
	return build_material(t)


static func _cube_mesh(size: float) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size, size, size)
	return mesh


static func _random_size(rng: RandomNumberGenerator, tunables: Dictionary) -> float:
	var lo: float = maxf(0.001, float(tunables.get("size_min", DEFAULT_SIZE_MIN)))
	var hi: float = maxf(lo, float(tunables.get("size_max", DEFAULT_SIZE_MAX)))
	return rng.randf_range(lo, hi)


## Wall-embedded tier: Poisson-disk cubes set directly into a ring's flat inner-shell surface, via
## ScatterComposer.sample() over `wall_uv` (a RingScaffoldGenerator.wall_surface_uv() descriptor) --
## the SAME domain/to_transform contract NonOverlappingCavityCarver consumes, so wall-tier cubes and
## cavity carving agree on "where is the wall" without this module re-deriving any geometry.
static func scatter_wall(wall_uv: Dictionary, tunables: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not (wall_uv.has("domain_min") and wall_uv.has("domain_max") and wall_uv.has("to_transform")):
		return out

	var density: float = clampf(float(tunables.get("density", DEFAULT_DENSITY)), 0.0, 1.0)
	var min_spacing: float = maxf(0.05, float(tunables.get("min_spacing", DEFAULT_MIN_SPACING)))
	var seed_value: int = int(tunables.get("seed", DEFAULT_SEED))
	var protrusion: float = float(tunables.get("protrusion", DEFAULT_PROTRUSION))

	var domain_min: Vector2 = wall_uv["domain_min"]
	var domain_max: Vector2 = wall_uv["domain_max"]
	var to_transform: Callable = wall_uv["to_transform"]
	var field_fn := func(_p: Vector2) -> float: return density

	var placements := ScatterComposer.sample(domain_min, domain_max, min_spacing, field_fn,
		seed_value, "amber_light_cube", to_transform)

	for p in placements:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(p.seed) ^ int(hash(p.point))
		var size := _random_size(rng, tunables)
		# Cube sits proud of the wall along the surface's OWN +Z (corridor-interior direction, per
		# wall_surface_uv's own docstring) -- an inlaid-but-visible read, never flush/hidden in the
		# wall material.
		var xform: Transform3D = p.transform
		xform.origin += xform.basis.z * (protrusion + size * 0.5)
		out.append({"transform": xform, "size": size, "mesh": _cube_mesh(size), "in_cavity": false})
	return out


## Cavity-interior tier: a seeded per-cavity Bernoulli draw decides which of `cavity_instances`
## (NonOverlappingCavityCarver.carve()'s own `cavity_instances` output -- niches AND through-passages
## both eligible) get a cube, placed at that cavity's OWN transform (already the wall-surface opening
## point) offset the SAME "sit proud toward the corridor" direction the wall tier uses, so both tiers
## read as one consistent light-cube family regardless of which surface they're inlaid into.
static func scatter_cavities(cavity_instances: Array, tunables: Dictionary = {}) -> Array[Dictionary]:
	var fill_probability: float = clampf(
		float(tunables.get("cavity_fill_probability", DEFAULT_CAVITY_FILL_PROBABILITY)), 0.0, 1.0)
	var seed_value: int = int(tunables.get("seed", DEFAULT_SEED))
	var protrusion: float = float(tunables.get("protrusion", DEFAULT_PROTRUSION))

	var out: Array[Dictionary] = []
	var idx := 0
	for inst in cavity_instances:
		var d: Dictionary = inst
		var rng := RandomNumberGenerator.new()
		rng.seed = int(hash(Vector3i(seed_value, idx, int(d.get("ring", 0)))))
		idx += 1
		if rng.randf() >= fill_probability:
			continue
		var size := _random_size(rng, tunables)
		var xform: Transform3D = d.get("transform", Transform3D())
		xform.origin += xform.basis.z * (protrusion + size * 0.5)
		out.append({"transform": xform, "size": size, "mesh": _cube_mesh(size), "in_cavity": true})
	return out


## Convenience: both tiers combined -- the "on walls AND inside cavities" full placement set a scene
## driver instantiates in one loop.
static func scatter(wall_uv: Dictionary, cavity_instances: Array, tunables: Dictionary = {}) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append_array(scatter_wall(wall_uv, tunables))
	out.append_array(scatter_cavities(cavity_instances, tunables))
	return out
