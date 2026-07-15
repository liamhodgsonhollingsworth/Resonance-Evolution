class_name ScatterComposer
extends RefCounted
## Poisson-disk Scatter Composer — Wave 1 item 1.1 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (Wavelet repo):
## "Seeded 2D Poisson-disk sampling weighted by a constraint field (density x
## biome/UV x slope), deterministic, emits {transform, CALL @target, seed}
## per placement." Both scene projects' constraint fields differ (terrain /
## wall-sill for the brick-street scene, unrolled-cylinder-UV for the
## underground-halls scene) but the sampler itself is FIELD-AGNOSTIC — the
## field is an input Callable, never baked in. Shared substrate, build once,
## consumed by A's nodes 12/14 and B's nodes 5/8/12.
##
## Pure DATA in -> pure DATA out (an Array of placement Dictionaries); no
## Image, no shader, no scene-tree dependency required to CALL this — same
## portability invariant as DetailField (renderers/detail_field.gd): the same
## sampler drives a Godot delegate today and a three.js/Python port later,
## unchanged.
##
## Algorithm: Bridson's grid-accelerated Poisson-disk dart-throwing over a
## rectangular 2D domain, DENSITY-WEIGHTED by an externally supplied field —
## a candidate survives a seeded Bernoulli draw against `field_fn(u, v)`
## (probability of acceptance), so density varies smoothly with the field
## while every ACCEPTED point still keeps the same hard `min_dist` from every
## other accepted point (density weighting thins candidates; it never
## violates the no-overlap guarantee). Deterministic: the SAME seed + SAME
## field + SAME params always produce the SAME point set — every random draw
## comes from one seeded RandomNumberGenerator consumed in a fixed,
## reproducible order (grid-accelerated dart-throwing order, never
## dictionary/set iteration order).
##
## Implemented as an instance (`_Run`) that owns its own mutable sampling
## state (grid / active list / rng), rather than nested closures over shared
## locals — deliberately avoids GDScript lambda-capture pitfalls for mutable
## state. `ScatterComposer.sample()` / `.sample_dicts()` are the public,
## purely-functional entry points; `_Run` is a private implementation detail.

## One accepted placement. `call_target` is the CALL @target handle from the
## spec text — an opaque identifier string naming what generator/asset the
## caller should invoke at this transform (e.g. an asset-picklist handle, a
## proc3d part name); this module does not resolve or invoke it, matching the
## reuse/portability law (a scatter composer places, it doesn't build).
class Placement:
	var transform: Transform3D
	var call_target: String
	var seed: int
	var point: Vector2  ## the raw (u, v) domain-space sample, pre-to_transform

	func _init(p_transform: Transform3D, p_call_target: String, p_seed: int, p_point: Vector2) -> void:
		transform = p_transform
		call_target = p_call_target
		seed = p_seed
		point = p_point

	func to_dict() -> Dictionary:
		return {
			"transform": transform,
			"call_target": call_target,
			"seed": seed,
			"point": point,
		}


## Private per-call sampling run — owns the grid/active-list/rng state for
## ONE `sample()` invocation. Kept as plain member variables + methods (not
## closures) so mutable state is unambiguous.
class _Run:
	var domain_min: Vector2
	var domain_max: Vector2
	var min_dist: float
	var field_fn: Callable
	var call_target: String
	var to_transform: Callable
	var k: int
	var max_points: int
	var rng: RandomNumberGenerator

	var size: Vector2
	var cell_size: float
	var grid_w: int
	var grid_h: int
	var grid: PackedInt32Array
	var out: Array[Placement]
	var active: Array[int]

	func _init(p_domain_min: Vector2, p_domain_max: Vector2, p_min_dist: float,
			p_field_fn: Callable, p_seed: int, p_call_target: String,
			p_to_transform: Callable, p_k: int, p_max_points: int) -> void:
		domain_min = p_domain_min
		domain_max = p_domain_max
		min_dist = p_min_dist
		field_fn = p_field_fn
		call_target = p_call_target
		to_transform = p_to_transform
		k = p_k
		max_points = p_max_points
		rng = RandomNumberGenerator.new()
		rng.seed = p_seed

		size = domain_max - domain_min
		out = []
		active = []

		if min_dist <= 0.0 or size.x <= 0.0 or size.y <= 0.0:
			grid_w = 0
			grid_h = 0
			return

		# Background acceleration grid: cell size min_dist/sqrt(2) so each
		# cell holds at most one sample (standard Bridson grid).
		cell_size = min_dist / sqrt(2.0)
		grid_w = maxi(1, int(ceil(size.x / cell_size)))
		grid_h = maxi(1, int(ceil(size.y / cell_size)))
		grid = PackedInt32Array()
		grid.resize(grid_w * grid_h)
		for i in grid.size():
			grid[i] = -1  # index into `out`, or -1 = empty

	func _cell_of(p: Vector2) -> Vector2i:
		var gx := clampi(int((p.x - domain_min.x) / cell_size), 0, grid_w - 1)
		var gy := clampi(int((p.y - domain_min.y) / cell_size), 0, grid_h - 1)
		return Vector2i(gx, gy)

	func _fits(p: Vector2) -> bool:
		if p.x < domain_min.x or p.x > domain_max.x or p.y < domain_min.y or p.y > domain_max.y:
			return false
		var c := _cell_of(p)
		var lo_x := maxi(0, c.x - 2)
		var hi_x := mini(grid_w - 1, c.x + 2)
		var lo_y := maxi(0, c.y - 2)
		var hi_y := mini(grid_h - 1, c.y + 2)
		for gy in range(lo_y, hi_y + 1):
			for gx in range(lo_x, hi_x + 1):
				var idx := grid[gy * grid_w + gx]
				if idx == -1:
					continue
				if p.distance_to(out[idx].point) < min_dist:
					return false
		return true

	func _passes_field(p: Vector2) -> bool:
		if not field_fn.is_valid():
			return true
		return rng.randf() < clampf(field_fn.call(p), 0.0, 1.0)

	func _emit(p: Vector2) -> void:
		var c := _cell_of(p)
		var idx := out.size()
		var xform: Transform3D
		if to_transform.is_valid():
			xform = to_transform.call(p, rng)
		else:
			xform = Transform3D(Basis.IDENTITY, Vector3(p.x, 0.0, p.y))
		out.append(Placement.new(xform, call_target, rng.seed, p))
		grid[c.y * grid_w + c.x] = idx
		active.append(idx)

	func run() -> Array[Placement]:
		if grid_w == 0 or grid_h == 0:
			return out

		# Retry the seed point against the field: a single seed draw that
		# lands in a low/zero-probability region would otherwise terminate
		# the whole run with zero points (nothing to grow from), even though
		# the field is non-zero elsewhere in the domain. Cap attempts so a
		# genuinely all-zero field still (correctly) terminates empty rather
		# than looping forever.
		var max_seed_attempts := 2000
		for _seed_attempt in max_seed_attempts:
			var first := domain_min + Vector2(rng.randf() * size.x, rng.randf() * size.y)
			if _passes_field(first):
				_emit(first)
				break

		while active.size() > 0 and out.size() < max_points:
			var active_slot := rng.randi_range(0, active.size() - 1)
			var origin_idx: int = active[active_slot]
			var origin: Vector2 = out[origin_idx].point
			var found := false
			for _attempt in k:
				var ang := rng.randf() * TAU
				var rad := min_dist * (1.0 + rng.randf())  # in [min_dist, 2*min_dist)
				var cand := origin + Vector2(cos(ang), sin(ang)) * rad
				if not _fits(cand):
					continue
				if not _passes_field(cand):
					continue
				_emit(cand)
				found = true
				if out.size() >= max_points:
					break
			if not found:
				active.remove_at(active_slot)

		return out


## Sample a density-weighted Poisson-disk point set over
## `[domain_min, domain_max]` and emit one Placement per accepted point.
##
##   domain_min / domain_max : Vector2   the 2D sampling rectangle (UV space,
##                                        world XZ, or an unrolled-cylinder
##                                        (theta, height) strip — caller's
##                                        choice; the sampler is domain-agnostic)
##   min_dist   : float                  hard minimum spacing between any two
##                                        accepted points, in domain units
##   field_fn   : Callable(Vector2)->float  the constraint field (density x
##                                        biome/UV x slope, pre-combined by the
##                                        caller); returns an acceptance
##                                        probability in [0, 1]. Pass an
##                                        invalid/empty Callable (the default)
##                                        for a uniform field (every candidate
##                                        that clears the spacing check is
##                                        accepted).
##   seed       : int                    RNG seed; identical seed -> identical
##                                        output
##   call_target: String                 the CALL @target handle stamped onto
##                                        every emitted Placement
##   to_transform: Callable(Vector2, RandomNumberGenerator)->Transform3D
##                                        maps an accepted (u, v) domain point
##                                        to a full engine Transform3D — lets
##                                        each scene supply its own domain ->
##                                        world mapping (terrain height lookup,
##                                        cylinder-unroll re-projection) and its
##                                        own rotation/scale jitter using the
##                                        SAME seeded rng (keeps the whole
##                                        placement deterministic end to end).
##                                        Default: identity rotation/scale,
##                                        position = Vector3(u, 0, v) — a flat
##                                        XZ-plane placement (matches both
##                                        scenes' Wave-1 "flat" defaults: flat
##                                        concentric rings at one elevation for
##                                        the underground-halls scene, a flat
##                                        street grid for the brick-street
##                                        scene).
##   k          : int                    Bridson candidates-per-active-point
##                                        before giving up on that point
##                                        (standard default 30)
##   max_points : int                    hard safety cap on emitted placements
static func sample(
	domain_min: Vector2,
	domain_max: Vector2,
	min_dist: float,
	field_fn: Callable = Callable(),
	seed: int = 0,
	call_target: String = "",
	to_transform: Callable = Callable(),
	k: int = 30,
	max_points: int = 20000,
) -> Array[Placement]:
	if min_dist <= 0.0:
		push_error("ScatterComposer.sample: min_dist must be > 0")
		return []
	var run := _Run.new(domain_min, domain_max, min_dist, field_fn, seed,
		call_target, to_transform, k, max_points)
	return run.run()


## Convenience: same as `sample()` but returns plain Dictionaries
## (`Placement.to_dict()`) — for callers (or tests) that want the wire-format
## shape directly rather than the typed wrapper.
static func sample_dicts(
	domain_min: Vector2,
	domain_max: Vector2,
	min_dist: float,
	field_fn: Callable = Callable(),
	seed: int = 0,
	call_target: String = "",
	to_transform: Callable = Callable(),
	k: int = 30,
	max_points: int = 20000,
) -> Array[Dictionary]:
	var placements := sample(domain_min, domain_max, min_dist, field_fn, seed,
		call_target, to_transform, k, max_points)
	var out: Array[Dictionary] = []
	for p in placements:
		out.append(p.to_dict())
	return out
