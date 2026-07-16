class_name PanedGlassPanel
extends RefCounted
## PanedGlassPanel -- DQ-84d20364, the window-glass-fill gap the brick-wall-generator lane's own
## release note disclosed: "Follow-up enqueued: DQ-84d20364 (window glass fill, PanedGlassPanel,
## windows currently show straight through to the sky)." Fills `BrickWallGenerator`'s window/door
## `openings` (the exact Rect2s its `build()` result already exposes, per the DQ note) with a real,
## simple glass material -- v0 flat dark glass by default (matches the 07-14 plan's own spec wording,
## "the insides of the windows can be black or dark... simple glass material"), with a TUNABLE
## muntin-grid option per this lane's explicit brief (`pane_pattern`, off/`none` by default, matching
## the DQ note's own v0 disposition: "window default dark/flat glass, mullion pattern deferred" -- the
## option EXISTS and is fully wired, it just isn't forced on).
##
## SHARES BrickArchGenerator's arch geometry (DQ-b415f577, see that module's docstring for the
## single-source-of-truth rationale): when an opening is arched (`opening["arch"]` non-null, set by
## `BrickWallGenerator.build()`), the glass is fit to the SAME curve the voussoir ring uses --
## `BrickArchGenerator.profile_points()` at the arch's own intrados radius, so the glass can never
## geometrically drift from the masonry it fills (no flat rectangular corners poking past a round
## arch into the voussoir ring, no gap between the glass and the brick surround).
##
## REAL-ISH GLASS MATERIAL, LOW-POLY CONVENTION: v0 is a StandardMaterial3D (opaque dark albedo +
## metallic/roughness tuned for a plausible glassy sheen), not a physically-based transparent/
## refractive shader -- matches this corpus's "low poly and low detail... more detail can be filled in
## later losslessly" directive (Liam 2026-06-14/07-14 spec). `glass_reflectivity` maps directly to
## `metallic` (+ an inverse-scaled `roughness`), giving a genuine tunable sheen without a refraction
## pass. The arch-cap piece is built as a THIN two-sided prism (front + back triangle fans, verified
## winding -- see `_append_arch_fan_pane`) rather than a single-sided flat plane, so it is never
## accidentally backface-culled/invisible from either the exterior or interior viewpoint -- a
## deliberate robustness choice over relying on `cull_mode` disable, disclosed here rather than
## silently risking an invisible-glass render defect (the facade lane's "verify by render" lesson).
##
## free_params (matches this corpus's `{type,min,max,default}` convention): `glass_inset_depth`
## {type:float, min:0.0, max:0.15, default:0.05} (reveal depth behind the wall's exterior brick face)
## · `glass_reflectivity` {type:float, min:0.0, max:1.0, default:0.3} · `pane_pattern` {type:enum,
## options:[none,grid], default:none} · `muntin_rows`/`muntin_cols` {type:int, min:1, max:6, default:1}
## (only visible when `pane_pattern:grid`) · `mullion_width` {type:float, min:0.0, max:0.1,
## default:0.03} · `glass_color` {type:color, default:"#0a0a0a"} (NOT TunablePanel-wired -- matches
## `BrickWallGenerator.brick_color`'s own precedent, since `TunablePanel` has no "color" widget type
## yet, `godot/tools/tunable_panel.gd`).

const DEFAULT_INSET_DEPTH := 0.05
const DEFAULT_REFLECTIVITY := 0.3
const DEFAULT_GLASS_COLOR := Color(0.04, 0.04, 0.05)  # near-black, "insides can be black or dark"
const DEFAULT_PANE_PATTERN := "none"
const DEFAULT_MUNTIN_ROWS := 1
const DEFAULT_MUNTIN_COLS := 1
const DEFAULT_MULLION_WIDTH := 0.03
const DEFAULT_MULLION_COLOR := Color(0.16, 0.14, 0.12)  # dark bronze/metal muntin bar
const DEFAULT_WALL_THICKNESS := 0.1  # fallback if the caller doesn't pass BrickWallGenerator's own
                                       # derived header_width (see BrickWallGenerator.build() result)
const ARCH_FAN_SEGMENTS := 12
const PANE_THICKNESS := 0.01


## Build one opening's glass fill. `wall` = the SAME {"origin","tangent","normal"} dict
## `BrickWallGenerator`'s own per-wall helpers use (reachable via the public
## `BrickWallGenerator.walls_from_footprint(rect)[opening.wall_index]`); `opening` = one entry of
## `BrickWallGenerator.build()`'s `openings` array ({"rect":Rect2, "arch":Dictionary_or_null, ...}).
## Returns:
##   {"panes": Array of {"mesh": Mesh, "transform": Transform3D, "color": Color, "metallic": float,
##                        "roughness": float},
##    "muntins": Array of {"mesh": Mesh, "transform": Transform3D, "color": Color}}
static func build(wall: Dictionary, opening: Dictionary, params: Dictionary = {}) -> Dictionary:
	var inset_depth: float = clampf(float(params.get("glass_inset_depth", DEFAULT_INSET_DEPTH)),
		0.0, float(params.get("wall_thickness", DEFAULT_WALL_THICKNESS)))
	var reflectivity: float = clampf(float(params.get("glass_reflectivity", DEFAULT_REFLECTIVITY)), 0.0, 1.0)
	var glass_color: Color = params.get("glass_color", DEFAULT_GLASS_COLOR)
	var pane_pattern: String = String(params.get("pane_pattern", DEFAULT_PANE_PATTERN))
	var muntin_rows: int = maxi(1, int(params.get("muntin_rows", DEFAULT_MUNTIN_ROWS)))
	var muntin_cols: int = maxi(1, int(params.get("muntin_cols", DEFAULT_MUNTIN_COLS)))
	var mullion_width: float = maxf(0.0, float(params.get("mullion_width", DEFAULT_MULLION_WIDTH)))
	var mullion_color: Color = params.get("mullion_color", DEFAULT_MULLION_COLOR)

	var rect: Rect2 = opening.get("rect", Rect2())
	var arch = opening.get("arch")
	var has_arch: bool = arch != null and typeof(arch) == TYPE_DICTIONARY and arch.get("style", "none") != "none"

	var jamb_rect: Rect2 = rect
	if has_arch:
		var springing_v: float = arch["springing_v"]
		jamb_rect = Rect2(rect.position, Vector2(rect.size.x, maxf(0.02, springing_v - rect.position.y)))

	var out := {"panes": [], "muntins": []}
	var metallic: float = reflectivity
	var roughness: float = clampf(1.0 - reflectivity * 0.85, 0.05, 1.0)

	if pane_pattern == "grid" and (muntin_rows > 1 or muntin_cols > 1):
		_build_grid_panes(out, wall, jamb_rect, inset_depth, glass_color, metallic, roughness,
			muntin_rows, muntin_cols, mullion_width, mullion_color)
	else:
		_append_flat_pane(out, wall, jamb_rect, inset_depth, glass_color, metallic, roughness)

	if has_arch:
		_append_arch_fan_pane(out, wall, arch, inset_depth, glass_color, metallic, roughness)

	return out


static func _wall_point_3d(wall: Dictionary, u: float, v: float, depth: float) -> Vector3:
	return (wall["origin"] as Vector3) + (wall["tangent"] as Vector3) * u + Vector3.UP * v \
		+ (wall["normal"] as Vector3) * depth


static func _append_flat_pane(out: Dictionary, wall: Dictionary, rect: Rect2, inset_depth: float,
		color: Color, metallic: float, roughness: float) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(maxf(0.01, rect.size.x), maxf(0.01, rect.size.y), PANE_THICKNESS)
	var basis := Basis(wall["tangent"], Vector3.UP, wall["normal"])
	var center_u: float = rect.position.x + rect.size.x * 0.5
	var center_v: float = rect.position.y + rect.size.y * 0.5
	# depth is measured BACK from the wall's exterior brick face (wall.origin + wall_thickness) along
	# the inward direction -- a real inset reveal, not flush with the outer brick plane.
	var origin := _wall_point_3d(wall, center_u, center_v, -inset_depth)
	out["panes"].append({"mesh": mesh, "transform": Transform3D(basis, origin), "color": color,
		"metallic": metallic, "roughness": roughness})


## Subdivides `rect` into `rows` x `cols` individually-bounded small panes (real multi-light paned
## glass, not one pane with a decal grid on it) plus mullion bars between them -- (rows-1) horizontal
## + (cols-1) vertical, spanning the full rect, matching the 07-14 plan's own "extrudes it upwards
## using some metal material" framing for the shared paned-glass mechanism (this call site keeps
## `extrude_height` at 0 -- a flat window fill, per that plan's own node 7/8 spec).
static func _build_grid_panes(out: Dictionary, wall: Dictionary, rect: Rect2, inset_depth: float,
		color: Color, metallic: float, roughness: float, rows: int, cols: int, mullion_width: float,
		mullion_color: Color) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var basis := Basis(wall["tangent"], Vector3.UP, wall["normal"])
	var cell_w: float = rect.size.x / float(cols)
	var cell_h: float = rect.size.y / float(rows)
	for r in rows:
		for c in cols:
			var cu: float = rect.position.x + (float(c) + 0.5) * cell_w
			var cv: float = rect.position.y + (float(r) + 0.5) * cell_h
			var mesh := BoxMesh.new()
			mesh.size = Vector3(maxf(0.01, cell_w - mullion_width), maxf(0.01, cell_h - mullion_width), PANE_THICKNESS)
			var origin := _wall_point_3d(wall, cu, cv, -inset_depth)
			out["panes"].append({"mesh": mesh, "transform": Transform3D(basis, origin), "color": color,
				"metallic": metallic, "roughness": roughness})
	for r in (rows - 1):
		var v: float = rect.position.y + float(r + 1) * cell_h
		var mesh := BoxMesh.new()
		mesh.size = Vector3(rect.size.x, maxf(0.005, mullion_width), PANE_THICKNESS * 2.0)
		var origin := _wall_point_3d(wall, rect.position.x + rect.size.x * 0.5, v, -inset_depth)
		out["muntins"].append({"mesh": mesh, "transform": Transform3D(basis, origin), "color": mullion_color})
	for c in (cols - 1):
		var u: float = rect.position.x + float(c + 1) * cell_w
		var mesh := BoxMesh.new()
		mesh.size = Vector3(maxf(0.005, mullion_width), rect.size.y, PANE_THICKNESS * 2.0)
		var origin := _wall_point_3d(wall, u, rect.position.y + rect.size.y * 0.5, -inset_depth)
		out["muntins"].append({"mesh": mesh, "transform": Transform3D(basis, origin), "color": mullion_color})


## The arched-cap glass piece -- a triangle fan from the springing-line midpoint to N points on
## `BrickArchGenerator`'s own curve at the arch's INTRADOS radius (the void boundary itself, module
## docstring). Built as a real thin TWO-SIDED prism (a front fan facing outward + a back fan facing
## inward, correct winding verified algebraically -- see module docstring) rather than a single-sided
## plane, so it is never accidentally invisible from either side.
static func _append_arch_fan_pane(out: Dictionary, wall: Dictionary, arch: Dictionary, inset_depth: float,
		color: Color, metallic: float, roughness: float) -> void:
	var radius: float = float(arch["radius"])
	var points := BrickArchGenerator.profile_points(arch, radius, ARCH_FAN_SEGMENTS)
	if points.size() < 3:
		return
	var apex_u: float = float(arch["center_u"])
	var apex_v: float = float(arch["springing_v"])
	var half_t: float = PANE_THICKNESS * 0.5
	var front_depth: float = -inset_depth + half_t
	var back_depth: float = -inset_depth - half_t
	var normal_out: Vector3 = wall["normal"]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var apex_front := _wall_point_3d(wall, apex_u, apex_v, front_depth)
	for i in (points.size() - 1):
		var p0 := _wall_point_3d(wall, points[i].x, points[i].y, front_depth)
		var p1 := _wall_point_3d(wall, points[i + 1].x, points[i + 1].y, front_depth)
		# winding (apex, p0, p1) gives a face normal aligned with +wall.normal for this codebase's
		# (tangent, UP, normal) handedness convention (tangent x UP = -normal) -- verified algebraically,
		# not by trial and error: det(du_i*dv_{i+1} - du_{i+1}*dv_i) is negative for increasing theta,
		# so cross(p0-apex, p1-apex) = -det * (tangent x UP) = +det * normal ... resolves to +normal.
		st.set_normal(normal_out)
		st.add_vertex(apex_front)
		st.set_normal(normal_out)
		st.add_vertex(p0)
		st.set_normal(normal_out)
		st.add_vertex(p1)

	var apex_back := _wall_point_3d(wall, apex_u, apex_v, back_depth)
	for i in (points.size() - 1):
		var p0 := _wall_point_3d(wall, points[i].x, points[i].y, back_depth)
		var p1 := _wall_point_3d(wall, points[i + 1].x, points[i + 1].y, back_depth)
		# reversed winding + reversed normal -- the inward-facing cap.
		st.set_normal(-normal_out)
		st.add_vertex(apex_back)
		st.set_normal(-normal_out)
		st.add_vertex(p1)
		st.set_normal(-normal_out)
		st.add_vertex(p0)

	var mesh := st.commit()
	# vertices are already baked in WORLD space (built directly from `wall.origin` etc.), so the
	# instance transform is identity -- the caller applies this uniformly for both box panes (local
	# mesh + transform) and this fan mesh (world-space mesh + identity transform), no special-casing.
	out["panes"].append({"mesh": mesh, "transform": Transform3D.IDENTITY, "color": color,
		"metallic": metallic, "roughness": roughness})
