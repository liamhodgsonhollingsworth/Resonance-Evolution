class_name DirtFloorInfill
extends RefCounted
## DirtFloorInfill -- node 10 ("Cavity / bridge tier") of
## notes/planning/underground_halls_plan_2026_07_14.md, Wave 5 item 5.1 (B) of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-225b57d9). NEW, small, 3h: "For
## cavities flagged street-level/floor-cutoff, fills the bottom with dirt up to a slope threshold."
##
## In: `cavity_cutaway_field` (NonOverlappingCavityCarver.carve()'s own `through == true` subset --
## the SAME set PlantScatterInCavities already prefers as its floor-level candidate set, Wave 4 item
## 4.3 (B); this module supplies the literal dirt floor those plants are conceptually rooted in).
##
## GEOMETRY INTERPRETATION (documented decision -- "fills the bottom... up to a slope threshold" reads
## as an angle-of-repose dirt/rubble pile spilling from the LOWER portion of a floor-cutoff cavity's own
## opening, filling the local footprint's bottom edge with a solid wedge whose top surface slopes at
## `max_slope_deg` off the horizontal -- the real-world "angle of repose" a loose dirt/rubble pile
## naturally settles at, capped so it never exceeds the cavity's own footprint bounds): a solid
## triangular-prism wedge, flush against the wall at the cavity's own local floor line (bottom of its
## footprint disk, matching cavity_carver's/plant_scatter's own local (basis.x, basis.y) footprint
## plane convention), protruding along the cavity's own +Z ("into the corridor interior", per
## `wall_surface_uv`'s convention) and rising from there to a ridge at `max_slope_deg`.
##
## Every returned entry: {"ring": int, "mesh": Mesh (world-space vertices, place with an IDENTITY
## transform -- same convention cavity_carver.gd's own cavity meshes use), "material_handle": String,
## "slope_deg": float (the ACTUAL slope used, after the footprint-bound cap -- may be < max_slope_deg
## for a small cavity)}.
##
## Tunables (the EXACT two named by the plan -- no more, per no-auto-generalization):
##   max_slope_deg        (float, degrees) -- the "angle of elevation... adjustable" param Liam
##                                            explicitly asked for; the dirt pile's own top-surface tilt.
##   dirt_material_handle (String) -- resolved through style_bridge.py's handle convention by a later
##                                    material-facing pass (this module emits the handle, not a
##                                    resolved Material -- matches `MaterialRealismPorts`' own
##                                    stub-port convention, per this scene's §10.3 addendum).
## (Implementation-detail defaults below -- `protrusion_fraction`/`width_fraction` -- documented,
## overridable via `tunables`, same pattern every sibling module in this arc uses.)

const DEFAULT_MAX_SLOPE_DEG := 35.0          # loose dirt/rubble angle-of-repose, real-world ballpark
const DEFAULT_DIRT_MATERIAL_HANDLE := "dirt_earth"
const DEFAULT_PROTRUSION_FRACTION := 0.9     # protrusion depth, as a fraction of the cavity's own size
const DEFAULT_WIDTH_FRACTION := 0.7          # wedge width, as a fraction of the cavity's own size


## Build a dirt patch for every entry in `cavity_cutaway_field`. Returns an Array[Dictionary] of
## `dirt_patch_meshes` (see file header for the exact shape).
static func infill(cavity_cutaway_field: Array, tunables: Dictionary = {}) -> Array[Dictionary]:
	var max_slope_deg: float = clampf(float(tunables.get("max_slope_deg", DEFAULT_MAX_SLOPE_DEG)), 1.0, 89.0)
	var dirt_material_handle: String = String(tunables.get("dirt_material_handle", DEFAULT_DIRT_MATERIAL_HANDLE))
	var protrusion_fraction: float = maxf(0.05, float(tunables.get("protrusion_fraction", DEFAULT_PROTRUSION_FRACTION)))
	var width_fraction: float = maxf(0.05, float(tunables.get("width_fraction", DEFAULT_WIDTH_FRACTION)))

	var out: Array[Dictionary] = []
	for cavity in cavity_cutaway_field:
		var d: Dictionary = cavity
		if not d.has("transform"):
			continue
		var transform: Transform3D = d["transform"]
		var size: float = maxf(0.05, float(d.get("size", 0.5)))
		var built := _build_wedge(transform, size, max_slope_deg, protrusion_fraction, width_fraction)
		out.append({
			"ring": int(d.get("ring", 0)), "mesh": built["mesh"], "material_handle": dirt_material_handle,
			"slope_deg": built["slope_deg"],
		})
	return out


## Solid triangular-prism dirt wedge, local frame (right=basis.x, up-along-wall=basis.y, into-corridor
## =basis.z), flush against the wall (local z=0) at the cavity's own local floor line (local y=-size),
## protruding to `depth` and rising to `rise` at `max_slope_deg` -- capped so `rise` never exceeds the
## footprint's own bound (2*size, the full local-plane diameter), which correspondingly caps the
## EFFECTIVE slope reported back in `slope_deg`.
static func _build_wedge(transform: Transform3D, size: float, max_slope_deg: float,
		protrusion_fraction: float, width_fraction: float) -> Dictionary:
	var depth: float = size * protrusion_fraction
	var half_width: float = size * width_fraction
	var floor_y := -size
	var max_rise: float = size * 2.0
	var wanted_rise: float = depth * tan(deg_to_rad(max_slope_deg))
	var rise: float = minf(wanted_rise, max_rise)
	var actual_slope_deg: float = rad_to_deg(atan2(rise, maxf(depth, 0.0001))) if rise < wanted_rise else max_slope_deg

	# Cross-section triangle in the LOCAL (y, z) plane: A = wall-floor corner, B = protruded-floor
	# corner, C = ridge (the sloped top edge, per the angle-of-repose interpretation above).
	var a_local := Vector3(0.0, floor_y, 0.0)
	var b_local := Vector3(0.0, floor_y, depth)
	var c_local := Vector3(0.0, floor_y + rise, depth)

	var a0 := transform * (a_local + Vector3(-half_width, 0.0, 0.0))
	var a1 := transform * (a_local + Vector3(half_width, 0.0, 0.0))
	var b0 := transform * (b_local + Vector3(-half_width, 0.0, 0.0))
	var b1 := transform * (b_local + Vector3(half_width, 0.0, 0.0))
	var c0 := transform * (c_local + Vector3(-half_width, 0.0, 0.0))
	var c1 := transform * (c_local + Vector3(half_width, 0.0, 0.0))

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_tri(st, a0, b0, c0)                 # left end cap
	_tri(st, a1, c1, b1)                 # right end cap (reversed winding, faces +X)
	_quad(st, a0, a1, b1, b0)             # bottom (floor)
	_quad(st, b0, b1, c1, c0)             # sloped top (the dirt surface)
	st.generate_normals()
	return {"mesh": st.commit(), "slope_deg": actual_slope_deg}

static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)

static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_tri(st, a, b, c)
	_tri(st, a, c, d)
