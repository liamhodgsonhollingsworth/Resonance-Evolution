class_name BrickArchGenerator
extends RefCounted
## BrickArchGenerator -- DQ-b415f577, the arched-openings gap explicitly DISCLOSED (not silently
## skipped) by the just-merged brick-wall-generator lane (DQ-e732faee, RE PR #207): "arched
## window/door openings (the Omaha reference's most visually distinctive facade detail) -- already
## tracked separately as DQ-b415f577, not duplicated; this lane's openings are flat-topped with a
## soldier-course lintel." This module builds the REAL voussoir masonry the reference image shows.
##
## STUDIED DIRECTLY FROM THE REFERENCE (not assumed): `Alethea-cc/tools/image_evolver/target/
## scene_refs/brick_street_omaha_reference.jpg` -- every visible facade opening on the right-hand wall
## is a TALL, ROUND-TOPPED (SEMICIRCULAR) arch with a visible lighter-brick voussoir ring outlining the
## curve, springing roughly two-thirds of the way up a narrow opening. This is why `semicircular` is
## this generator's DEFAULT (the older 07-14 plan's node-5 draft defaulted `arch_style` to `segmental`
## before anyone had actually looked closely at the reference image -- disclosed deviation, not a
## silent one: this lane's own brief says "match what the Omaha reference actually shows").
##
## REAL-WORLD RESEARCH (notes/research/brick_street_construction_methods_2026_07_16.md sec9, Wavelet
## repo -- Brick Industry Association arch technical guides, Archtoolbox, standard masonry-arch
## references):
##   - voussoir: a wedge-shaped brick laid RADIALLY (its bed joints point at the arch's center) so the
##     ring of voussoirs is in compression around the opening -- the defining structural mechanism of
##     a masonry arch.
##   - keystone: the (often enlarged/proud) voussoir at the CROWN (the topmost, theta=0 wedge) that
##     locks the two haunches together -- a real, distinctive detail, not decorative-only.
##   - springing line: the height at which the curve leaves the vertical jambs and the radial coursing
##     begins -- everything below is ordinary vertical jamb (unchanged field/jamb masonry), everything
##     above is the arch ring.
##   - segmental arch: a circular arc FLATTER than a semicircle (rise < half-span) -- the common,
##     economical window-head arch in US commercial masonry, typically rise/span in the ~1/8-1/2 range.
##   - semicircular arch: rise == half-span == the circle's own radius, BY DEFINITION (a true half
##     circle) -- the round-arch profile Romanesque-influenced warehouse facades (like the Omaha
##     reference) commonly use.
##   - rowlock/soldier arch courses: this generator reuses `BrickWallGenerator`'s own already-real
##     soldier-course convention (radial voussoirs ARE a curved generalization of a soldier course --
##     each brick standing on end, narrow face out, just individually rotated to follow the curve
##     instead of all sharing one flat orientation) rather than inventing a third brick posture.
##
## PHYSICAL-SEED SELECTABLE (same principle `seed_handle` already proves for bond pattern,
## `BrickWallGenerator`'s own docstring): `godot/assets/arch_exemplars/{segmental,semicircular}_arch.
## json` declare `rise_ratio` / `voussoir_count` / `keystone_enabled` as DATA, not code branches --
## swapping `arch_seed_handle` changes the arch style with ZERO code change, matching the "no redundant
## enum" precedent `BrickWallGenerator` already established for its own `bond_pattern` (this generator
## deliberately does NOT also expose a parallel `arch_style`/`voussoir_count` free_param dict --
## exactly one source of truth, the seed file, same lesson).
##
## SHARED SINGLE-SOURCE-OF-TRUTH GEOMETRY: `arch_geometry()` is the ONE place the segmental/semicircular
## curve math lives. `BrickWallGenerator.build()` calls it once per opening and stores the result in
## `openings[i]["arch"]`; `PanedGlassPanel` (DQ-84d20364) consumes that SAME dict (via
## `profile_points()`) rather than recomputing the curve, so the glass fill and the masonry ring can
## never geometrically drift apart.
##
## LOW-POLY CONVENTION (Liam 2026-07-14 spec: "make the bricks be simple rectangles with single
## colors... more detail can be filled in later losslessly"): each voussoir is a simple BoxMesh,
## ROTATED to be genuinely radial (not a hand-tapered wedge mesh) -- the COURSING/PLACEMENT is real
## masonry geometry (every wedge points at the true arch center, evenly divided by angle, exactly as
## real voussoirs are cut and laid), the per-brick SHAPE is the same low-poly simplification every
## other orientation in this file already uses (see `BrickWallGenerator._extents_for_orientation`).
## A future detail pass can taper the box into a true trapezoidal wedge losslessly, per spec.
##
## COURSES ADJUSTED AROUND THE ARCH (no floating bricks, no gap -- the facade lane's corner-gap
## lesson, "verify by RENDER, not code review"): `BrickWallGenerator.build()` excludes ordinary field
## coursing from the union of (jamb rect below the springing line) and (a disk of radius
## `extrados_radius` centered on the arch, above the springing line) -- see `_in_any_opening` there.
## The SPANDREL corners (between the arch's outer curve and the opening's old flat-topped bounding
## box) are deliberately left UNEXCLUDED so ordinary running-bond field coursing continues to fill
## them naturally, exactly as real spandrel brickwork does -- this is why the exclusion test is a
## disk-around-the-arch-center, not "exclude the whole old rectangular opening bounding box".

const ORIENT_VOUSSOIR := 500
const ORIENT_KEYSTONE := 501


## Exposed-face extents for a plain voussoir, matching `BrickWallGenerator._extents_for_orientation`'s
## own per-orientation Vector3(tangential_width, radial_length, depth_into_wall) convention -- a
## voussoir is a soldier-like brick (narrow header end exposed, standing on its length) individually
## rotated to point at the arch center instead of sharing one flat wall-tangent orientation.
static func voussoir_extents(brick_length: float, header_width: float) -> Vector3:
	return Vector3(header_width, brick_length, header_width)


## The keystone is a real, distinctive detail -- slightly wider (tangentially), slightly longer
## (radially), and slightly proud of the arch ring (deeper) than a plain voussoir, matching how real
## keystones are commonly cut oversized to visually and structurally lock the crown.
static func keystone_extents(brick_length: float, header_width: float) -> Vector3:
	return Vector3(header_width * 1.25, brick_length * 1.3, header_width * 1.35)


## Reads an arch physical-seed JSON (schema: {"style":"none"|"segmental"|"semicircular",
## "rise_ratio":float, "voussoir_count":int, "keystone_enabled":bool}). `path == ""` or `"none"` is the
## explicit sentinel for "no arch, flat lintel" (preserves the prior brick-wall-generator-2026-07-16
## lane's behavior with zero geometry change). Fail-open on any read/parse error, matching
## `PhysicalSeedReader`'s own posture (degrade to "no arch" rather than crash).
static func read_arch_seed(path: String) -> Dictionary:
	if path == "" or path == "none":
		return {"style": "none"}
	if not FileAccess.file_exists(path):
		push_error("BrickArchGenerator.read_arch_seed: not found at %s" % path)
		return {"style": "none"}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("BrickArchGenerator.read_arch_seed: malformed seed at %s" % path)
		return {"style": "none"}
	return {
		"style": String(parsed.get("style", "none")),
		"rise_ratio": float(parsed.get("rise_ratio", 0.25)),
		"voussoir_count": int(parsed.get("voussoir_count", 7)),
		"keystone_enabled": bool(parsed.get("keystone_enabled", true)),
	}


## Pure circular-arc-from-chord-and-rise geometry: given a half-span `s` and a `rise` (both > 0),
## returns the circle's radius, the vertical offset from the springing line down to the circle's
## center, and the half-angle the arc subtends. Formula: R = (s^2 + r^2) / (2r) -- the standard
## relation for a circular arc through two springing points a distance `2s` apart with apex height
## `r` above the chord. `semicircular` is the special case rise == half_span: R reduces EXACTLY to
## `s` and the center-offset reduces EXACTLY to 0 (the center sits ON the springing line) -- the
## textbook semicircular arch, not a separate code path.
static func _radius_and_theta(half_span: float, rise: float) -> Dictionary:
	var r := maxf(0.01, rise)
	var s := maxf(0.01, half_span)
	var radius := (s * s + r * r) / (2.0 * r)
	radius = maxf(radius, s)  # a circular arc through the springing points + apex is never narrower
	                            # than the half-span itself (degenerate/near-zero-rise guard)
	var theta_max := asin(clampf(s / radius, -1.0, 1.0))
	return {"radius": radius, "center_v_offset": r - radius, "theta_max": theta_max}


## Full arch descriptor for one opening. `rect` is the opening's existing (u0, v0, w, h) wall-local
## bounding box (`BrickWallGenerator._layout_openings`'s own convention, UNCHANGED) -- the arch is
## inscribed in its TOP portion, springing off the jambs partway up, so the total opening height `h`
## keeps meaning "jamb height + arch rise" and every existing `window_height`/`door_height` tunable
## keeps working unmodified. Returns `{"style":"none"}` for `style` values other than "segmental" /
## "semicircular" (the flat-lintel path, caller checks `style != "none"`). DEGENERATE-OPENING GUARD
## (found by an actual headless test run, not just review -- a genuine crash, `_in_any_opening`'s jamb
## Rect2 going negative-size for a short/wide opening): `rise` is clamped to never exceed the opening's
## own height for BOTH styles, including semicircular -- a true semicircle physically cannot fit inside
## an opening shorter than its own half-span, so that degenerate case degrades to a flatter arc rather
## than crashing, matching this file's own clamp-degenerate-inputs-never-crash convention.
static func arch_geometry(rect: Rect2, style: String, rise_ratio: float) -> Dictionary:
	if style != "segmental" and style != "semicircular":
		return {"style": "none"}
	var half_span: float = maxf(0.02, rect.size.x * 0.5)
	var rise: float
	if style == "semicircular":
		rise = half_span  # geometrically FORCED -- a semicircle's rise IS its half-span, by definition
	else:
		rise = clampf(rise_ratio, 0.05, 0.9) * rect.size.x
	# UNIFORM guard for BOTH styles: never taller than the opening itself. A semicircle physically
	# cannot fit inside an opening shorter than its own half-span (a real construction would use a
	# shallower arch there instead) -- clamping degrades that degenerate case to a flatter arc rather
	# than producing a negative-height jamb rect (a genuine crash found by an actual headless test run,
	# not just review: `_in_any_opening`'s jamb Rect2 went negative-size for a short, wide opening,
	# matching this file's own "clamp degenerate inputs, never crash" convention).
	rise = minf(rise, maxf(0.02, rect.size.y - 0.02))
	rise = maxf(rise, 0.02)
	var rt := _radius_and_theta(half_span, rise)
	var center_u: float = rect.position.x + rect.size.x * 0.5
	var springing_v: float = rect.position.y + rect.size.y - rise
	return {
		"style": style,
		"center_u": center_u,
		"springing_v": springing_v,
		"center_v": springing_v + float(rt["center_v_offset"]),
		"radius": float(rt["radius"]),
		"theta_max": float(rt["theta_max"]),
		"half_span": half_span,
		"rise": rise,
	}


## Curve points (wall-local u,v), `segments` straight pieces (segments+1 points), from the left
## springing point over the crown to the right springing point, at the given `radius` from the arch's
## own center -- shared by voussoir placement (intrados/extrados/mid radii, below) AND
## `PanedGlassPanel`'s glass-fan fitting (module docstring): one curve function, multiple radii, two
## consumers, zero drift.
static func profile_points(arch: Dictionary, radius: float, segments: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	if arch.get("style", "none") == "none":
		return out
	var theta_max: float = arch["theta_max"]
	var center_u: float = arch["center_u"]
	var center_v: float = arch["center_v"]
	var n: int = maxi(2, segments)
	for i in (n + 1):
		var t: float = float(i) / float(n)
		var theta: float = -theta_max + t * 2.0 * theta_max
		out.append(Vector2(center_u + radius * sin(theta), center_v + radius * cos(theta)))
	return out


## Voussoir + keystone placements for one opening, in WORLD-space Transform3Ds ready for the caller to
## merge into `BrickWallGenerator`'s own `groups[orientation] -> Array[Transform3D]` convention (this
## module returns pure data -- no coupling to that dict's shape). `wall` is the SAME
## {"origin","tangent","normal","length"} dict `_append_lintel`/`_append_sill` already receive
## (`BrickWallGenerator._walls_from_footprint`'s own per-wall output, also reachable via the public
## `BrickWallGenerator.walls_from_footprint()`) -- no private-helper reach-in, the caller already has
## it in scope.
static func build_voussoirs(wall: Dictionary, arch: Dictionary, brick_length: float, header_width: float,
		voussoir_count: int, keystone_enabled: bool) -> Dictionary:
	var out := {"voussoirs": [], "keystone": null, "extrados_radius": 0.0}
	if arch.get("style", "none") == "none":
		return out

	var v_extents := voussoir_extents(brick_length, header_width)
	var k_extents := keystone_extents(brick_length, header_width)
	var radial_thickness: float = v_extents.y  # intrados sits at arch["radius"] (the void boundary)
	var mid_radius: float = float(arch["radius"]) + radial_thickness * 0.5
	var theta_max: float = arch["theta_max"]
	var center_u: float = arch["center_u"]
	var center_v: float = arch["center_v"]

	var count: int = maxi(3, voussoir_count)
	if keystone_enabled and count % 2 == 0:
		count += 1  # guarantee a true CENTER wedge exists so the keystone has somewhere to sit
	var has_center: bool = keystone_enabled

	var voussoir_transforms: Array = []
	var keystone_transform = null
	var tangent: Vector3 = wall["tangent"]
	var normal: Vector3 = wall["normal"]
	var origin: Vector3 = wall["origin"]

	for i in count:
		var t: float = (float(i) + 0.5) / float(count)
		var theta: float = -theta_max + t * 2.0 * theta_max
		var is_center: bool = has_center and i == count / 2
		var extents: Vector3 = k_extents if is_center else v_extents
		var u: float = center_u + mid_radius * sin(theta)
		var v: float = center_v + mid_radius * cos(theta)
		# local X = tangential (direction of increasing theta along the arc), local Y = radial
		# (points away from the arch center) -- the SAME (tangent, UP, normal) plane-basis convention
		# `_append_placement` uses for flat field bricks, just rotated WITHIN that plane by theta.
		var tangential_2d := Vector2(cos(theta), -sin(theta))
		var radial_2d := Vector2(sin(theta), cos(theta))
		var tangential_3d: Vector3 = tangent * tangential_2d.x + Vector3.UP * tangential_2d.y
		var radial_3d: Vector3 = tangent * radial_2d.x + Vector3.UP * radial_2d.y
		var basis := Basis(tangential_3d, radial_3d, normal)
		var depth_center: float = extents.z * 0.5
		var brick_origin: Vector3 = origin + tangent * u + Vector3.UP * v + normal * depth_center
		var xform := Transform3D(basis, brick_origin)
		if is_center:
			keystone_transform = xform
		else:
			voussoir_transforms.append(xform)

	out["voussoirs"] = voussoir_transforms
	out["keystone"] = keystone_transform
	# extrados radius used by BrickWallGenerator to exclude field coursing from the arch ring's
	# footprint -- take the LARGER of the two extents' radial half-length so an enlarged keystone can
	# never poke into (or leave a sliver excluded around) neighboring field brick.
	var max_radial: float = maxf(v_extents.y, k_extents.y if has_center else 0.0)
	out["extrados_radius"] = mid_radius + max_radial * 0.5
	return out
