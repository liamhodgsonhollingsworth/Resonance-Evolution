class_name PrimStereoRender
extends Primitive
## StereoRender — ONE viewing-geometry parameter set (viewer-to-screen distance, IPD, focal/
## convergence plane, depth budget, screen size/DPI — all DATA) drives MULTIPLE stereo output
## modes from the SAME scene:
##   depth map (cyclopean)  →  autostereogram (SIRDS)  ·  side-by-side stereo pair (off-axis,
##   converged at the focal plane)  ·  anaglyph (cheap physical verification).
## The same dict also drives the live/VR camera rig (renderers/stereo_rig.gd) — see
## notes/design/stereogram_vr_viewer_2026-07-02.md for the model + the derivations.
##
## Everything is CPU + deterministic so the whole path is headless-provable: the decoder test
## (headless_stereo_test.gd) measures the stereogram's repeat period and the pair's pixel
## disparity back out of the PNGs and checks them against the closed-form geometry.
##
## Scene input: a renderer-neutral `scene_node` tree (the same descriptors Model/Transform/
## Group/PartsCatalog emit). The CPU depth renderer supports the ANALYTIC subset — primitive
## `sphere` (uniform scale) + `box` (any TRS) — because the proof needs exact expected depths;
## other meshes are skipped and counted in `skipped_nodes` (GPU depth readback is the documented
## follow-up seam; every function below takes a plain depth buffer, so that is a source swap).
##
## params:
##   geometry     — the viewing-geometry dict (see DEFAULT_GEOMETRY); merged over defaults.
##   pattern      — { "seed": int, "strip_px": int (0 = auto: max period in the budget) }.
##   outputs      — Array of "depth" | "stereogram" | "pair" | "anaglyph" (default: all four).
##   out_dir      — where PNGs are written (default user://stereo).
##   basename     — output file stem (default "stereo").
##   pair_layout  — "cross" (left eye's view on the RIGHT half, for cross-eyed free-viewing)
##                  | "parallel" (L|R). Display layout only; geometry is unaffected.
##   background   — [r,g,b] 0..1 for eye renders, or "gradient" (default).
## input ports:
##   scene    — scene_node tree to render.
##   geometry — optional dict wire OVERRIDING params.geometry (a knob node can drive IPD live).
## output port:
##   stereo   — JSON-serializable descriptor: derived geometry, PNG paths + ok flags, depth
##              stats, separation range, skipped_nodes. No Image on the wire (portability).

const DEFAULT_GEOMETRY := {
	"screen_distance_m": 0.6,
	"ipd_m": 0.063,
	"screen_width_m": 0.52,
	"image_width_px": 960,
	"image_height_px": 600,
	"viewing": "cross",           # "parallel" | "cross"
	"display_near_m": 0.40,
	"display_far_m": 0.54,
	"scene_near_m": 0.0,          # 0.0 = auto (min/max of the rendered depth map)
	"scene_far_m": 0.0,
	"znear_m": 0.05,
	"zfar_m": 100.0,
}
const DEFAULT_OUT := "user://stereo"
const ALL_OUTPUTS := ["depth", "stereogram", "pair", "anaglyph"]

func _init() -> void:
	prim_type = "StereoRender"

func input_ports() -> Array:
	return [
		{ "name": "scene", "type": "scene_node" },
		{ "name": "geometry", "type": "any" },
	]

func output_ports() -> Array:
	return [{ "name": "stereo", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var geo_in: Dictionary = params.get("geometry", {})
	var geo_wire = inputs.get("geometry")
	if typeof(geo_wire) == TYPE_DICTIONARY:
		var merged := geo_in.duplicate(true)
		for k in geo_wire:
			merged[k] = geo_wire[k]
		geo_in = merged
	var geo := derive(geo_in)
	var desc := {
		"geometry": geo, "paths": {}, "ok": geo["valid"],
		"depth_stats": {}, "skipped_nodes": 0,
	}
	if not geo["valid"]:
		return { "stereo": desc }

	var scene = inputs.get("scene")
	var collected := collect_shapes(scene)
	desc["skipped_nodes"] = int(collected["skipped"])
	var shapes: Array = collected["shapes"]

	var wanted: Array = params.get("outputs", ALL_OUTPUTS)
	var out_dir := String(params.get("out_dir", DEFAULT_OUT))
	var base := String(params.get("basename", "stereo"))
	_ensure_dir(out_dir)

	# --- depth map (cyclopean) — the shared source for the stereogram ---------------------
	var zbuf := render_depth(shapes, geo)
	var stats := depth_stats(zbuf)
	desc["depth_stats"] = stats
	var vbuf := normalize_depth(zbuf, geo, stats)

	if wanted.has("depth"):
		var dimg := depth_image(vbuf, geo)
		desc["paths"]["depth"] = _save(dimg, out_dir, base + "_depth")
	if wanted.has("stereogram"):
		var pat: Dictionary = params.get("pattern", {})
		var simg := sirds(vbuf, geo, int(pat.get("seed", 7)), int(pat.get("strip_px", 0)))
		desc["paths"]["stereogram"] = _save(simg, out_dir, base + "_sirds")
	if wanted.has("pair") or wanted.has("anaglyph"):
		var style := { "background": params.get("background", "gradient") }
		var left := render_eye(shapes, geo, -geo["ipd_m"] / 2.0, style)
		var right := render_eye(shapes, geo, geo["ipd_m"] / 2.0, style)
		if wanted.has("pair"):
			var pimg := compose_pair(left, right, String(params.get("pair_layout", "cross")))
			desc["paths"]["pair"] = _save(pimg, out_dir, base + "_pair")
		if wanted.has("anaglyph"):
			desc["paths"]["anaglyph"] = _save(anaglyph(left, right), out_dir, base + "_anaglyph")

	var all_ok: bool = true
	for k in desc["paths"]:
		all_ok = all_ok and String(desc["paths"][k]) != ""
	desc["ok"] = all_ok
	return { "stereo": desc }

# =============================== geometry (the ONE model) ===============================

## Fill defaults + derived quantities + validity. Pure; safe for tests and downstream nodes.
static func derive(geo_in: Dictionary) -> Dictionary:
	var g := DEFAULT_GEOMETRY.duplicate(true)
	for k in geo_in:
		g[k] = geo_in[k]
	var w_px := int(g["image_width_px"])
	var h_px := int(g["image_height_px"])
	var w_m := float(g["screen_width_m"])
	g["ppm"] = float(w_px) / w_m
	g["screen_height_m"] = float(h_px) / float(g["ppm"])
	var errors: Array = []
	var d := float(g["screen_distance_m"])
	var zn := float(g["display_near_m"])
	var zf := float(g["display_far_m"])
	if not (zn > 0.0 and zf > zn):
		errors.append("display budget must satisfy 0 < near < far")
	if String(g["viewing"]) == "parallel" and zn <= d:
		errors.append("parallel viewing needs the budget behind the screen (display_near_m > screen_distance_m)")
	if String(g["viewing"]) == "cross" and zf >= d:
		errors.append("cross viewing needs the budget in front of the screen (display_far_m < screen_distance_m)")
	if float(g["ipd_m"]) <= 0.0 or d <= 0.0 or w_m <= 0.0 or w_px <= 0 or h_px <= 0:
		errors.append("ipd/distance/screen/image sizes must be positive")
	g["errors"] = errors
	g["valid"] = errors.is_empty()
	if g["valid"]:
		g["sep_near_px"] = separation_px(g, zn)
		g["sep_far_px"] = separation_px(g, zf)
	return g

## Autostereogram repeat period (pixels) for a point at viewer-distance z_m.
## parallel: s = ppm·e·(Z−D)/Z   ·   cross: s = ppm·e·(D−Z)/Z   (both positive in their budget).
static func separation_px(geo: Dictionary, z_m: float) -> float:
	var d := float(geo["screen_distance_m"])
	var e := float(geo["ipd_m"])
	var ppm := float(geo["ppm"])
	if String(geo["viewing"]) == "parallel":
		return ppm * e * (z_m - d) / z_m
	return ppm * e * (d - z_m) / z_m

## Stereo-pair pixel disparity d(Z) = u_L − u_R = ppm·e·(D−Z)/Z (signed; + = crossed/near).
static func pair_disparity_px(geo: Dictionary, z_m: float) -> float:
	var d := float(geo["screen_distance_m"])
	return float(geo["ppm"]) * float(geo["ipd_m"]) * (d - z_m) / z_m

## Depth value v∈[0,1] (1 = near) → display distance, linear in 1/Z (disparity-linear).
static func depth_to_display_z(geo: Dictionary, v: float) -> float:
	var inv_n := 1.0 / float(geo["display_near_m"])
	var inv_f := 1.0 / float(geo["display_far_m"])
	return 1.0 / (inv_f + clampf(v, 0.0, 1.0) * (inv_n - inv_f))

# =============================== scene → analytic shapes ===============================

## Walk a scene_node tree, composing TRS, collecting the analytic subset:
##   { kind:"sphere", center:Vector3, radius:float, color:Color }
##   { kind:"box", to_local:Transform3D, half:Vector3, color:Color }
## Returns { "shapes": Array, "skipped": int }.
static func collect_shapes(desc) -> Dictionary:
	var shapes: Array = []
	var skipped := [0]
	if typeof(desc) == TYPE_DICTIONARY:
		_collect(desc, Transform3D.IDENTITY, shapes, skipped)
	return { "shapes": shapes, "skipped": skipped[0] }

static func _collect(desc: Dictionary, parent: Transform3D, into: Array, skipped: Array) -> void:
	var t := _vec3(desc.get("translation"), Vector3.ZERO)
	var q := _quat(desc.get("rotation"))
	var s := _vec3(desc.get("scale"), Vector3.ONE)
	var xf := parent * Transform3D(Basis(q).scaled(s), t)
	var mesh = desc.get("mesh")
	if typeof(mesh) == TYPE_DICTIONARY and String(mesh.get("source", "")) == "primitive":
		var p: Dictionary = mesh.get("params", {}) if typeof(mesh.get("params")) == TYPE_DICTIONARY else {}
		var color := _color(p.get("color"))
		match String(mesh.get("shape", "")):
			"sphere":
				# Uniform scale assumed for the analytic proof (documented restriction).
				into.append({
					"kind": "sphere",
					"center": xf.origin,
					"radius": float(p.get("radius", 0.5)) * xf.basis.get_scale().x,
					"color": color,
				})
			"box", "cube":
				var half := Vector3(float(p.get("width", 1.0)), float(p.get("height", 1.0)), float(p.get("depth", 1.0))) / 2.0
				into.append({ "kind": "box", "to_local": xf.affine_inverse(), "half": half, "color": color })
			_:
				skipped[0] += 1
	elif typeof(mesh) == TYPE_DICTIONARY:
		skipped[0] += 1
	for c in desc.get("children", []):
		if typeof(c) == TYPE_DICTIONARY:
			_collect(c, xf, into, skipped)

# =============================== CPU raycast core ===============================

## Nearest hit of ray (origin o, unit dir dir) against the shapes.
## Returns { t, normal, color } or {} on miss.
static func _ray_hit(shapes: Array, o: Vector3, dir: Vector3) -> Dictionary:
	var best_t := INF
	var best := {}
	for sh in shapes:
		if sh["kind"] == "sphere":
			var oc: Vector3 = o - sh["center"]
			var r: float = sh["radius"]
			var b := oc.dot(dir)
			var c := oc.dot(oc) - r * r
			var disc := b * b - c
			if disc >= 0.0:
				var t := -b - sqrt(disc)
				if t > 1e-6 and t < best_t:
					best_t = t
					var p := o + dir * t
					best = { "t": t, "normal": (p - sh["center"]).normalized(), "color": sh["color"] }
		else:  # box (slab test in local frame)
			var inv: Transform3D = sh["to_local"]
			var lo := inv * o
			var ld: Vector3 = inv.basis * dir      # direction: basis only (no translation)
			var half: Vector3 = sh["half"]
			var tmin := -INF
			var tmax := INF
			var nmin := Vector3.ZERO
			var inside := true
			for ax in 3:
				var loa := lo[ax]
				var lda := ld[ax]
				if absf(lda) < 1e-12:
					if absf(loa) > half[ax]:
						inside = false
						break
					continue
				var t1 := (-half[ax] - loa) / lda
				var t2 := (half[ax] - loa) / lda
				var n := Vector3.ZERO
				n[ax] = -signf(lda)
				if t1 > t2:
					var tmp := t1; t1 = t2; t2 = tmp
				if t1 > tmin:
					tmin = t1
					nmin = n
				tmax = minf(tmax, t2)
				if tmin > tmax:
					inside = false
					break
			if inside and tmax > 1e-6 and tmin > 1e-6 and tmin < best_t:
				best_t = tmin
				# Normal back to world space (rotation part of the box's world transform).
				var wn: Vector3 = (inv.affine_inverse().basis * nmin).normalized()
				best = { "t": tmin, "normal": wn, "color": sh["color"] }
	return best

## Screen-window point for pixel (i,j): the physical position on the screen plane z = −D.
static func _screen_point(geo: Dictionary, i: int, j: int) -> Vector3:
	var w_m := float(geo["screen_width_m"])
	var h_m := float(geo["screen_height_m"])
	var w := int(geo["image_width_px"])
	var h := int(geo["image_height_px"])
	var x := (float(i) + 0.5) / float(w) * w_m - w_m / 2.0
	var y := h_m / 2.0 - (float(j) + 0.5) / float(h) * h_m
	return Vector3(x, y, -float(geo["screen_distance_m"]))

## Cyclopean depth render: viewer-distance Z (= −hit.z) per pixel; INF on miss.
static func render_depth(shapes: Array, geo: Dictionary) -> PackedFloat32Array:
	var w := int(geo["image_width_px"])
	var h := int(geo["image_height_px"])
	var buf := PackedFloat32Array()
	buf.resize(w * h)
	var o := Vector3.ZERO
	for j in h:
		for i in w:
			var dir := _screen_point(geo, i, j).normalized()
			var hit := _ray_hit(shapes, o, dir)
			buf[j * w + i] = (-(o + dir * hit["t"]).z) if not hit.is_empty() else INF
	return buf

static func depth_stats(zbuf: PackedFloat32Array) -> Dictionary:
	var mn := INF
	var mx := -INF
	var covered := 0
	for z in zbuf:
		if z != INF:
			covered += 1
			mn = minf(mn, z)
			mx = maxf(mx, z)
	return { "min_z_m": (mn if covered > 0 else 0.0), "max_z_m": (mx if covered > 0 else 0.0),
		"coverage": float(covered) / maxf(1.0, float(zbuf.size())) }

## Scene Z buffer → normalized v∈[0,1] (1 = near), linear in 1/Z over the scene range.
## Misses map to v = 0 (the far plane of the budget).
static func normalize_depth(zbuf: PackedFloat32Array, geo: Dictionary, stats: Dictionary) -> PackedFloat32Array:
	var sn := float(geo["scene_near_m"])
	var sf := float(geo["scene_far_m"])
	if sn <= 0.0 or sf <= 0.0 or sf <= sn:
		sn = float(stats["min_z_m"])
		sf = float(stats["max_z_m"])
	var out := PackedFloat32Array()
	out.resize(zbuf.size())
	if sn <= 0.0 or sf <= sn:  # empty / degenerate scene: everything far
		out.fill(0.0)
		return out
	var inv_n := 1.0 / sn
	var inv_f := 1.0 / sf
	for k in zbuf.size():
		var z := zbuf[k]
		out[k] = 0.0 if z == INF else clampf((1.0 / z - inv_f) / (inv_n - inv_f), 0.0, 1.0)
	return out

static func depth_image(vbuf: PackedFloat32Array, geo: Dictionary) -> Image:
	var w := int(geo["image_width_px"])
	var h := int(geo["image_height_px"])
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for j in h:
		for i in w:
			var v := vbuf[j * w + i]
			img.set_pixel(i, j, Color(v, v, v))
	return img

# =============================== mode (a): autostereogram ===============================

## Classic SIRDS over a normalized depth buffer. Per row, left-to-right back-reference:
##   s = round(s_px(Z(v)));  img[x] = x ≥ s ? img[x−s] : pattern[x mod strip, y]
## strip_px 0 = auto (max period in the budget). Deterministic for a given seed.
static func sirds(vbuf: PackedFloat32Array, geo: Dictionary, seed_v: int = 7, strip_px: int = 0) -> Image:
	var w := int(geo["image_width_px"])
	var h := int(geo["image_height_px"])
	var strip := strip_px
	if strip <= 0:
		strip = int(ceilf(maxf(float(geo["sep_near_px"]), float(geo["sep_far_px"])))) + 1
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	# Full-height random pattern strip (per-pixel random => no vertical repetition).
	var pattern := Image.create(strip, h, false, Image.FORMAT_RGB8)
	for j in h:
		for i in strip:
			pattern.set_pixel(i, j, Color8(rng.randi_range(0, 255), rng.randi_range(0, 255), rng.randi_range(0, 255)))
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for j in h:
		for i in w:
			var z := depth_to_display_z(geo, vbuf[j * w + i])
			var s := int(roundf(separation_px(geo, z)))
			if s > 0 and i >= s:
				img.set_pixel(i, j, img.get_pixel(i - s, j))
			else:
				img.set_pixel(i, j, pattern.get_pixel(i % strip, j))
	return img

# =============================== mode (b): stereo pair ===============================

## One eye render: pinhole at (eye_x, 0, 0) shooting through the SAME physical screen window
## (off-axis frustum — convergence exactly at the screen/focal plane, no toe-in).
static func render_eye(shapes: Array, geo: Dictionary, eye_x: float, style: Dictionary = {}) -> Image:
	var w := int(geo["image_width_px"])
	var h := int(geo["image_height_px"])
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var o := Vector3(eye_x, 0.0, 0.0)
	var light := Vector3(-0.45, 0.7, 0.55).normalized()
	var bg = style.get("background", "gradient")
	for j in h:
		var bg_col: Color
		if bg is Array and (bg as Array).size() >= 3:
			bg_col = Color(float(bg[0]), float(bg[1]), float(bg[2]))
		else:
			var f := float(j) / maxf(1.0, float(h - 1))
			bg_col = Color(0.07, 0.08, 0.11).lerp(Color(0.13, 0.15, 0.20), f)
		for i in w:
			var dir := (_screen_point(geo, i, j) - o).normalized()
			var hit := _ray_hit(shapes, o, dir)
			if hit.is_empty():
				img.set_pixel(i, j, bg_col)
			else:
				var ndl := maxf(0.0, (hit["normal"] as Vector3).dot(light))
				var c: Color = hit["color"]
				img.set_pixel(i, j, Color(
					clampf(c.r * (0.25 + 0.75 * ndl), 0.0, 1.0),
					clampf(c.g * (0.25 + 0.75 * ndl), 0.0, 1.0),
					clampf(c.b * (0.25 + 0.75 * ndl), 0.0, 1.0)))
	return img

## Side-by-side compose. layout "cross" puts the LEFT eye's image on the RIGHT half (so
## crossing your eyes fuses it); "parallel" keeps L|R. 4px gutter.
static func compose_pair(left: Image, right: Image, layout: String = "cross") -> Image:
	var w := left.get_width()
	var h := left.get_height()
	var gutter := 4
	var img := Image.create(w * 2 + gutter, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.02, 0.02, 0.02))
	var first := right if layout == "cross" else left
	var second := left if layout == "cross" else right
	img.blit_rect(first, Rect2i(0, 0, w, h), Vector2i(0, 0))
	img.blit_rect(second, Rect2i(0, 0, w, h), Vector2i(w + gutter, 0))
	return img

# =============================== mode (c): anaglyph ===============================

## Red/cyan channel compose: R ← left.r, G/B ← right.g/b. Exact (unit-testable) by design.
static func anaglyph(left: Image, right: Image) -> Image:
	var w := left.get_width()
	var h := left.get_height()
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for j in h:
		for i in w:
			var l := left.get_pixel(i, j)
			var r := right.get_pixel(i, j)
			img.set_pixel(i, j, Color(l.r, r.g, r.b))
	return img

# =============================== helpers ===============================

static func _save(img: Image, out_dir: String, stem: String) -> String:
	var path := out_dir.path_join(stem + ".png")
	var err := img.save_png(path)
	return path if err == OK and FileAccess.file_exists(path) else ""

static func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(abs)

static func _vec3(a, fallback: Vector3) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback

static func _quat(a) -> Quaternion:
	if a is Array and (a as Array).size() >= 4:
		return Quaternion(float(a[0]), float(a[1]), float(a[2]), float(a[3])).normalized()
	return Quaternion.IDENTITY

static func _color(a) -> Color:
	if a is Array and (a as Array).size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(0.82, 0.82, 0.84)
