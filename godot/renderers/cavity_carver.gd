class_name NonOverlappingCavityCarver
extends RefCounted
## NonOverlappingCavityCarver -- node 8 ("Cavity / bridge tier") of
## notes/planning/underground_halls_plan_2026_07_14.md §4, Wave 3 item 3.1 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-6963c689). 2D Poisson-disk
## placement on the unrolled wall UV (plan §2.2), then SDF add/subtract of circle/ellipse/eye
## shapes at each placement (plan §2.5's SDF-sculpt choice).
##
## REUSE (no changes to any of these files):
##   - RingScaffoldGenerator.wall_surface_uv() (renderers/ring_scaffold.gd, PR #190) -- the
##     unrolled-cylinder UV-strip domain, already shaped to plug into ScatterComposer.sample()
##     unchanged.
##   - ScatterComposer.sample() (renderers/scatter_composer.gd, Wave 1 item 1.1) -- the
##     density-weighted Poisson-disk sampler, field-agnostic.
##   - SDF (renderers/sdf.gd) analytic primitive distances + CSG ops, COMPOSED here (never edited)
##     into the three cavity footprints below, emitted as SDF.EDIT_FORMAT edit-list descriptors
##     (prim_sdf_edit.gd's own wire shape) for a later sculpt/voxel slice (the visuals session's
##     lane, per prim_sdf_edit.gd's own docstring) to evaluate into geometry. This module also
##     builds a small DIRECT parametric "niche pocket" / "through passage" Mesh per cavity for
##     `carved_wall_mesh` -- the SAME house style ring_scaffold.gd itself uses (parametric
##     SurfaceTool geometry, not a real-time CSG boolean or SDF voxelization -- both explicitly
##     out of scope for the live regenerate loop per plan §2.5).
##
## CROSS-RING WALL COORDINATION -- the CRITICAL correctness requirement (plan FM-4, §6 item 4;
## resolution E4, §5; quoted verbatim from DQ-6963c689): "a shared wall between two adjacent rings
## ... must be carved ONCE from the UNION of both rings' cavity-candidate sets -- carving each
## ring's wall_surface_uv strip independently can produce a mismatch/overlap the other ring's
## strip never saw."
##
## GEOMETRIC BASIS for the fix, derived from ring_scaffold.gd's own wall_surface_uv() docstring +
## its `to_transform` math: `v` (the cross-section angle) has v=0/1 ("springline") on the OUTWARD
## side of a ring's tube (offset along the WORLD-radial direction, away from the world center) and
## v=0.5 on the INWARD side (offset toward the world center). ring_scaffold.gd's own "gap plays two
## roles" design note establishes that ring N's OUTER shell boundary and ring (N+1)'s INNER shell
## boundary coincide at radius = ring_N.radius + gap/2 (rings are packed edge-to-edge) -- so ring
## N's wall at v≈0 and ring (N+1)'s wall at v≈0.5, AT THE SAME ANGLE `a`, are literally the two
## faces of the SAME physical partition.
##
## Fix: for every adjacent ring pair (ring, ring.adjacent_out), when `depth` selects
## connect_adjacent mode, sample that SHARED WALL'S Poisson-disk candidates EXACTLY ONCE (owned by
## the lower-indexed ring of the pair) restricted to a narrow springline band, then PROJECT each
## accepted angle onto BOTH rings' wall_surface_uv (v=0 on the lower ring, v=0.5 on the higher
## ring) to emit ONE linked pair of cavity_instances (a through-passage). The general/independent
## Poisson-disk pass every ring ALSO runs (for its non-shared ceiling/floor wall + either springline
## band when that side has no adjacent ring, or when NOT in connect_adjacent mode) explicitly
## EXCLUDES whichever springline bands the owner-pass above already covers, via the SAME
## ScatterComposer field_fn mechanism (never a second, overlapping domain) -- see `_exclude_bands`.

# ── Tunables (plan §4 node 8) ───────────────────────────────────────────────────────────────────
const SHAPE_CIRCLE := "circle"
const SHAPE_ELLIPSE := "ellipse"
const SHAPE_EYE := "eye"
const SHAPE_MIX := "mix"
const SHAPES := [SHAPE_CIRCLE, SHAPE_ELLIPSE, SHAPE_EYE]          # concrete shapes "mix" draws from

const DEFAULT_SHAPE := SHAPE_CIRCLE
const DEFAULT_MIN_SPACING := 2.0          # hard Poisson-disk spacing, domain (world) units
const DEFAULT_DENSITY := 0.5              # ScatterComposer field acceptance probability, [0,1]
const DEFAULT_DEPTH := 1.0                # 0-1; >= CONNECT_ADJACENT_THRESHOLD = connect_adjacent
                                           # (Liam's explicit default, plan §4 node 8)
const DEFAULT_SEED := 0

# Implementation-detail defaults (not named as headline tunables by the plan, but needed to turn
# shape/min_spacing/depth into concrete geometry -- documented decisions, overridable via
# `tunables`, same pattern ring_scaffold.gd uses for cross_segments/arc_steps beyond node 1's own
# headline tunable list).
const DEFAULT_SIZE_FRACTION := 0.35       # cavity footprint half-size, as a fraction of min_spacing
const DEFAULT_MAX_CARVE_DEPTH := 1.2      # world units; depth=1.0-but-not-connect-mode caps here
const DEFAULT_SEGMENTS := 10              # footprint boundary polygon resolution

# depth >= this value selects "connect_adjacent" mode (FM-4/E4 cross-ring coordination). Values
# below run ordinary independent shallow-niche carving, with carve depth scaling with `depth`.
const CONNECT_ADJACENT_THRESHOLD := 0.999

# Width (as a fraction of the full [0,1) v-range) of the springline band reserved for the
# shared-wall owner-pass on each side (around v=0 and v=0.5) when connect_adjacent mode excludes
# it from the general independent pass. A design constant, not a plan-named tunable.
const SPRINGLINE_BAND_HALF := 0.12


## Carve cavities into every ring named in `wall_uv_by_ring` (ring index -> one
## RingScaffoldGenerator.wall_surface_uv() descriptor -- exactly RingScaffoldGenerator.build()'s
## own `wall_surface_uv` output shape), using `ring_topology`'s adjacency (from
## RingScaffoldGenerator.build_topology()) to resolve the FM-4/E4 cross-ring coordination. Returns:
##   {"cavity_instances": Array[Dictionary], "cavity_cutaway_field": Array[Dictionary]}
## Each `cavity_instances` entry:
##   {"ring": int, "connects_to_ring": int (-1 if none), "shape": String, "depth": float,
##    "elevation": float, "size": float, "transform": Transform3D, "point": Vector2,
##    "sdf_edits": Array (SDF.EDIT_FORMAT edit-list descriptor for this cavity), "seed": int,
##    "through": bool, "mesh": Mesh}
## `cavity_cutaway_field` is the SUBSET flagged `through == true` -- node 8's own "flags which
## cavities are street-level/floor-cutoff" output, feeding node 10 DirtFloorInfill + node 9
## BridgeGenerator later (both explicitly out of this item's scope, per DQ-6963c689's own text).
static func carve(ring_topology: Array, wall_uv_by_ring: Dictionary, tunables: Dictionary = {}) -> Dictionary:
	var shape: String = String(tunables.get("shape", DEFAULT_SHAPE))
	var min_spacing: float = maxf(0.05, float(tunables.get("min_spacing", DEFAULT_MIN_SPACING)))
	var density: float = clampf(float(tunables.get("density", DEFAULT_DENSITY)), 0.0, 1.0)
	var depth: float = clampf(float(tunables.get("depth", DEFAULT_DEPTH)), 0.0, 1.0)
	var seed_value: int = int(tunables.get("seed", DEFAULT_SEED))
	var size: float = maxf(0.02, float(tunables.get("cavity_size", min_spacing * DEFAULT_SIZE_FRACTION)))
	var max_carve_depth: float = maxf(0.05, float(tunables.get("max_carve_depth", DEFAULT_MAX_CARVE_DEPTH)))
	var segments: int = maxi(6, int(tunables.get("segments", DEFAULT_SEGMENTS)))

	var by_ring: Dictionary = {}
	for ring_data in ring_topology:
		by_ring[int(ring_data["ring"])] = ring_data

	var connect_mode: bool = depth >= CONNECT_ADJACENT_THRESHOLD
	var carve_depth: float = max_carve_depth if connect_mode else maxf(0.05, depth * max_carve_depth)

	var instances: Array = []
	var cutaway: Array = []

	for ring_data in ring_topology:
		var ring_index: int = int(ring_data["ring"])
		if not wall_uv_by_ring.has(ring_index):
			continue
		var wall_uv: Dictionary = wall_uv_by_ring[ring_index]
		var elevation: float = float(ring_data.get("elevation", 0.0))
		var adjacent_out: int = int(ring_data.get("adjacent_out", -1))
		var has_partner: bool = connect_mode and adjacent_out != -1 and wall_uv_by_ring.has(adjacent_out)

		# 1) General/independent pass -- every ring, every regeneration. Excludes whichever
		#    springline bands the owner-pass below will separately cover (see _exclude_bands),
		#    so the two passes never sample the same physical wall region twice.
		var excluded := _exclude_bands(ring_data, connect_mode, wall_uv_by_ring)
		var general_seed := _ring_seed(seed_value, ring_index)
		var general_placements := _sample_wall(wall_uv, min_spacing, density, general_seed,
			func(v: float) -> bool: return not _in_bands(v, excluded))
		for placement in general_placements:
			var rng := RandomNumberGenerator.new()
			rng.seed = int(placement.seed)
			var picked := _resolve_shape(shape, rng)
			instances.append(_niche_instance(ring_index, -1, elevation, placement, picked, size,
				carve_depth, depth, segments, rng))

		# 2) Owner pass -- ONLY when this ring owns a connect_adjacent shared wall with
		#    adjacent_out (FM-4/E4). Sampled ONCE here, restricted to the outward springline band,
		#    then projected onto BOTH walls at the same angle -- never independently re-sampled
		#    from adjacent_out's own loop iteration (which instead lands in branch 1 above for
		#    that shared band, since `_exclude_bands` excludes its v≈0.5 inward band whenever an
		#    adjacent_in ring exists in connect_mode).
		if has_partner:
			var far_ring_data: Dictionary = by_ring[adjacent_out]
			var far_wall_uv: Dictionary = wall_uv_by_ring[adjacent_out]
			var pair_seed := _pair_seed(seed_value, ring_index, adjacent_out)
			var shared_placements := _sample_wall(wall_uv, min_spacing, density, pair_seed,
				func(v: float) -> bool: return v <= SPRINGLINE_BAND_HALF or v >= 1.0 - SPRINGLINE_BAND_HALF)
			var pair_index := 0
			for placement in shared_placements:
				# NOTE: ScatterComposer.Placement.seed reads RandomNumberGenerator.seed, which is
				# the RUN's initial seed (constant for every point _emit()'d during that one
				# sample() call) -- NOT a unique per-point id. Every placement from THIS owner-pass
				# shares the same `.seed` value, so it cannot identify WHICH cavity a near/far pair
				# belongs to when a shared wall carries more than one. `pair_id` (ring pair + a
				# per-pass running index, both deterministic) is the real unique join key.
				var pair_id := "%d_%d_%d" % [ring_index, adjacent_out, pair_index]
				pair_index += 1
				var rng2 := RandomNumberGenerator.new()
				rng2.seed = int(placement.seed)
				var picked2 := _resolve_shape(shape, rng2)
				var radius_near: float = maxf(0.0001, float(ring_data.get("radius", 1.0)))
				var angle: float = placement.point.x / radius_near
				var radius_far: float = maxf(0.0001, float(far_ring_data.get("radius", 1.0)))
				var far_point := Vector2(angle * radius_far, 0.5)
				var far_rng := RandomNumberGenerator.new()
				far_rng.seed = int(placement.seed)
				var far_transform: Transform3D = (far_wall_uv["to_transform"] as Callable).call(far_point, far_rng)
				var pair := _through_pair(ring_index, adjacent_out, elevation,
					float(far_ring_data.get("elevation", elevation)), placement, far_transform,
					far_point, picked2, size, segments, rng2, pair_id)
				instances.append(pair["near"])
				instances.append(pair["far"])
				cutaway.append(pair["near"])
				cutaway.append(pair["far"])

	return {"cavity_instances": instances, "cavity_cutaway_field": cutaway}


## v-bands (as [lo,hi] Vector2 pairs, in the wall's [0,1) cross-section-angle space) the general/
## independent pass (branch 1 of `carve`) must EXCLUDE, because an owner-pass covers them instead:
## the OUTWARD band (v≈0) when THIS ring owns its (ring, adjacent_out) shared wall, and the INWARD
## band (v≈0.5) when the ring BELOW owns the (adjacent_in, ring) shared wall and projects onto this
## ring's v≈0.5. Only excluded in connect_mode with a real partner on that side -- otherwise there
## is nothing to connect to and that springline just gets ordinary independent shallow niches.
static func _exclude_bands(ring_data: Dictionary, connect_mode: bool, wall_uv_by_ring: Dictionary) -> Array:
	var bands: Array = []
	if not connect_mode:
		return bands
	var adjacent_out: int = int(ring_data.get("adjacent_out", -1))
	if adjacent_out != -1 and wall_uv_by_ring.has(adjacent_out):
		bands.append(Vector2(0.0, SPRINGLINE_BAND_HALF))
		bands.append(Vector2(1.0 - SPRINGLINE_BAND_HALF, 1.0))
	var adjacent_in: int = int(ring_data.get("adjacent_in", -1))
	if adjacent_in != -1 and wall_uv_by_ring.has(adjacent_in):
		bands.append(Vector2(0.5 - SPRINGLINE_BAND_HALF, 0.5 + SPRINGLINE_BAND_HALF))
	return bands

static func _in_bands(v: float, bands: Array) -> bool:
	for b in bands:
		if v >= (b as Vector2).x and v <= (b as Vector2).y:
			return true
	return false


## Sample one wall's Poisson-disk candidate set via ScatterComposer, gated by `density` AND a
## caller-supplied `v_allowed(v: float) -> bool` predicate (implements both the general pass's
## band-exclusion and the owner-pass's band-restriction through the SAME field_fn seam --
## ScatterComposer.sample() never needs to know about bands at all).
static func _sample_wall(wall_uv: Dictionary, min_spacing: float, density: float, seed_value: int,
		v_allowed: Callable) -> Array:
	var domain_min: Vector2 = wall_uv["domain_min"]
	var domain_max: Vector2 = wall_uv["domain_max"]
	var field_fn := func(p: Vector2) -> float:
		var v := p.y
		if not v_allowed.call(v):
			return 0.0
		return density
	return ScatterComposer.sample(domain_min, domain_max, min_spacing, field_fn, seed_value, "",
		wall_uv["to_transform"])

static func _ring_seed(base_seed: int, ring: int) -> int:
	return int(hash(Vector2i(base_seed, ring * 7919)))

static func _pair_seed(base_seed: int, ring_a: int, ring_b: int) -> int:
	var lo := mini(ring_a, ring_b)
	var hi := maxi(ring_a, ring_b)
	return int(hash(Vector3i(base_seed, lo, hi)))

static func _resolve_shape(shape: String, rng: RandomNumberGenerator) -> String:
	if shape == SHAPE_MIX:
		return SHAPES[rng.randi_range(0, SHAPES.size() - 1)]
	if shape in SHAPES:
		return shape
	return DEFAULT_SHAPE


## One shallow (non-connecting) niche cavity_instance at `placement` (a ScatterComposer.Placement).
static func _niche_instance(ring: int, connects_to_ring: int, elevation: float, placement,
		shape: String, size: float, carve_depth: float, depth: float, segments: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var transform: Transform3D = placement.transform
	var edits := _sdf_edits(shape, transform, size, carve_depth, rng)
	var mesh := _niche_mesh(transform, shape, size, carve_depth, segments)
	return {
		"ring": ring, "connects_to_ring": connects_to_ring, "pair_id": "", "shape": shape,
		"depth": depth, "elevation": elevation, "size": size, "transform": transform,
		"point": placement.point, "sdf_edits": edits, "seed": placement.seed, "through": false,
		"mesh": mesh,
	}


## A linked pair of THROUGH cavity_instances (one per ring) sharing one wall opening -- the
## connect_adjacent case. Both carry `connects_to_ring` pointing at the other, the SAME `pair_id`
## (the reliable join key -- see the NOTE at the `carve()` call site on why `seed` cannot serve
## this role), and `through = true` (the `cavity_cutaway_field` flag node 10/9 consume later). The
## mesh on each is the SAME lofted passage geometry (see `_through_mesh`) so either side alone
## already shows the full opening.
static func _through_pair(ring_near: int, ring_far: int, elevation_near: float, elevation_far: float,
		near_placement, far_transform: Transform3D, far_point: Vector2, shape: String, size: float,
		segments: int, rng: RandomNumberGenerator, pair_id: String) -> Dictionary:
	var near_transform: Transform3D = near_placement.transform
	var mesh := _through_mesh(near_transform, far_transform, shape, size, segments)
	var near_edits := _sdf_edits(shape, near_transform, size, size * 2.0, rng)
	var far_edits := _sdf_edits(shape, far_transform, size, size * 2.0, rng)
	var near := {
		"ring": ring_near, "connects_to_ring": ring_far, "pair_id": pair_id, "shape": shape,
		"depth": 1.0, "elevation": elevation_near, "size": size, "transform": near_transform,
		"point": near_placement.point, "sdf_edits": near_edits, "seed": near_placement.seed,
		"through": true, "mesh": mesh,
	}
	var far := {
		"ring": ring_far, "connects_to_ring": ring_near, "pair_id": pair_id, "shape": shape,
		"depth": 1.0, "elevation": elevation_far, "size": size, "transform": far_transform,
		"point": far_point, "sdf_edits": far_edits, "seed": near_placement.seed, "through": true,
		"mesh": mesh,
	}
	return {"near": near, "far": far}


# ── SDF edit-list composition (SDF.gd primitives + ops, REUSE -- see file header) ────────────────

## Compose `shape`'s SDF.EDIT_FORMAT edit-list (1 edit for circle/ellipse, 2 for eye -- an
## intersection of two spheres, the classic vesica/almond construction) at `transform`, carved
## `carve_depth` world units into the material along transform's own -Z ("the carve direction, away
## from the corridor interior", per wall_surface_uv's own docstring). Matches prim_sdf_edit.gd's
## wire shape exactly so a later sculpt/voxel slice can consume these unchanged.
static func _sdf_edits(shape: String, transform: Transform3D, size: float, carve_depth: float,
		_rng: RandomNumberGenerator) -> Array:
	var q := transform.basis.get_rotation_quaternion()
	var rot := [q.x, q.y, q.z, q.w]
	match shape:
		SHAPE_ELLIPSE:
			var pos := transform.origin - transform.basis.z * (carve_depth * 0.5)
			return [{
				"format": SDF.EDIT_FORMAT, "shape": "round_box", "op": "subtract", "blend": 0.0,
				"transform": {"position": [pos.x, pos.y, pos.z], "scale": 1.0, "rotation": rot},
				"params": {"half_extents": [size, size * 0.6, carve_depth * 0.5], "radius": size * 0.55},
				"material": {},
			}]
		SHAPE_EYE:
			var d := size * 0.55
			var r := size * 0.75
			var center := transform.origin - transform.basis.z * (carve_depth * 0.5)
			var pos_a := center - transform.basis.x * d
			var pos_b := center + transform.basis.x * d
			return [
				{
					"format": SDF.EDIT_FORMAT, "shape": "sphere", "op": "subtract", "blend": 0.0,
					"transform": {"position": [pos_a.x, pos_a.y, pos_a.z], "scale": 1.0, "rotation": rot},
					"params": {"radius": r}, "material": {},
				},
				{
					"format": SDF.EDIT_FORMAT, "shape": "sphere", "op": "intersect", "blend": size * 0.15,
					"transform": {"position": [pos_b.x, pos_b.y, pos_b.z], "scale": 1.0, "rotation": rot},
					"params": {"radius": r}, "material": {},
				},
			]
		_:  # SHAPE_CIRCLE (and any unrecognized fallback)
			var pos := transform.origin - transform.basis.z * carve_depth
			return [{
				"format": SDF.EDIT_FORMAT, "shape": "sphere", "op": "subtract", "blend": 0.0,
				"transform": {"position": [pos.x, pos.y, pos.z], "scale": 1.0, "rotation": rot},
				"params": {"radius": size}, "material": {},
			}]


# ── Footprint boundary + carved-pocket / through-passage meshes (direct parametric geometry, ─────
# ── same house style as ring_scaffold.gd's build_wedge_mesh -- no CSG boolean, no SDF voxelization)

## Local-2D (right, up) boundary points of `shape`'s footprint, `segments` points, CCW.
static func _footprint_points(shape: String, size: float, segments: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	match shape:
		SHAPE_ELLIPSE:
			for i in segments:
				var t := TAU * float(i) / float(segments)
				pts.append(Vector2(cos(t) * size, sin(t) * size * 0.6))
		SHAPE_EYE:
			pts = _eye_boundary(size, segments)
		_:  # circle
			for i in segments:
				var t := TAU * float(i) / float(segments)
				pts.append(Vector2(cos(t) * size, sin(t) * size))
	return pts

## Exact vesica-piscis (lens/almond) boundary: intersection of two circles of radius `r = size*0.75`
## centred at (∓d/2, 0), d = r*1.1 (chosen to guarantee overlap). Standard construction: the
## half-angle subtended at each circle's own centre by the two intersection points is
## `alpha = acos((d/2)/r)`; circle A's (left, at -d/2) arc from -alpha..alpha is the RIGHT bulge,
## circle B's (right, at +d/2) arc from (PI-alpha)..(PI+alpha) is the LEFT bulge -- concatenated,
## a closed CCW loop.
static func _eye_boundary(size: float, segments: int) -> PackedVector2Array:
	var r := size * 0.75
	var d := r * 1.1
	var alpha: float = acos(clampf((d * 0.5) / r, -1.0, 1.0))
	var half_n: int = maxi(3, segments / 2)
	var pts := PackedVector2Array()
	for i in half_n:
		var t: float = lerpf(-alpha, alpha, float(i) / float(half_n - 1))
		pts.append(Vector2(-d * 0.5 + cos(t) * r, sin(t) * r))
	for i in half_n:
		var t: float = lerpf(PI - alpha, PI + alpha, float(i) / float(half_n - 1))
		pts.append(Vector2(d * 0.5 + cos(t) * r, sin(t) * r))
	return pts

## Shallow closed pocket: an outer rim (on the wall surface, at `transform`) connected by side
## walls to an inner rim (offset `carve_depth` along -Z, scaled 0.85x -- a slight inward taper),
## closed with a flat back cap. Faces oriented outward (toward the corridor interior / +Z).
static func _niche_mesh(transform: Transform3D, shape: String, size: float, carve_depth: float,
		segments: int) -> Mesh:
	var footprint := _footprint_points(shape, size, segments)
	var n := footprint.size()
	if n < 3:
		return null
	var outer: Array = []
	var inner: Array = []
	for p in footprint:
		outer.append(transform * Vector3(p.x, p.y, 0.0))
		var local_inner := Vector3(p.x * 0.85, p.y * 0.85, -carve_depth)
		inner.append(transform * local_inner)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n:
		var j := (i + 1) % n
		_tri(st, outer[i], inner[i], inner[j])
		_tri(st, outer[i], inner[j], outer[j])
	var centroid := Vector3.ZERO
	for v in inner:
		centroid += v
	centroid /= float(n)
	for i in n:
		var j := (i + 1) % n
		_tri(st, inner[j], inner[i], centroid)
	st.generate_normals()
	return st.commit()

## Open lofted passage between `near_transform` and `far_transform`'s SAME footprint (index-matched
## rim-to-rim quads, no caps) -- the connect_adjacent through-opening between two hallway rings.
static func _through_mesh(near_transform: Transform3D, far_transform: Transform3D, shape: String,
		size: float, segments: int) -> Mesh:
	var footprint := _footprint_points(shape, size, segments)
	var n := footprint.size()
	if n < 3:
		return null
	var near_ring: Array = []
	var far_ring: Array = []
	for p in footprint:
		near_ring.append(near_transform * Vector3(p.x, p.y, 0.0))
		far_ring.append(far_transform * Vector3(p.x, p.y, 0.0))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in n:
		var j := (i + 1) % n
		_tri(st, near_ring[i], far_ring[i], far_ring[j])
		_tri(st, near_ring[i], far_ring[j], near_ring[j])
	st.generate_normals()
	return st.commit()

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
