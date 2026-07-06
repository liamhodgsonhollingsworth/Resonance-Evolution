class_name SDF
extends RefCounted
## SIGNED-DISTANCE-FIELD math — the analytic primitive distances + the smooth CSG operators, ALL
## as pure static functions over plain Vector3 / floats (no engine objects, no Image, no render).
## This is the DATA-producing math seam under `prim_sdf_edit.gd`, exactly as `renderers/lsystem.gd`
## (LSystem) is the seam under `prim_lsystem.gd`: the primitive emits an EDIT-LIST descriptor, and a
## later sculpt/voxel/splat slice (the visuals session's lane) evaluates that descriptor into geometry.
## Nothing here draws — it STOPS at the distance function + the edit-list contract.
##
## ── ATTRIBUTION (MIT) ──────────────────────────────────────────────────────────────────────────
## The analytic primitive distances (sphere / box / round-box / torus / capped-cylinder / plane) and
## the polynomial smooth-min are the canonical closed forms from Inigo Quilez's "distance functions"
## reference (https://iquilezles.org/articles/distfunctions/), which IQ publishes under the MIT
## License, and match the MIT-licensed distribution of Mercury's hg_sdf primitive set. Only the
## MIT-licensed forms are ported here (the CC-BY-NC hg_sdf variant is NOT used — incompatible with the
## repo's O'Saasy/MIT posture). Formulas ported (not a linked dependency); credit: Inigo Quilez, MIT.
## ────────────────────────────────────────────────────────────────────────────────────────────────

# The edit-list format tag the primitive stamps onto its emitted descriptor. Additive-superset
# discipline: a new shape/op is a new enum string a consumer learns, never a format break.
const EDIT_FORMAT := "resonance.sdf_edit/v1"

# ── Analytic primitive distances (world point p, already in the shape's local frame) ─────────────

## Sphere of radius r centred at origin. sdSphere. (IQ, MIT)
static func sd_sphere(p: Vector3, r: float) -> float:
	return p.length() - r

## Axis-aligned box of half-extents b. sdBox. (IQ, MIT)
static func sd_box(p: Vector3, b: Vector3) -> float:
	var q := Vector3(absf(p.x) - b.x, absf(p.y) - b.y, absf(p.z) - b.z)
	var outside := Vector3(maxf(q.x, 0.0), maxf(q.y, 0.0), maxf(q.z, 0.0)).length()
	var inside := minf(maxf(q.x, maxf(q.y, q.z)), 0.0)
	return outside + inside

## Round box: box of half-extents b with corner radius rad. sdRoundBox. (IQ, MIT)
static func sd_round_box(p: Vector3, b: Vector3, rad: float) -> float:
	return sd_box(p, b) - rad

## Torus in the XZ plane: t.x major radius, t.y tube radius. sdTorus. (IQ, MIT)
static func sd_torus(p: Vector3, t: Vector2) -> float:
	var q := Vector2(Vector2(p.x, p.z).length() - t.x, p.y)
	return q.length() - t.y

## Capped cylinder along Y: radius r, half-height h. sdCappedCylinder. (IQ, MIT)
static func sd_capped_cylinder(p: Vector3, r: float, h: float) -> float:
	var d := Vector2(absf(Vector2(p.x, p.z).length()) - r, absf(p.y) - h)
	return minf(maxf(d.x, d.y), 0.0) + Vector2(maxf(d.x, 0.0), maxf(d.y, 0.0)).length()

## Plane with unit normal n at signed distance offset h from origin. sdPlane. (IQ, MIT)
static func sd_plane(p: Vector3, n: Vector3, h: float) -> float:
	return p.dot(n.normalized()) + h

# ── CSG operators (combine two already-evaluated distances) ──────────────────────────────────────

## Hard union / subtraction / intersection (min / max forms). (IQ, MIT)
static func op_union(d1: float, d2: float) -> float:
	return minf(d1, d2)

static func op_subtract(d1: float, d2: float) -> float:
	# Subtract shape 2 from shape 1: max(d1, -d2).
	return maxf(d1, -d2)

static func op_intersect(d1: float, d2: float) -> float:
	return maxf(d1, d2)

## Polynomial smooth-min: the C1 blend that rounds a union with blend radius k>0. smin. (IQ, MIT)
## k == 0 degrades exactly to the hard min, so blend radius 0 is the sharp CSG case (continuous).
static func smooth_union(d1: float, d2: float, k: float) -> float:
	if k <= 0.0:
		return minf(d1, d2)
	var h := clampf(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0)
	return lerpf(d2, d1, h) - k * h * (1.0 - h)

## Smooth subtraction (round the carved edge with radius k). (IQ, MIT)
static func smooth_subtract(d1: float, d2: float, k: float) -> float:
	if k <= 0.0:
		return maxf(d1, -d2)
	var h := clampf(0.5 - 0.5 * (d2 + d1) / k, 0.0, 1.0)
	return lerpf(d1, -d2, h) + k * h * (1.0 - h)

## Smooth intersection (round the shared edge with radius k). (IQ, MIT)
static func smooth_intersect(d1: float, d2: float, k: float) -> float:
	if k <= 0.0:
		return maxf(d1, d2)
	var h := clampf(0.5 - 0.5 * (d2 - d1) / k, 0.0, 1.0)
	return lerpf(d2, d1, h) + k * h * (1.0 - h)

# ── Edit-list evaluation (the DATA contract; NOT a renderer) ──────────────────────────────────────

## Distance of one edit's shape at world point p. `edit` is the plain-dict edit descriptor emitted by
## prim_sdf_edit (shape + params + transform). The point is moved into the edit's local frame by the
## inverse translation + a uniform inverse scale (rotation via a quaternion if present), then the
## matching analytic form is evaluated and rescaled back to world units (multiply by scale) so
## distances remain composable across edits of different scale.
static func edit_distance(edit: Dictionary, p: Vector3) -> float:
	var t: Dictionary = edit.get("transform", {})
	var pos := _as_vec3(t.get("position", [0, 0, 0]))
	var scale := float(t.get("scale", 1.0))
	if scale == 0.0:
		scale = 1.0
	var rot = t.get("rotation", null)  # optional [x,y,z,w] quaternion
	var lp := p - pos
	if rot != null:
		var q := Quaternion(float(rot[0]), float(rot[1]), float(rot[2]), float(rot[3])).normalized()
		lp = q.inverse() * lp
	lp = lp / scale
	var pr: Dictionary = edit.get("params", {})
	var d := 1e30
	match String(edit.get("shape", "sphere")):
		"sphere":
			d = sd_sphere(lp, float(pr.get("radius", 1.0)))
		"box":
			d = sd_box(lp, _as_vec3(pr.get("half_extents", [1, 1, 1])))
		"round_box":
			d = sd_round_box(lp, _as_vec3(pr.get("half_extents", [1, 1, 1])), float(pr.get("radius", 0.1)))
		"torus":
			d = sd_torus(lp, Vector2(float(pr.get("major", 1.0)), float(pr.get("minor", 0.25))))
		"cylinder":
			d = sd_capped_cylinder(lp, float(pr.get("radius", 1.0)), float(pr.get("height", 1.0)))
		"plane":
			d = sd_plane(lp, _as_vec3(pr.get("normal", [0, 1, 0])), float(pr.get("offset", 0.0)))
		_:
			d = sd_sphere(lp, float(pr.get("radius", 1.0)))
	return d * scale

## Distance of a whole ORDERED edit-list at world point p — the composed field the sculpt/voxel/splat
## consumer bakes. Each edit folds into the accumulator with its own CSG op + blend radius, so the
## list IS the arrangement: reorder / edit an entry and the field changes, no new code. An empty list
## is "far everywhere" (+inf sentinel), the well-defined identity for union.
static func field_distance(edits: Array, p: Vector3) -> float:
	var acc := 1e30
	var first := true
	for e in edits:
		var d := edit_distance(e, p)
		var op := String(e.get("op", "add"))
		var k := float(e.get("blend", 0.0))
		if first:
			# The first edit seeds the field; add/subtract on an empty field both yield the shape
			# (subtract-from-nothing = nothing, so a leading subtract yields +inf, which is correct).
			acc = d if op != "subtract" else 1e30
			first = false
			continue
		match op:
			"add":
				acc = smooth_union(acc, d, k)
			"subtract":
				acc = smooth_subtract(acc, d, k)
			"intersect":
				acc = smooth_intersect(acc, d, k)
			_:
				acc = smooth_union(acc, d, k)
	return acc

static func _as_vec3(v) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2]))
	return Vector3.ZERO
