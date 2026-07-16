class_name BrickPavementGenerator
extends RefCounted
## BrickPavementGenerator -- the brick-street lane's realism deliverable (Liam verbatim, Discord
## #dev, 2026-07-16T02:11:38Z, brick-street-realism-2026-07-16 claim): "make something that is
## genuinely real and physical by coding in the construction or assembly method as procedural
## generation." Replaces the prior placeholder (Kenney's modern asphalt/concrete City Kit Roads,
## `KitGridPlacer`/`brick_street_real_kit_proof.gd`, PR #203) as the STREET SURFACE generator
## specifically -- `StreetGridScaffold`'s lot/street layout scaffold is UNCHANGED and still the
## upstream producer of the `street_polygon` rects this node consumes; `KitGridPlacer` remains the
## right tool for discrete kit-piece placement (lampposts, signs) elsewhere in the scene.
##
## REAL-WORLD LAYER STACK (research: notes/research/brick_street_construction_methods_2026_07_16.md,
## Wavelet repo, sourced from Brick Industry Association Tech Notes 14A/14C, Oregon State University
## Extension, historicalbricks.com's account of Mordecai Levi's 1870s brick-road patent method, and
## LA Bureau of Engineering's Complete Street Design Manual):
##   sub-grade (the scene's existing ground, not regenerated here)
##   -> aggregate base course (compacted crushed stone, historically "broken stone/slate/gravel")
##   -> binder layer (historic brick streets used a bituminous binder course under the sand bed --
##      modeled as its own thin slab, not merged into the bedding layer, so the stack is genuinely
##      inspectable)
##   -> bedding/sand layer (thin screeded sand -- lets pavers seat level)
##   -> paver course (real herringbone-by-default bond, see PHYSICAL SEED below)
##   -> curb + gutter pan along both long edges, for real cross-slope drainage
##
## PHYSICAL SEED (Liam's 2026-07-16 physical-seed principle; design:
## notes/planning/physical_seed_procgen_design_2026_07_16.md, Wavelet repo): this node contains ZERO
## pattern-specific offset math. `PhysicalSeedReader` (godot/tools/physical_seed_reader.gd) reads a
## small physical/data exemplar (a JSON unit-cell description, or an actual hand-arranged .tscn --
## "logical blocks as physical objects") and this generator does nothing but tile that exemplar's
## lattice across the target rect (`_stamp_lattice`, format-blind). Swapping `seed_handle` between
## `res://assets/paver_exemplars/herringbone_2brick.json` (default -- herringbone is the ONLY bond
## documented to resist vehicular shear, the correct choice for an actual trafficked street, per the
## research doc sec2) and `res://assets/paver_exemplars/running_bond_1brick.json` (pedestrian-area
## alternate, matching BrickWallGenerator's planned wall-facade bond) changes the paving pattern with
## ZERO code changes -- the concrete, testable proof the physical-seed principle holds.
##
## CROWNING (research sec5): a real Y-offset parabola across the street's SHORT axis (its "width" --
## `StreetGridScaffold`'s own street strips are always exactly `street_width` wide on ONE axis, so
## the shorter rect dimension IS the width axis by construction), peak at the centerline, zero at the
## curb line -- a genuine geometric feature (drives real per-paver Y placement), not a texture trick.
## Documented simplification: the base/binder/bedding SLABS beneath the pavers are rendered flat
## (only the paver course itself follows the crown curve) -- the visually-inspectable top surface is
## what's modeled; a future increment could crown the whole stack if ever needed.
##
## GUTTER (research sec5): pavers are simply not placed within `gutter_width` of either curb line --
## the exposed bedding-sand slab beneath reads as the smooth gutter pan real streets use there, with
## zero new geometry.
##
## free_params (matches the corpus's `{type,min,max,default}` convention, `library/README.md`):
##   seed_handle             {type:enum, options:[res://assets/paver_exemplars/herringbone_2brick.json,
##                             res://assets/paver_exemplars/running_bond_1brick.json], default:herringbone}
##   seed                    {type:int,   min:0,    max:2^31, default:1}   (per-paver weathering jitter)
##   mortar_gap              {type:float, min:0.0,  max:0.02, default:0.005}  (sand-set optimum, research sec3)
##   joint_mode              {type:enum,  options:[sand_set,mortar_set], default:sand_set}
##   crown_height            {type:float, min:0.0,  max:0.15, default:0.03}
##   curb_reveal_height      {type:float, min:0.0,  max:0.3,  default:0.12}
##   curb_width              {type:float, min:0.05, max:0.5,  default:0.15}
##   gutter_width            {type:float, min:0.0,  max:1.0,  default:0.3}
##   aggregate_base_thickness {type:float, min:0.05, max:0.3, default:0.15}  (research sec1: 4-6in)
##   binder_thickness        {type:float, min:0.0,  max:0.08, default:0.03}
##   bedding_thickness       {type:float, min:0.005,max:0.06, default:0.025} (research sec1: ~1in)
##   brick_thickness         {type:float, min:0.02, max:0.08, default:0.05} (research sec4: ~2-2.25in)

const DEFAULT_SEED_HANDLE := "res://assets/paver_exemplars/herringbone_2brick.json"
const DEFAULT_SEED := 1
const DEFAULT_MORTAR_GAP := 0.005
const DEFAULT_JOINT_MODE := "sand_set"
const DEFAULT_CROWN_HEIGHT := 0.03
const DEFAULT_CURB_REVEAL_HEIGHT := 0.12
const DEFAULT_CURB_WIDTH := 0.15
const DEFAULT_GUTTER_WIDTH := 0.3
const DEFAULT_AGGREGATE_BASE_THICKNESS := 0.15
const DEFAULT_BINDER_THICKNESS := 0.03
const DEFAULT_BEDDING_THICKNESS := 0.025
const DEFAULT_BRICK_THICKNESS := 0.05

const SAND_COLOR := Color(0.76, 0.68, 0.52)
const BINDER_COLOR := Color(0.1, 0.09, 0.08)
const BASE_COLOR := Color(0.42, 0.4, 0.37)
const CURB_COLOR := Color(0.55, 0.53, 0.5)
const MORTAR_COLOR := Color(0.62, 0.6, 0.56)
const BRICK_COLOR_BASE := Color(0.55, 0.22, 0.16)  # simple red clay brick, per plan precedent


## Build one street segment's real construction stack over `street_rect` (world-space XZ, matches
## StreetGridScaffold.street_polygon's own Rect2 convention), `base_y` = the ground/sub-grade Y this
## stack sits on top of. Returns:
##   {
##     "layers": Array of {"mesh": Mesh, "position": Vector3, "color": Color}  -- base/binder/bedding
##                slabs, bottom to top,
##     "curbs": Array of {"mesh": Mesh, "position": Vector3, "color": Color}   -- two long-edge curbs,
##     "paver_mesh": Mesh,                        -- ONE shared BoxMesh every paver instances (MultiMesh-ready,
##                                                    matches the plan's Truncate/LOD reuse intent),
##     "paver_transforms": Array[Transform3D],    -- real per-brick placements (herringbone by default),
##     "paver_color": Color,
##   }
static func build(street_rect: Rect2, params: Dictionary = {}, base_y: float = 0.0) -> Dictionary:
	var seed_handle: String = params.get("seed_handle", DEFAULT_SEED_HANDLE)
	var jitter_seed: int = int(params.get("seed", DEFAULT_SEED))
	var mortar_gap: float = maxf(0.0, float(params.get("mortar_gap", DEFAULT_MORTAR_GAP)))
	var joint_mode: String = params.get("joint_mode", DEFAULT_JOINT_MODE)
	var crown_height: float = maxf(0.0, float(params.get("crown_height", DEFAULT_CROWN_HEIGHT)))
	var curb_reveal_height: float = maxf(0.0, float(params.get("curb_reveal_height", DEFAULT_CURB_REVEAL_HEIGHT)))
	var curb_width: float = maxf(0.01, float(params.get("curb_width", DEFAULT_CURB_WIDTH)))
	var gutter_width: float = maxf(0.0, float(params.get("gutter_width", DEFAULT_GUTTER_WIDTH)))
	var aggregate_base_thickness: float = maxf(0.01, float(params.get("aggregate_base_thickness", DEFAULT_AGGREGATE_BASE_THICKNESS)))
	var binder_thickness: float = maxf(0.0, float(params.get("binder_thickness", DEFAULT_BINDER_THICKNESS)))
	var bedding_thickness: float = maxf(0.001, float(params.get("bedding_thickness", DEFAULT_BEDDING_THICKNESS)))
	var brick_thickness: float = maxf(0.005, float(params.get("brick_thickness", DEFAULT_BRICK_THICKNESS)))

	var seed_data := PhysicalSeedReader.read(seed_handle)
	var stack_top := base_y + aggregate_base_thickness + binder_thickness + bedding_thickness

	# ── layer slabs (base -> binder -> bedding), flat, bottom to top ────────────────────────────────
	var layers: Array = []
	var base_y_c := base_y + aggregate_base_thickness * 0.5
	layers.append(_slab(street_rect, aggregate_base_thickness, base_y_c, BASE_COLOR))
	var binder_y_c := base_y + aggregate_base_thickness + binder_thickness * 0.5
	if binder_thickness > 0.0:
		layers.append(_slab(street_rect, binder_thickness, binder_y_c, BINDER_COLOR))
	var bedding_y_c := base_y + aggregate_base_thickness + binder_thickness + bedding_thickness * 0.5
	var bedding_color := SAND_COLOR if joint_mode != "mortar_set" else MORTAR_COLOR
	layers.append(_slab(street_rect, bedding_thickness, bedding_y_c, bedding_color))

	# ── width axis + crown/gutter geometry (research sec5) ──────────────────────────────────────────
	var width_is_x := street_rect.size.x <= street_rect.size.y
	var half_width: float = (street_rect.size.x if width_is_x else street_rect.size.y) * 0.5
	var center := street_rect.get_center()

	# ── curbs: two prisms along the LENGTH axis, at the two width extremes ──────────────────────────
	var curbs: Array = []
	if curb_reveal_height > 0.0 and half_width > curb_width * 0.5:
		# curb spans from base_y up to (stack_top - brick_thickness surface + curb_reveal_height above
		# the paver top) -- i.e. bottom-anchored at base_y, top rises curb_reveal_height above the
		# (uncrowned) paver top surface.
		var curb_bottom := base_y
		var curb_top := stack_top + brick_thickness + curb_reveal_height
		var curb_h := curb_top - curb_bottom
		var curb_center_y := curb_bottom + curb_h * 0.5
		for edge_sign: float in [-1.0, 1.0]:
			var d: float = edge_sign * (half_width - curb_width * 0.5)
			var mesh := BoxMesh.new()
			var pos: Vector3
			if width_is_x:
				mesh.size = Vector3(curb_width, curb_h, street_rect.size.y)
				pos = Vector3(center.x + d, curb_center_y, center.y)
			else:
				mesh.size = Vector3(street_rect.size.x, curb_h, curb_width)
				pos = Vector3(center.x, curb_center_y, center.y + d)
			curbs.append({"mesh": mesh, "position": pos, "color": CURB_COLOR})

	# ── pavers: tile the physical-seed lattice across the rect, then crown + gutter-exclude ───────────
	var paver_mesh := BoxMesh.new()
	var brick_length: float = float(seed_data.get("brick_length", 0.2))
	var brick_width_dim: float = float(seed_data.get("brick_width", 0.1))
	paver_mesh.size = Vector3(maxf(0.01, brick_length - mortar_gap), brick_thickness, maxf(0.01, brick_width_dim - mortar_gap))

	var transforms: Array = _stamp_lattice(seed_data, street_rect)
	var placed: Array = []
	for tr in transforms:
		var pos: Vector3 = tr["position"]
		var d: float = (pos.x - center.x) if width_is_x else (pos.z - center.y)
		if half_width - absf(d) < gutter_width:
			continue  # gutter pan -- exposed bedding sand, no paver here (research sec5)
		var crown_t: float = clampf(d / maxf(0.001, half_width), -1.0, 1.0)
		var crown_offset: float = crown_height * (1.0 - crown_t * crown_t)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash([jitter_seed, int(pos.x * 1000.0), int(pos.z * 1000.0)])
		var jitter_y := rng.randf_range(-0.001, 0.001)  # sub-mm per-brick settling variation
		placed.append(Transform3D(
			Basis(Vector3.UP, deg_to_rad(tr["rotation_deg"])),
			Vector3(pos.x, stack_top + brick_thickness * 0.5 + crown_offset + jitter_y, pos.z)
		))

	return {
		"layers": layers,
		"curbs": curbs,
		"paver_mesh": paver_mesh,
		"paver_transforms": placed,
		"paver_color": BRICK_COLOR_BASE,
	}


static func _slab(rect: Rect2, thickness: float, center_y: float, color: Color) -> Dictionary:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(maxf(0.01, rect.size.x), maxf(0.001, thickness), maxf(0.01, rect.size.y))
	var c := rect.get_center()
	return {"mesh": mesh, "position": Vector3(c.x, center_y, c.y), "color": color}


## Generic, format-blind lattice tiling (design doc sec3.1): stamp `seed_data`'s member list at every
## integer (i,j) combination of lattice_a/lattice_b whose stamped bounding box could overlap `rect`,
## in RECT-LOCAL space, then translate into world space. No pattern-specific code -- works identically
## whether `seed_data` came from a herringbone JSON, a running-bond JSON, or a hand-arranged .tscn.
static func _stamp_lattice(seed_data: Dictionary, rect: Rect2) -> Array:
	var members: Array = seed_data.get("members", [])
	var lattice_a: Vector2 = seed_data.get("lattice_a", Vector2.ZERO)
	var lattice_b: Vector2 = seed_data.get("lattice_b", Vector2.ZERO)
	if members.is_empty() or lattice_a.length() < 1e-6 or lattice_b.length() < 1e-6:
		return []

	var out: Array = []
	# Conservative i/j bound: enough repeats in each lattice direction to cover the rect's diagonal
	# plus a one-cell margin (matches StreetGridScaffold's own "guard, never hang" posture for
	# degenerate/large inputs).
	var diag := rect.size.length()
	var span_a: int = int(ceil(diag / maxf(0.01, lattice_a.length()))) + 2
	var span_b: int = int(ceil(diag / maxf(0.01, lattice_b.length()))) + 2
	span_a = mini(span_a, 4096)
	span_b = mini(span_b, 4096)

	var origin := rect.position
	for i in range(-span_a, span_a + 1):
		for j in range(-span_b, span_b + 1):
			var base := origin + float(i) * lattice_a + float(j) * lattice_b
			for m in members:
				var offset: Vector2 = m["offset"]
				var world := base + offset
				if world.x < rect.position.x - 0.5 or world.x > rect.position.x + rect.size.x + 0.5:
					continue
				if world.y < rect.position.y - 0.5 or world.y > rect.position.y + rect.size.y + 0.5:
					continue
				# strict membership in the rect itself (the 0.5 margin above is a coarse candidate
				# filter for perf; this is the real boundary test)
				if world.x < rect.position.x or world.x > rect.position.x + rect.size.x:
					continue
				if world.y < rect.position.y or world.y > rect.position.y + rect.size.y:
					continue
				out.append({"position": Vector3(world.x, 0.0, world.y), "rotation_deg": m["rotation_deg"]})
	return out


## Convenience: build ONE MultiMeshInstance3D for a `build()` result's paver set -- real GPU
## instancing (Truncate/LOD reuse intent, plan sec2.6), not one MeshInstance3D per brick.
static func paver_multimesh(result: Dictionary) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = result["paver_mesh"]
	var transforms: Array = result["paver_transforms"]
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = result.get("paver_color", BRICK_COLOR_BASE)
	mat.roughness = 0.85
	mmi.material_override = mat
	return mmi
