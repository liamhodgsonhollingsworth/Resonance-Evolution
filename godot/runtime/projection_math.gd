class_name ProjectionMath
extends RefCounted
## The shared CPU math seam for the PROJECTION-MAPPING family (projector = inverse camera).
## Pure, deterministic, engine-agnostic float math — no rendering, no GPU, no scene access —
## so the SAME functions back the headless calibration tests, the simulated camera-feedback
## loop, and (later) a real projector rig where only the observation source is swapped.
##
## Conventions (glTF/Godot canonical): +Y up, right-handed, cameras AND projectors look down
## their local -Z. Pixel space: origin top-left, +x right, +y down. Homographies are 9-float
## row-major Arrays (h33 normalized to 1 where possible). All wire values stay plain
## Arrays/Dictionaries/floats — JSON-serializable, per the data-on-a-wire law.

# ── 3x3 homography algebra (row-major 9-float Arrays) ────────────────────────────────────────

static func mat_identity() -> Array:
	return [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]

static func mat_is_valid(m) -> bool:
	if not (m is Array) or (m as Array).size() != 9:
		return false
	for v in m:
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			return false
	return true

static func mat_mul(a: Array, b: Array) -> Array:
	var r := []
	r.resize(9)
	for i in 3:
		for j in 3:
			var s := 0.0
			for k in 3:
				s += float(a[i * 3 + k]) * float(b[k * 3 + j])
			r[i * 3 + j] = s
	return r

## Normalize so h33 == 1 (when not degenerate) — keeps blends/comparisons meaningful.
static func mat_normalize(m: Array) -> Array:
	var w := float(m[8])
	if abs(w) < 1e-12:
		return m.duplicate()
	var r := []
	r.resize(9)
	for i in 9:
		r[i] = float(m[i]) / w
	return r

## 3x3 inverse via adjugate. Near-singular input degrades to identity (never crashes the loop).
static func mat_inv(m: Array) -> Array:
	var a := float(m[0]); var b := float(m[1]); var c := float(m[2])
	var d := float(m[3]); var e := float(m[4]); var f := float(m[5])
	var g := float(m[6]); var h := float(m[7]); var i := float(m[8])
	var det := a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
	if abs(det) < 1e-12:
		push_warning("ProjectionMath.mat_inv: near-singular matrix; returning identity")
		return mat_identity()
	var inv := [
		(e * i - f * h), (c * h - b * i), (b * f - c * e),
		(f * g - d * i), (a * i - c * g), (c * d - a * f),
		(d * h - e * g), (b * g - a * h), (a * e - b * d),
	]
	for k in 9:
		inv[k] = float(inv[k]) / det
	return inv

## Apply a homography to a 2D point (perspective divide).
static func apply_h(m: Array, p: Vector2) -> Vector2:
	var w := float(m[6]) * p.x + float(m[7]) * p.y + float(m[8])
	if abs(w) < 1e-12:
		return Vector2.INF
	return Vector2(
		(float(m[0]) * p.x + float(m[1]) * p.y + float(m[2])) / w,
		(float(m[3]) * p.x + float(m[4]) * p.y + float(m[5])) / w)

## Element-wise blend of two NORMALIZED homographies (gain in [0,1]) — the damped correction
## step of the feedback loop. gain=1 adopts `to` outright.
static func mat_blend(from: Array, to: Array, gain: float) -> Array:
	var a := mat_normalize(from)
	var b := mat_normalize(to)
	var r := []
	r.resize(9)
	for i in 9:
		r[i] = float(a[i]) + (float(b[i]) - float(a[i])) * clampf(gain, 0.0, 1.0)
	return mat_normalize(r)

# ── homography estimation (DLT, Hartley-normalized, least squares) ───────────────────────────

## Fit H such that dst ≈ H(src), from >= 4 point pairs (least squares over all pairs, via the
## normal equations of the DLT system, with Hartley coordinate normalization for conditioning).
## Returns a normalized 9-float Array, or identity when under-determined/degenerate.
static func fit_homography(src: Array, dst: Array) -> Array:
	var n: int = min(src.size(), dst.size())
	if n < 4:
		push_warning("ProjectionMath.fit_homography: need >= 4 correspondences, got %d" % n)
		return mat_identity()
	var ts := _hartley(src)
	var td := _hartley(dst)
	# Build the 8x8 normal equations A^T A h = A^T b over the normalized points.
	var ata := []
	var atb := []
	for i in 8:
		atb.append(0.0)
		var row := []
		for j in 8:
			row.append(0.0)
		ata.append(row)
	for k in n:
		var s: Vector2 = _apply_affine(ts, src[k])
		var d: Vector2 = _apply_affine(td, dst[k])
		var rows := [
			[s.x, s.y, 1.0, 0.0, 0.0, 0.0, -d.x * s.x, -d.x * s.y, d.x],
			[0.0, 0.0, 0.0, s.x, s.y, 1.0, -d.y * s.x, -d.y * s.y, d.y],
		]
		for r in rows:
			for i in 8:
				atb[i] = float(atb[i]) + float(r[i]) * float(r[8])
				for j in 8:
					ata[i][j] = float(ata[i][j]) + float(r[i]) * float(r[j])
	var h8 := _solve8(ata, atb)
	if h8.is_empty():
		return mat_identity()
	var hn := [h8[0], h8[1], h8[2], h8[3], h8[4], h8[5], h8[6], h8[7], 1.0]
	# Denormalize: H = Td^-1 * Hn * Ts.
	var h := mat_mul(mat_inv(_affine_to_mat(td)), mat_mul(hn, _affine_to_mat(ts)))
	return mat_normalize(h)

## Hartley normalization: translate centroid to origin, scale mean distance to sqrt(2).
## Returned as { "tx", "ty", "s" } meaning p' = (p - t) * s.
static func _hartley(pts: Array) -> Dictionary:
	var c := Vector2.ZERO
	for p in pts:
		c += p as Vector2
	c /= float(pts.size())
	var mean_d := 0.0
	for p in pts:
		mean_d += ((p as Vector2) - c).length()
	mean_d /= float(pts.size())
	var s := 1.0
	if mean_d > 1e-12:
		s = sqrt(2.0) / mean_d
	return { "tx": c.x, "ty": c.y, "s": s }

static func _apply_affine(t: Dictionary, p) -> Vector2:
	var v := p as Vector2
	return Vector2((v.x - float(t["tx"])) * float(t["s"]), (v.y - float(t["ty"])) * float(t["s"]))

static func _affine_to_mat(t: Dictionary) -> Array:
	var s := float(t["s"])
	return [s, 0.0, -s * float(t["tx"]), 0.0, s, -s * float(t["ty"]), 0.0, 0.0, 1.0]

## Gaussian elimination with partial pivoting on an 8x8 system. Returns [] when singular.
static func _solve8(a: Array, b: Array) -> Array:
	var m := []
	for i in 8:
		var row: Array = (a[i] as Array).duplicate()
		row.append(float(b[i]))
		m.append(row)
	for col in 8:
		var piv := col
		for r in range(col + 1, 8):
			if abs(float(m[r][col])) > abs(float(m[piv][col])):
				piv = r
		if abs(float(m[piv][col])) < 1e-12:
			return []
		if piv != col:
			var tmp = m[piv]
			m[piv] = m[col]
			m[col] = tmp
		for r in range(col + 1, 8):
			var f := float(m[r][col]) / float(m[col][col])
			for cc in range(col, 9):
				m[r][cc] = float(m[r][cc]) - f * float(m[col][cc])
	var x := []
	x.resize(8)
	for i in range(7, -1, -1):
		var s := float(m[i][8])
		for j in range(i + 1, 8):
			s -= float(m[i][j]) * float(x[j])
		x[i] = s / float(m[i][i])
	return x

# ── pinhole model (camera AND projector — a projector is a camera run backwards) ─────────────

## Build a pose Transform3D from position + optional look_at (or explicit euler-degrees
## rotation). Looking straight up/down gets a stable fallback up-axis.
static func pose_from(position: Array, look_at, rotation_deg) -> Transform3D:
	var pos := _v3(position, Vector3.ZERO)
	if look_at != null:
		var aim := _v3(look_at, Vector3.ZERO)
		var dir := aim - pos
		if dir.length() < 1e-9:
			return Transform3D(Basis.IDENTITY, pos)
		var up := Vector3.UP
		if abs(dir.normalized().dot(Vector3.UP)) > 0.999:
			up = Vector3(0, 0, -1)
		return Transform3D(Basis.looking_at(dir, up), pos)
	var e := _v3(rotation_deg, Vector3.ZERO)
	var q := Quaternion.from_euler(Vector3(deg_to_rad(e.x), deg_to_rad(e.y), deg_to_rad(e.z)))
	return Transform3D(Basis(q), pos)

## World point -> pixel through a pinhole at `pose` (looks down -Z). Returns
## { "ok": bool (in front), "px": Vector2, "depth": float (positive distance along -Z) }.
static func project_px(pose: Transform3D, yfov_rad: float, aspect: float, res: Vector2, world: Vector3) -> Dictionary:
	var c := pose.affine_inverse() * world
	if c.z >= -1e-9:
		return { "ok": false, "px": Vector2.INF, "depth": 0.0 }
	var ty := tan(yfov_rad * 0.5)
	var ndc_x := (c.x / -c.z) / (ty * aspect)
	var ndc_y := (c.y / -c.z) / ty
	var px := Vector2((ndc_x * 0.5 + 0.5) * res.x, (0.5 - ndc_y * 0.5) * res.y)
	return { "ok": true, "px": px, "depth": -c.z }

## Pixel -> world ray. Returns { "origin": Vector3, "dir": Vector3 (normalized) }.
static func px_ray(pose: Transform3D, yfov_rad: float, aspect: float, res: Vector2, px: Vector2) -> Dictionary:
	var ty := tan(yfov_rad * 0.5)
	var ndc_x := px.x / res.x * 2.0 - 1.0
	var ndc_y := 1.0 - px.y / res.y * 2.0
	var dir_cam := Vector3(ndc_x * ty * aspect, ndc_y * ty, -1.0).normalized()
	return { "origin": pose.origin, "dir": (pose.basis * dir_cam).normalized() }

## Vertical FOV (radians) from a projector THROW RATIO (distance / image width) + aspect.
static func yfov_from_throw(throw_ratio: float, aspect: float) -> float:
	var hfov := 2.0 * atan(1.0 / (2.0 * max(throw_ratio, 1e-6)))
	return 2.0 * atan(tan(hfov * 0.5) / max(aspect, 1e-6))

# ── surfaces (the projection targets): plane + curved (cylindrical section) ──────────────────
## A surface descriptor (DATA on a wire):
##   { "kind": "plane"|"cylinder", "origin": [x,y,z], "rotation": [x,y,z,w] (quat),
##     "size": [w,h] (plane meters | cylinder [arc-ignored, height]),
##     "radius": r, "arc_deg": a (cylinder only) }
## Local frame: u = +X, v = +Y, normal = +Z (plane); cylinder axis = +Y, outward ref = +Z.
## Surface uv ∈ [0,1]^2 spans the extent (u right, v up).

## Point + outward normal at a surface uv. Returns { "point": Vector3, "normal": Vector3 }.
static func surface_point(surface: Dictionary, uv: Vector2) -> Dictionary:
	var o := _v3(surface.get("origin", [0, 0, 0]), Vector3.ZERO)
	var basis := Basis(_quat(surface.get("rotation", [0, 0, 0, 1])))
	var size = surface.get("size", [2.0, 1.5])
	var w := float(size[0])
	var h := float(size[1])
	if String(surface.get("kind", "plane")) == "cylinder":
		var r := float(surface.get("radius", 1.0))
		var arc := deg_to_rad(float(surface.get("arc_deg", 120.0)))
		var ang := (uv.x - 0.5) * arc
		var out := (basis.z).rotated(basis.y, ang)
		var p := o + basis.y * ((uv.y - 0.5) * h) + out * r
		return { "point": p, "normal": out }
	var pt := o + basis.x * ((uv.x - 0.5) * w) + basis.y * ((uv.y - 0.5) * h)
	return { "point": pt, "normal": basis.z }

## Ray-surface intersection. Returns { "hit": bool, "point": Vector3, "uv": Vector2,
## "normal": Vector3, "t": float }. Only front-facing (normal opposing the ray) hits count —
## a projector cannot paint the back of the screen.
static func intersect_surface(surface: Dictionary, origin: Vector3, dir: Vector3) -> Dictionary:
	var miss := { "hit": false, "point": Vector3.ZERO, "uv": Vector2.ZERO, "normal": Vector3.ZERO, "t": 0.0 }
	var o := _v3(surface.get("origin", [0, 0, 0]), Vector3.ZERO)
	var basis := Basis(_quat(surface.get("rotation", [0, 0, 0, 1])))
	var size = surface.get("size", [2.0, 1.5])
	var w := float(size[0])
	var h := float(size[1])
	if String(surface.get("kind", "plane")) == "cylinder":
		return _intersect_cylinder(surface, o, basis, h, origin, dir, miss)
	var n := basis.z
	var denom := dir.dot(n)
	if abs(denom) < 1e-9 or denom > 0.0:
		return miss
	var t := (o - origin).dot(n) / denom
	if t <= 1e-6:
		return miss
	var p := origin + dir * t
	var lu := (p - o).dot(basis.x)
	var lv := (p - o).dot(basis.y)
	if abs(lu) > w * 0.5 or abs(lv) > h * 0.5:
		return miss
	return { "hit": true, "point": p, "uv": Vector2(lu / w + 0.5, lv / h + 0.5), "normal": n, "t": t }

static func _intersect_cylinder(surface: Dictionary, o: Vector3, basis: Basis, h: float,
		origin: Vector3, dir: Vector3, miss: Dictionary) -> Dictionary:
	var r := float(surface.get("radius", 1.0))
	var arc := deg_to_rad(float(surface.get("arc_deg", 120.0)))
	var a := basis.y
	var d := origin - o
	var q := d - a * d.dot(a)
	var m := dir - a * dir.dot(a)
	var aa := m.dot(m)
	if aa < 1e-12:
		return miss
	var bb := 2.0 * q.dot(m)
	var cc := q.dot(q) - r * r
	var disc := bb * bb - 4.0 * aa * cc
	if disc < 0.0:
		return miss
	var sq := sqrt(disc)
	for t in [(-bb - sq) / (2.0 * aa), (-bb + sq) / (2.0 * aa)]:
		if t <= 1e-6:
			continue
		var p: Vector3 = origin + dir * float(t)
		var y := (p - o).dot(a)
		if abs(y) > h * 0.5:
			continue
		var out := (p - o - a * y).normalized()
		if out.dot(dir) > 0.0:
			continue  # back-facing (inside) — projector paints the outside
		var ang := atan2(out.dot(basis.x), out.dot(basis.z))
		if abs(ang) > arc * 0.5:
			continue
		return { "hit": true, "point": p, "uv": Vector2(ang / arc + 0.5, y / h + 0.5),
			"normal": out, "t": float(t) }
	return miss

# ── small shared coercions (wire values are plain Arrays) ────────────────────────────────────

static func _v3(a, fallback: Vector3) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

static func _quat(a) -> Quaternion:
	if a is Array and (a as Array).size() >= 4:
		return Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3])).normalized()
	return Quaternion.IDENTITY
