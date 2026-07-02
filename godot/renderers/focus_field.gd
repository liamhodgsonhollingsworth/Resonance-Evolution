class_name FocusField
extends RefCounted
## CAMERA FOCUS / DEPTH-OF-FIELD as a DETAIL FIELD — the second concrete instantiation of the generic
## detail-falloff seam (after PainterlyFalloff's screen-space curves): here the per-pixel detail budget
## comes from DEPTH. d(x,y) = detail_knob × focus(depth(x,y)) where `focus` is a response curve peaked
## at `focal_distance` and widened by `focal_depth` — pixels near the focal plane get full detail
## (sharp), pixels far from it get none (blurred). The SAME single detail-knob from PR #121 composes in
## front: turn the knob down and the whole frame loses detail budget (knob=0 → everything out of focus).
##
## Everything is DATA (the arrangement-JSON `focus` block): focal_distance + focal_depth + depth_range
## are plain numbers Liam iterates in the hot-reload params file; the depth source is an IMAGE (grayscale,
## 0..1 mapped over depth_range), so any producer works — the demo scene captures true per-pixel depth
## from the render, the headless test synthesizes a ramp. CPU-only (pure Image math, headless-safe), the
## same reference-oracle discipline as EffectStackCpu / PainterlyFalloff: a GPU/shader DOF delegate later
## consumes the SAME focus descriptor with zero caller change.
##
## THE MECHANISM (deliberately the PainterlyFalloff two-pole blend, reused shape-for-shape):
##   1. blur the source once (separable box blur, radius = `blur_radius` — the out-of-focus pole);
##   2. build the per-pixel field d = knob × focus(depth);
##   3. per-pixel blend: out(x,y) = lerp(blurred, sharp, d(x,y)).
## Two poles + a field blend is the minimal thing that makes "focus visibly shifts with the knob" TRUE;
## a physically-based CoC kernel later plugs in behind the SAME field seam.

## The focus response: 1.0 on the focal plane, a plateau of full sharpness for |depth-focal_distance| up
## to 0.5×focal_depth, feathered smoothly to 0.0 by 1.5×focal_depth. Monotone in |Δdepth|; focal_depth
## is the aperture-like knob — wider = deeper in-focus band (a small aperture), narrower = thin slice.
static func response(depth: float, focal_distance: float, focal_depth: float) -> float:
	var x := absf(depth - focal_distance) / maxf(0.0001, focal_depth)
	return clampf(1.0 - smoothstep(0.5, 1.5, x), 0.0, 1.0)

## Build the per-pixel detail field from a grayscale DEPTH image. `depth_img` gray 0..1 maps linearly
## over `depth_range` = [near, far] (world units); `focus` = { focal_distance, focal_depth, depth_range }.
## Returns a PackedFloat32Array (w*h, row-major) — the same field shape DetailField.build emits, so the
## debug view (DetailField.to_debug_image) and any field consumer work on it unchanged.
static func build(depth_img: Image, detail_knob: float, focus: Dictionary) -> PackedFloat32Array:
	var f: Dictionary = focus if typeof(focus) == TYPE_DICTIONARY else {}
	var fd := float(f.get("focal_distance", 6.0))
	var fw := float(f.get("focal_depth", 2.0))
	var rng: Array = f.get("depth_range", [0.0, 1.0])
	var near := float(rng[0]) if rng.size() >= 1 else 0.0
	var far := float(rng[1]) if rng.size() >= 2 else 1.0
	var knob := clampf(detail_knob, 0.0, 1.0)
	var w := depth_img.get_width()
	var h := depth_img.get_height()
	var field := PackedFloat32Array()
	field.resize(w * h)
	var i := 0
	for y in h:
		for x in w:
			var g := depth_img.get_pixel(x, y).r
			var depth := near + g * (far - near)
			field[i] = knob * response(depth, fd, fw)
			i += 1
	return field

## Separable box blur (horizontal then vertical pass), radius in pixels — the out-of-focus pole.
## radius <= 0 returns a copy. Returns a NEW Image (src untouched).
static func blur(src: Image, radius: int) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	if radius <= 0:
		return src.duplicate()
	var tmp := Image.create(w, h, false, src.get_format())
	var out := Image.create(w, h, false, src.get_format())
	for y in h:
		for x in w:
			var acc := Color(0, 0, 0, 0)
			var n := 0
			for k in range(-radius, radius + 1):
				var xx := clampi(x + k, 0, w - 1)
				acc += src.get_pixel(xx, y)
				n += 1
			tmp.set_pixel(x, y, acc / float(n))
	for y in h:
		for x in w:
			var acc := Color(0, 0, 0, 0)
			var n := 0
			for k in range(-radius, radius + 1):
				var yy := clampi(y + k, 0, h - 1)
				acc += tmp.get_pixel(x, yy)
				n += 1
			out.set_pixel(x, y, acc / float(n))
	return out

## Per-pixel blend of the two poles by the field: out = lerp(blurred, sharp, d). The exact blend shape
## PainterlyFalloff.paint uses — d≈1 pixels stay sharp, d≈0 pixels take the blurred pole.
static func blend(sharp: Image, blurred: Image, field: PackedFloat32Array) -> Image:
	var w := sharp.get_width()
	var h := sharp.get_height()
	var out := Image.create(w, h, false, sharp.get_format())
	var i := 0
	for y in h:
		for x in w:
			var d := field[i] if i < field.size() else 0.0
			var sc := sharp.get_pixel(x, y)
			var bc := blurred.get_pixel(x, y)
			out.set_pixel(x, y, Color(
				lerpf(bc.r, sc.r, d),
				lerpf(bc.g, sc.g, d),
				lerpf(bc.b, sc.b, d),
				lerpf(bc.a, sc.a, d)
			))
			i += 1
	return out

## The one entry point: paint `src` with depth-of-field from `depth_img` + the `cfg` DATA block
## ({ detail_knob, blur_radius, focus:{focal_distance, focal_depth, depth_range} }). Returns a NEW Image.
static func paint(src: Image, depth_img: Image, cfg: Dictionary) -> Image:
	var knob := float(cfg.get("detail_knob", 1.0))
	var radius := int(cfg.get("blur_radius", 6))
	var focus: Dictionary = cfg.get("focus", {})
	var field := build(depth_img, knob, focus)
	var blurred := blur(src, radius)
	return blend(src, blurred, field)
