class_name BrickWallGenerator
extends RefCounted
## BrickWallGenerator -- the brick-wall-generator-2026-07-16 lane's realism deliverable
## (DQ-e732faee, `brick_street_scene_plan` node 4). The facade generator the
## brick-street-realism-2026-07-16 lane (`BrickPavementGenerator`, PR #206) explicitly left unbuilt
## (that lane only shipped the street SURFACE). Replaces `StreetGridScaffold.lot_box_mesh`'s flat
## placeholder box with REAL coursed brick walls -- running/common/Flemish bond (physical-seed
## selectable, zero code change to swap), header courses, soldier-course lintels + rowlock-course
## sills around window/door openings, and toothed corner treatment. `StreetGridScaffold`
## (`building_footprints`, UNCHANGED, RE #202/#203) remains the upstream producer of the Rect2
## footprints this node builds walls around.
##
## REAL-WORLD RESEARCH (notes/research/brick_street_construction_methods_2026_07_16.md sec8, Wavelet
## repo -- extends the 07-14 plan's sec2.3 running-bond/arch-type research with facade coursing this
## lane's scope actually needs: common bond, Flemish bond, header courses, lintels/sills, corner
## toothing -- sourced from Brick Industry Association Technical Notes 10/30, Archtoolbox,
## BrickNBolt, Britannica, IDS-DMV, Bautsystem):
##   - Common (American) bond: a header course every 5-6 courses among running-bond stretchers.
##   - Flemish bond: header+stretcher alternate WITHIN every course, denser interlock.
##   - Modular brick nominal 8in x 2-5/8in x 4in (length x course-height x header-width), a strict
##     2:1 length:header-width ratio -- `header_width = brick_length / 2` is a DERIVED constant, not
##     a second free param (same "don't invent an unresearched independent degree of freedom"
##     invariant `BrickPavementGenerator` already established for its own paver_length/paver_width).
##   - Standard WALL mortar joint = 3/8in (9.5mm) -- genuinely different from the pavement's
##     sand-set joint (1/16-3/16in): different construction system, different real number.
##   - Soldier course (bricks on end, narrow face out) is the real lintel method over an opening;
##     rowlock course (bricks on their long edge) is the real sloped-sill method under a window.
##   - Corner toothing/quoining: real masonry alternates, per course, which of two intersecting walls
##     extends flush to the corner vs. insets by one header-depth, so the wythes interlock.
##
## PHYSICAL SEED (same mechanism as `BrickPavementGenerator`; design:
## notes/planning/physical_seed_procgen_design_2026_07_16.md, Wavelet repo): this node contains ZERO
## bond-pattern-specific offset math. `PhysicalSeedReader` reads a wall exemplar (a JSON unit-cell,
## OR a hand-arranged `.tscn` -- "logical blocks as physical objects" made literal) in the WALL'S OWN
## 2D UV plane (u=along-wall, v=up-wall -- the reader's existing (position.x, position.z) convention
## is reused unmodified; a `.tscn` seed physically represents the wall's elevation pattern laid flat
## on a table, X=along-wall, Z=up-wall) and this generator does nothing but tile that lattice across
## each wall face (`_stamp_wall_lattice`, format-blind, mirrors `BrickPavementGenerator._stamp_lattice`
## structurally). Swapping `seed_handle` between the running/common/Flemish JSON exemplars or the
## `stack_bond_wall_exemplar.tscn` changes the coursing with ZERO code changes -- the same concrete,
## testable proof of the physical-seed principle `BrickPavementGenerator` already established.
##
## `rotation_deg` REINTERPRETATION (documented, research doc sec8.6): `PhysicalSeedReader`'s
## `rotation_deg` field is domain-generic -- the reader itself never rotates anything, a caller
## decides what the number means. For the pavement domain it is a literal in-plane rotation. For
## THIS wall domain, `rotation_deg` is reinterpreted as a discrete ORIENTATION CODE, because a header
## brick is NOT a stretcher rotated 90 degrees in-plane -- it exposes a DIFFERENT FACE of the same 3D
## unit (its actual end, not its side, and it protrudes DEEPER into the wall -- the real structural
## reason header courses exist, tying wythes together):
##   ORIENT_STRETCHER (0)   -- exposed face brick_length(u) x course_height(v), depth=header_width
##   ORIENT_HEADER    (90)  -- exposed face header_width(u) x course_height(v), depth=brick_length
## Two further orientation codes are GENERATOR-INTERNAL (never appear in a seed file -- they are
## local opening geometry, not tiled field coursing):
##   ORIENT_SOLDIER   (180) -- lintel: exposed face header_width(u) x brick_length(v, standing tall)
##   ORIENT_ROWLOCK    (270) -- sill: exposed face brick_length(u) x header_width(v), projects outward
##
## `.tscn` BACKEND LIMITATION (disclosed, research doc sec8.6): `PhysicalSeedReader.read_scene_tscn`
## always INFERS its lattice from the member bounding box (no explicit-lattice override, unlike the
## JSON backend) -- a strictly-one-brick-per-cell periodic bond cannot be represented via 2
## non-degenerate points without the inferred lattice reproducing one point as an exact positional
## duplicate of the other. This generator handles that GENERICALLY by deduplicating near-identical
## stamped transforms before instancing (`_dedupe_transforms`) -- a real robustness feature for any
## seed source, not a workaround specific to one exemplar.
##
## free_params (matches the corpus's `{type,min,max,default}` convention, `library/README.md`):
##   seed_handle          {type:enum, options:[res://assets/wall_exemplars/running_bond_wall.json,
##                          res://assets/wall_exemplars/common_bond_wall.json,
##                          res://assets/wall_exemplars/flemish_bond_wall.json,
##                          res://assets/wall_exemplars/stack_bond_wall_exemplar.tscn], default:running}
##   seed                 {type:int,   min:0,    max:2^31, default:1}    (per-brick weathering jitter)
##   mortar_gap           {type:float, min:0.0,  max:0.02, default:0.0095}  (3/8in wall joint, research sec8.2)
##   row_count             {type:int,   min:1,    max:8,    default:3}    (window/floor rows)
##   window_width          {type:float, min:0.5,  max:2.5,  default:1.1}
##   window_height         {type:float, min:0.6,  max:2.8,  default:1.6}
##   window_spacing        {type:float, min:0.3,  max:4.0,  default:1.5}  (evenly-spaced facade rhythm)
##   sill_height_above_floor {type:float, min:0.3, max:1.5, default:0.9}
##   ground_floor_door      {type:bool,  default:true}
##   door_width             {type:float, min:0.7, max:1.8,  default:1.0}
##   door_height            {type:float, min:1.8, max:2.6,  default:2.1}
##   lintel_overhang        {type:float, min:0.0, max:0.3,  default:0.1}
##   sill_projection        {type:float, min:0.0, max:0.1,  default:0.02}
##   brick_color            {type:color, default:"#8c3829"} (simple red clay brick, matches
##                            BrickPavementGenerator's BRICK_COLOR_BASE for cross-scene consistency)
##   arch_seed_handle       {type:enum, options:[none, res://assets/arch_exemplars/segmental_arch.json,
##                            res://assets/arch_exemplars/semicircular_arch.json],
##                            default:semicircular} (DQ-b415f577 -- see BrickArchGenerator docstring)
## `wall_height` is a direct build() argument (like BrickPavementGenerator's `base_y`), not a
## free_param dict entry -- it is scene-scale geometry the caller derives per lot, not a per-brick
## tunable. `header_width` and `corner_inset` are DERIVED (brick_length/2), not separate free params
## -- per Liam's own spec: "if you have any free variables, constrain them using physical realism."
##
## NO REDUNDANT `bond_pattern` ENUM: the 07-14 plan's original node-4 draft proposed a separate
## `bond_pattern: enum[running,stack,flemish]` param. The NEWER 2026-07-16 physical-seed spec
## supersedes that on this exact point -- `BrickPavementGenerator` already demonstrates bond choice
## belongs ENTIRELY in `seed_handle`, not a second parallel enum (goal > spec-letter when they
## diverge, per the standing quality/pushback instruction). This generator follows the same,
## newer-and-more-specific convention.
##
## ARCHED OPENINGS (DQ-b415f577, EXTENDS this file -- new module wired alongside, no primitive
## rewrite): `arch_seed_handle` selects a REAL, researched arch type via
## `godot/assets/arch_exemplars/*.json` (same physical-seed, no-redundant-enum principle as
## `seed_handle` above -- `BrickArchGenerator`'s own docstring covers the geometry/research). `"none"`
## preserves the prior flat-lintel-only behavior (the brick-wall-generator-2026-07-16 lane's shipped
## default) with zero change. When an opening is arched, `BrickWallGenerator` calls
## `BrickArchGenerator.build_voussoirs()` instead of `_append_lintel()`, merges the returned
## voussoir/keystone transforms into this file's own `groups` dict (same MultiMesh-per-orientation-key
## convention, just two new orientation codes), and excludes ordinary field coursing from the arch
## ring's disk footprint (`_in_any_opening`, extended) rather than the opening's old flat rectangular
## bounding box -- so the spandrel corners between the round arch and that old bounding box are left
## for ordinary running-bond field coursing to fill naturally, exactly as real spandrel brickwork does.

const DEFAULT_SEED_HANDLE := "res://assets/wall_exemplars/running_bond_wall.json"
const DEFAULT_ARCH_SEED_HANDLE := "res://assets/arch_exemplars/semicircular_arch.json"
const DEFAULT_SEED := 1
const DEFAULT_MORTAR_GAP := 0.0095
const DEFAULT_ROW_COUNT := 3
const DEFAULT_WINDOW_WIDTH := 1.1
const DEFAULT_WINDOW_HEIGHT := 1.6
const DEFAULT_WINDOW_SPACING := 1.5
const DEFAULT_SILL_HEIGHT_ABOVE_FLOOR := 0.9
const DEFAULT_GROUND_FLOOR_DOOR := true
const DEFAULT_DOOR_WIDTH := 1.0
const DEFAULT_DOOR_HEIGHT := 2.1
const DEFAULT_LINTEL_OVERHANG := 0.1
const DEFAULT_SILL_PROJECTION := 0.02

const BRICK_COLOR_BASE := Color(0.55, 0.22, 0.16)  # same red clay brick as BrickPavementGenerator

const ORIENT_STRETCHER := 0
const ORIENT_HEADER := 90
const ORIENT_SOLDIER := 180
const ORIENT_ROWLOCK := 270
const ORIENT_QUOIN_LONG_X := 400  # additive corner post block, long arm along world X
const ORIENT_QUOIN_LONG_Z := 401  # additive corner post block, long arm along world Z

const MAX_BRICKS_PER_WALL := 20000  # guard, never hang -- matches this corpus's fail-open posture
const DEDUPE_EPS := 1e-4


## Build one building's full brick-wall envelope over `footprint` (world-space XZ Rect2, matches
## StreetGridScaffold.building_footprints' own {"rect": Rect2, ...} convention), `wall_height` = total
## facade height (row_count evenly divides it into floors), `base_y` = the ground Y the walls sit on.
## Returns:
##   {
##     "brick_groups": Array of {"mesh": BoxMesh, "transforms": Array[Transform3D], "color": Color,
##                                 "orientation": int}   -- one entry per orientation actually used
##                                (MultiMesh-ready PER GROUP -- see wall_multimeshes()),
##     "openings": Array of {"rect": Rect2 (wall-local u/v, per wall), "wall_index": int, "type": String,
##                            "arch": Dictionary_or_null (BrickArchGenerator.arch_geometry() result,
##                             DQ-b415f577 -- non-null only when arch_seed_handle != "none")},
##     "header_width": float (the derived wall-thickness constant this build actually used -- exposed
##                              so a caller like PanedGlassPanel, DQ-84d20364, can fit a glass reveal
##                              depth to the real wall thickness instead of re-deriving/guessing it),
##   }
static func build(footprint: Rect2, wall_height: float, params: Dictionary = {}, base_y: float = 0.0) -> Dictionary:
	var seed_handle: String = params.get("seed_handle", DEFAULT_SEED_HANDLE)
	var arch_seed_handle: String = params.get("arch_seed_handle", DEFAULT_ARCH_SEED_HANDLE)
	var jitter_seed: int = int(params.get("seed", DEFAULT_SEED))
	var mortar_gap: float = maxf(0.0, float(params.get("mortar_gap", DEFAULT_MORTAR_GAP)))
	var row_count: int = maxi(1, int(params.get("row_count", DEFAULT_ROW_COUNT)))
	var window_width: float = maxf(0.05, float(params.get("window_width", DEFAULT_WINDOW_WIDTH)))
	var window_height: float = maxf(0.05, float(params.get("window_height", DEFAULT_WINDOW_HEIGHT)))
	var window_spacing: float = maxf(0.05, float(params.get("window_spacing", DEFAULT_WINDOW_SPACING)))
	var sill_height_above_floor: float = maxf(0.0, float(params.get("sill_height_above_floor", DEFAULT_SILL_HEIGHT_ABOVE_FLOOR)))
	var ground_floor_door: bool = bool(params.get("ground_floor_door", DEFAULT_GROUND_FLOOR_DOOR))
	var door_width: float = maxf(0.05, float(params.get("door_width", DEFAULT_DOOR_WIDTH)))
	var door_height: float = maxf(0.05, float(params.get("door_height", DEFAULT_DOOR_HEIGHT)))
	var lintel_overhang: float = maxf(0.0, float(params.get("lintel_overhang", DEFAULT_LINTEL_OVERHANG)))
	var sill_projection: float = maxf(0.0, float(params.get("sill_projection", DEFAULT_SILL_PROJECTION)))
	var brick_color: Color = params.get("brick_color", BRICK_COLOR_BASE)
	wall_height = maxf(0.2, wall_height)

	var seed_data := PhysicalSeedReader.read(seed_handle)
	var brick_length: float = maxf(0.02, float(seed_data.get("brick_length", 0.2)))
	var course_height: float = maxf(0.01, float(seed_data.get("brick_width", 0.067)))
	var header_width: float = brick_length * 0.5  # derived, real 2:1 ratio (research sec8.2)

	# DQ-b415f577: arch style + rise/voussoir-count/keystone are ENTIRELY seed-file data (no parallel
	# free_param enum -- same "no redundant enum" precedent this file's own docstring already
	# established for bond_pattern vs. seed_handle).
	var arch_seed_data := BrickArchGenerator.read_arch_seed(arch_seed_handle)
	var arch_style: String = String(arch_seed_data.get("style", "none"))
	var arch_rise_ratio: float = float(arch_seed_data.get("rise_ratio", 0.25))
	var voussoir_count: int = int(arch_seed_data.get("voussoir_count", 7))
	var keystone_enabled: bool = bool(arch_seed_data.get("keystone_enabled", true))

	var walls := _walls_from_footprint(footprint)
	var openings_all: Array = []
	# grouped placements, keyed by orientation int -> Array[Transform3D]
	var groups: Dictionary = {}

	for wi in walls.size():
		var w: Dictionary = walls[wi]
		var wall_length: float = w["length"]
		if wall_length <= header_width * 2.0:
			continue  # too short to carry any real coursing -- guard, skip rather than crash

		var wall_openings := _layout_openings(wall_length, wall_height, row_count, window_width,
			window_height, window_spacing, sill_height_above_floor,
			ground_floor_door and wi == 0, door_width, door_height)

		# DQ-b415f577: compute each opening's arch geometry (if any) AND place its voussoir/keystone
		# bricks BEFORE the field-coursing stamp loop below -- the field-exclusion test
		# (_in_any_opening) needs each opening's "arch" key populated to know the ring's disk footprint.
		for o in wall_openings:
			o["arch"] = null
			if arch_style == "none":
				continue
			var arch := BrickArchGenerator.arch_geometry(o["rect"], arch_style, arch_rise_ratio)
			if arch.get("style", "none") == "none":
				continue
			var vresult := BrickArchGenerator.build_voussoirs(w, arch, brick_length, header_width,
				voussoir_count, keystone_enabled)
			arch["extrados_radius"] = float(vresult.get("extrados_radius", arch["radius"]))
			_merge_transforms(groups, BrickArchGenerator.ORIENT_VOUSSOIR, vresult["voussoirs"])
			if vresult["keystone"] != null:
				_merge_transforms(groups, BrickArchGenerator.ORIENT_KEYSTONE, [vresult["keystone"]])
			o["arch"] = arch

		for o in wall_openings:
			openings_all.append({"rect": o["rect"], "wall_index": wi, "type": o["type"], "arch": o["arch"]})

		# Field coursing runs FULL LENGTH, flush to both corners (no exclusion) -- an earlier design
		# tried per-course corner INSET/exclusion (real toothing's textbook description) but that
		# creates a genuine, render-verified GAP: two independent per-wall 1D coursing loops in
		# PERPENDICULAR planes do not automatically close a hole left in one wall's own plane just
		# because the other wall has depth (found via an actual --milestone-shot render, single-lot
		## corner close-up, adversarial-iteration pass, this lane). Corner interlock is instead
		# provided by a genuine, ADDITIVE quoin corner post (_append_quoin_corners, below) -- real
		# alternating long/short quoin blocks (research sec8.4) that can only ever ADD geometry, so
		# they cannot re-introduce a gap the way exclusion did.
		var field := _stamp_wall_lattice(seed_data, wall_length, wall_height, brick_length, header_width, course_height)
		for cand in field:
			var u: float = cand["u"]
			var v: float = cand["v"]
			var orient: int = cand["orient"]
			if _in_any_opening(u, v, wall_openings, header_width * 0.5):
				continue
			_append_placement(groups, orient, w, u, v, brick_length, header_width, course_height, mortar_gap, jitter_seed)

		for o in wall_openings:
			var orect: Rect2 = o["rect"]
			# DQ-b415f577: an arched opening's OWN voussoir ring is the real spanning member (already
			# placed above) -- a flat soldier-course lintel on top of a round arch is not real masonry,
			# so skip it precisely when this opening got an arch (o["arch"] set above).
			if o["arch"] == null:
				_append_lintel(groups, w, orect, header_width, brick_length, course_height, lintel_overhang, mortar_gap)
			if o["type"] == "window":
				_append_sill(groups, w, orect, header_width, brick_length, course_height, sill_projection, mortar_gap)

	_append_quoin_corners(groups, footprint, wall_height, brick_length, header_width, course_height, mortar_gap)

	var brick_groups: Array = []
	for orient_key in groups.keys():
		var transforms: Array = _dedupe_transforms(groups[orient_key])
		if transforms.is_empty():
			continue
		var extents := _extents_for_orientation(int(orient_key), brick_length, header_width, course_height)
		var is_quoin: bool = int(orient_key) == ORIENT_QUOIN_LONG_X or int(orient_key) == ORIENT_QUOIN_LONG_Z
		var z_size: float = maxf(0.005, extents.z - mortar_gap) if is_quoin else maxf(0.005, extents.z)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(maxf(0.005, extents.x - mortar_gap), maxf(0.005, extents.y - mortar_gap), z_size)
		brick_groups.append({"mesh": mesh, "transforms": transforms, "color": brick_color, "orientation": int(orient_key)})

	return {"brick_groups": brick_groups, "openings": openings_all, "header_width": header_width}


## Public wrapper over `_walls_from_footprint` -- a pure function of `footprint` alone (no seed/param
## dependency), so an external caller (e.g. `brick_street_pavement_proof.gd` wiring `PanedGlassPanel`,
## DQ-84d20364) can recover the SAME per-wall {"origin","tangent","normal","length"} dicts `build()`
## used internally for a given `openings[i]["wall_index"]`, without reaching into a private helper.
static func walls_from_footprint(footprint: Rect2) -> Array:
	return _walls_from_footprint(footprint)


## Merge `transforms` into `groups[orient]`, creating the bucket if needed -- the same
## MultiMesh-per-orientation-key convention every other `_append_*` helper in this file already uses,
## factored out because BrickArchGenerator (DQ-b415f577) returns its placements as pure data (module
## docstring) rather than writing into this file's `groups` dict directly.
static func _merge_transforms(groups: Dictionary, orient: int, transforms: Array) -> void:
	if transforms.is_empty():
		return
	if not groups.has(orient):
		groups[orient] = []
	for t in transforms:
		(groups[orient] as Array).append(t)


## Four wall segments tracing `footprint`'s perimeter (world-space XZ), in a consistent winding order
## (N, E, S, W) -- each entry: {"origin": Vector3 (start, y=0 local), "tangent": Vector3 (unit, along
## the wall), "normal": Vector3 (unit, outward), "length": float}.
static func _walls_from_footprint(footprint: Rect2) -> Array:
	var p0 := footprint.position
	var p1 := footprint.position + Vector2(footprint.size.x, 0.0)
	var p2 := footprint.position + footprint.size
	var p3 := footprint.position + Vector2(0.0, footprint.size.y)
	var corners := [p0, p1, p2, p3]
	var walls: Array = []
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var seg := b - a
		var length := seg.length()
		if length < 1e-6:
			continue
		var tangent2 := seg / length
		var tangent := Vector3(tangent2.x, 0.0, tangent2.y)
		var normal := Vector3(tangent2.y, 0.0, -tangent2.x)  # rotate -90deg in XZ -> points outward for CW winding
		walls.append({
			"origin": Vector3(a.x, 0.0, a.y),
			"tangent": tangent,
			"normal": normal,
			"length": length,
		})
	return walls


## Evenly-spaced window/door opening layout along one wall (plan's "evenly-spaced windows... matching
## the reference's facade rhythm"). Returns Array of {"rect": Rect2(u,v,w,h), "type": "window"|"door"}.
static func _layout_openings(wall_length: float, wall_height: float, row_count: int, window_width: float,
		window_height: float, window_spacing: float, sill_height_above_floor: float,
		allow_door: bool, door_width: float, door_height: float) -> Array:
	var floor_height: float = wall_height / float(row_count)
	var pitch: float = window_width + window_spacing
	var n_cols: int = int(floor((wall_length + window_spacing) / pitch)) if pitch > 1e-6 else 0
	n_cols = maxi(0, n_cols)
	if n_cols == 0:
		return []
	var total_span: float = n_cols * window_width + (n_cols - 1) * window_spacing
	var margin: float = maxf(0.0, (wall_length - total_span) * 0.5)

	var out: Array = []
	for r in row_count:
		var floor_base: float = float(r) * floor_height
		for c in n_cols:
			var u0: float = margin + float(c) * pitch
			if r == 0 and c == 0 and allow_door:
				var door_v_top: float = minf(door_height, floor_height - 0.05)
				out.append({"rect": Rect2(u0, floor_base, door_width, maxf(0.2, door_v_top)), "type": "door"})
				continue
			var v0: float = floor_base + sill_height_above_floor
			var v_top: float = floor_base + floor_height - 0.05
			var h: float = clampf(window_height, 0.1, maxf(0.1, v_top - v0))
			if v0 + h > wall_height:
				continue
			out.append({"rect": Rect2(u0, v0, window_width, h), "type": "window"})
	return out


## DQ-b415f577: arch-aware exclusion. For an opening with a non-null "arch" entry, field coursing is
## excluded from the union of (the JAMB rect, below the springing line) and (a DISK of radius
## `extrados_radius` centered on the arch, above the springing line) -- NOT the opening's old flat
## rectangular bounding box. This deliberately leaves the SPANDREL corners (between the round arch's
## outer curve and that old bounding box) unexcluded, so ordinary running-bond field coursing keeps
## filling them, exactly as real spandrel brickwork does (BrickArchGenerator's own module docstring
## covers the reasoning). A plain (non-arch) opening keeps the original flat-rect test, unchanged.
static func _in_any_opening(u: float, v: float, openings: Array, margin: float) -> bool:
	for o in openings:
		var r: Rect2 = o["rect"]
		var arch = o.get("arch")
		if arch != null and typeof(arch) == TYPE_DICTIONARY and arch.get("style", "none") != "none":
			var springing_v: float = arch["springing_v"]
			if v < springing_v:
				var jamb := Rect2(r.position, Vector2(r.size.x, springing_v - r.position.y))
				if jamb.grow(margin).has_point(Vector2(u, v)):
					return true
			else:
				var extrados: float = float(arch.get("extrados_radius", arch["radius"]))
				var d := Vector2(u - float(arch["center_u"]), v - float(arch["center_v"])).length()
				if d <= extrados + margin:
					return true
			continue
		var expanded := r.grow(margin)
		if expanded.has_point(Vector2(u, v)):
			return true
	return false


## Real quoin corner treatment (research sec8.4: toothing/quoining -- alternating LONG/SHORT blocks
## at a corner for visual + interlocking distinction), rebuilt ADDITIVE after the exclusion-based
## attempt above was found (by an actual render, not just review) to leave a full-height gap: two
## independent per-wall coursing loops in perpendicular planes do not close a hole left by one wall
## just because the other wall has physical depth. A quoin post instead stacks its OWN dedicated
## blocks directly at each of the 4 footprint corners, alternating per-course which world axis gets
## the long arm (brick_length) vs. the short arm (header_width) -- the classic long-short quoin
## silhouette -- and can only ever ADD geometry on top of the already-solid, flush field coursing, so
## it cannot reintroduce a gap. `ORIENT_QUOIN_LONG_X`/`ORIENT_QUOIN_LONG_Z` name which world axis is
## long on a given block (footprints are always axis-aligned, so a quoin's long arm is always along
## either world X or world Z -- no rotation math needed, unlike the wall-tangent-relative placements
## above).
static func _append_quoin_corners(groups: Dictionary, footprint: Rect2, wall_height: float,
		brick_length: float, header_width: float, course_height: float, mortar_gap: float) -> void:
	var corners: Array = [footprint.position, footprint.position + Vector2(footprint.size.x, 0.0),
		footprint.position + footprint.size, footprint.position + Vector2(0.0, footprint.size.y)]
	var n_courses: int = int(ceil(wall_height / course_height))
	for ci in corners.size():
		var corner: Vector2 = corners[ci]
		for k in n_courses:
			var v: float = float(k) * course_height + course_height * 0.5
			if v > wall_height:
				break
			var long_on_x: bool = (k + ci) % 2 == 0
			var orient: int = ORIENT_QUOIN_LONG_X if long_on_x else ORIENT_QUOIN_LONG_Z
			var origin := Vector3(corner.x, v, corner.y)
			if not groups.has(orient):
				groups[orient] = []
			(groups[orient] as Array).append(Transform3D(Basis.IDENTITY, origin))


## Generic, format-blind lattice tiling in the wall's own (u, v) plane -- structurally mirrors
## BrickPavementGenerator._stamp_lattice (stamp every integer lattice combination whose footprint
## could overlap the wall rect, in rect-local space), just consuming a vertical wall UV rect instead
## of a ground-plane street rect. Interprets each member's rotation_deg per this generator's own
## ORIENT_* reinterpretation (0=stretcher, 90=header -- the only two codes a seed file ever declares).
static func _stamp_wall_lattice(seed_data: Dictionary, wall_length: float, wall_height: float,
		brick_length: float, header_width: float, course_height: float) -> Array:
	var members: Array = seed_data.get("members", [])
	var lattice_a: Vector2 = seed_data.get("lattice_a", Vector2.ZERO)
	var lattice_b: Vector2 = seed_data.get("lattice_b", Vector2.ZERO)
	if members.is_empty() or lattice_a.length() < 1e-6 or lattice_b.length() < 1e-6:
		return []

	var out: Array = []
	var diag := Vector2(wall_length, wall_height).length()
	var span_a: int = mini(int(ceil(diag / maxf(0.01, lattice_a.length()))) + 2, 2048)
	var span_b: int = mini(int(ceil(diag / maxf(0.01, lattice_b.length()))) + 2, 2048)

	var margin := maxf(brick_length, course_height)
	for i in range(-span_a, span_a + 1):
		for j in range(-span_b, span_b + 1):
			var base := float(i) * lattice_a + float(j) * lattice_b
			for m in members:
				var offset: Vector2 = m["offset"]
				var world := base + offset
				# Snap to a fixed grid BEFORE any downstream use: two nominally-identical stamped
				# positions reached via different (i,j) paths (e.g. the .tscn backend's inference
				# limitation, research doc sec8.6) can differ by sub-ULP floating noise depending on
				# summation order, which would otherwise desync the jitter hash below AND the
				# dedup key in _dedupe_transforms for what is mathematically the exact same brick.
				world.x = snappedf(world.x, 0.00001)
				world.y = snappedf(world.y, 0.00001)
				if world.x < -margin or world.x > wall_length + margin:
					continue
				if world.y < -margin or world.y > wall_height + margin:
					continue
				if world.x < 0.0 or world.x > wall_length or world.y < 0.0 or world.y > wall_height:
					continue
				var orient: int = ORIENT_HEADER if int(m["rotation_deg"]) % 180 == 90 else ORIENT_STRETCHER
				out.append({"u": world.x, "v": world.y, "orient": orient})
				if out.size() > MAX_BRICKS_PER_WALL:
					return out
	return out


## (u,v,orient) x wall-frame -> a world Transform3D appended into groups[orient], with a small
## per-brick weathering jitter (deterministic, hash-seeded, mirrors BrickPavementGenerator's own
## sub-mm placement jitter convention).
static func _append_placement(groups: Dictionary, orient: int, wall: Dictionary, u: float, v: float,
		brick_length: float, header_width: float, course_height: float, mortar_gap: float, jitter_seed: int) -> void:
	var extents := _extents_for_orientation(orient, brick_length, header_width, course_height)
	var depth_center: float = extents.z * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([jitter_seed, int(u * 10000.0), int(v * 10000.0), orient])
	var jitter: float = rng.randf_range(-0.0005, 0.0005)
	var origin: Vector3 = wall["origin"] + (wall["tangent"] as Vector3) * u + Vector3.UP * (v + jitter) \
		+ (wall["normal"] as Vector3) * depth_center
	var basis := Basis(wall["tangent"], Vector3.UP, wall["normal"])
	if not groups.has(orient):
		groups[orient] = []
	(groups[orient] as Array).append(Transform3D(basis, origin))


## Soldier-course lintel spanning `opening.rect` (research sec8.3), pitched at header_width, centered
## on the opening top plus `lintel_overhang` on each side.
static func _append_lintel(groups: Dictionary, wall: Dictionary, opening: Rect2, header_width: float,
		brick_length: float, course_height: float, lintel_overhang: float, mortar_gap: float) -> void:
	var u0: float = opening.position.x - lintel_overhang
	var span: float = opening.size.x + lintel_overhang * 2.0
	var count: int = maxi(1, int(ceil(span / header_width)))
	var v: float = opening.position.y + opening.size.y + brick_length * 0.5
	for c in count:
		var u: float = u0 + (float(c) + 0.5) * (span / float(count))
		_append_placement(groups, ORIENT_SOLDIER, wall, u, v, brick_length, header_width, course_height, mortar_gap, 0)


## Rowlock-course sill under `opening.rect` (window-type only, research sec8.3), pitched at
## brick_length, projecting `sill_projection` outward from the field wall plane for drainage.
static func _append_sill(groups: Dictionary, wall: Dictionary, opening: Rect2, header_width: float,
		brick_length: float, course_height: float, sill_projection: float, mortar_gap: float) -> void:
	var u0: float = opening.position.x
	var span: float = opening.size.x
	var count: int = maxi(1, int(ceil(span / brick_length)))
	var v: float = opening.position.y - header_width * 0.5
	var extents := _extents_for_orientation(ORIENT_ROWLOCK, brick_length, header_width, course_height)
	var projected_wall := {
		"origin": (wall["origin"] as Vector3) + (wall["normal"] as Vector3) * sill_projection,
		"tangent": wall["tangent"],
		"normal": wall["normal"],
	}
	for c in count:
		var u: float = u0 + (float(c) + 0.5) * (span / float(count))
		_append_placement(groups, ORIENT_ROWLOCK, projected_wall, u, v, brick_length, header_width, course_height, mortar_gap, 0)


## Exposed (u,v) face dims + depth-into-wall, per orientation code (research sec8.3/8.4 -- each
## orientation is a genuinely different exposed FACE of the same physical brick, not a rescaled box).
static func _extents_for_orientation(orient: int, brick_length: float, header_width: float, course_height: float) -> Vector3:
	match orient:
		ORIENT_HEADER:
			return Vector3(header_width, course_height, brick_length)   # ties through -- deeper
		ORIENT_SOLDIER:
			return Vector3(header_width, brick_length, header_width)    # standing on end
		ORIENT_ROWLOCK:
			return Vector3(brick_length, header_width, course_height)   # on its long edge
		ORIENT_QUOIN_LONG_X:
			return Vector3(brick_length, course_height, header_width)   # additive corner post, long arm on X
		ORIENT_QUOIN_LONG_Z:
			return Vector3(header_width, course_height, brick_length)   # additive corner post, long arm on Z
		BrickArchGenerator.ORIENT_VOUSSOIR:
			return BrickArchGenerator.voussoir_extents(brick_length, header_width)
		BrickArchGenerator.ORIENT_KEYSTONE:
			return BrickArchGenerator.keystone_extents(brick_length, header_width)
		_:
			return Vector3(brick_length, course_height, header_width)   # ORIENT_STRETCHER


## Deduplicate near-identical transforms (position within DEDUPE_EPS) -- the generic robustness fix
## for the `.tscn` backend's bbox-inference limitation (research sec8.6): any seed source that
## produces two placements at (near-)the same world position collapses to one, rather than
## double-instancing coincident geometry.
static func _dedupe_transforms(transforms: Array) -> Array:
	var seen: Dictionary = {}
	var out: Array = []
	for t in transforms:
		var tr: Transform3D = t
		var key := "%d_%d_%d" % [
			int(round(tr.origin.x / DEDUPE_EPS)),
			int(round(tr.origin.y / DEDUPE_EPS)),
			int(round(tr.origin.z / DEDUPE_EPS)),
		]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(tr)
	return out


## Convenience: one MultiMeshInstance3D PER orientation group in a `build()` result (real GPU
## instancing, Truncate/LOD reuse intent, matching BrickPavementGenerator.paver_multimesh) -- multiple
## groups because each orientation is a genuinely differently-SIZED box, so one shared MultiMesh
## cannot represent all of them (MultiMesh requires one mesh per instance set).
static func wall_multimeshes(result: Dictionary) -> Array:
	var out: Array = []
	for group_v in (result["brick_groups"] as Array):
		var group: Dictionary = group_v
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = group["mesh"]
		var transforms: Array = group["transforms"]
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		var mat := StandardMaterial3D.new()
		mat.albedo_color = group.get("color", BRICK_COLOR_BASE)
		mat.roughness = 0.85
		mmi.material_override = mat
		out.append(mmi)
	return out
