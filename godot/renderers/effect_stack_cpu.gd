class_name EffectStackCpu
extends RefCounted
## The CPU REFERENCE applier for an `effect_stack` descriptor — the 2D analogue of
## GodotSceneRenderer (the 3D delegate). It consumes a renderer-neutral effect_stack (pure DATA,
## emitted by PrimEffectStack) plus a source Image, and returns a NEW Image with the stack's layers
## applied IN ORDER. It is deliberately renderer-neutral and dependency-free: plain CPU pixel math on
## a Godot `Image`, no shaders, no GPU, no Compositor — so it runs HEADLESS and serves as the
## ground-truth oracle a GPU/shader delegate (Godot CompositorEffect / three.js postprocessing) must
## match, exactly like the glTF exporter is the oracle for the 3D renderer.
##
## WHY a CPU reference first: the look lives in the DATA, so the FIRST iterable increment only needs
## *an* applier that proves order + knobs are honoured. The fast GPU path is a swappable delegate
## added LATER against this same descriptor — no caller change (PROGRESS.md "thin swappable delegates").
##
## EFFECT REGISTRY (this is where new painterly layers land — each a new branch here + its GPU twin,
## never an edit to the primitive). EFFECT_TYPES below is the machine-readable mirror the evolver reads
## to know the vocabulary + each effect's param schema:
##   "passthrough"  — identity (the no-op floor; proves ordering is observable).
##   "posterize"    — palette quantization: snap each RGB channel to `levels` bands. params.levels:int>=2.
##   "kuwahara"     — classic 4-quadrant edge-preserving smoothing: each pixel becomes the mean of the
##                    least-variance quadrant of its (radius) neighbourhood. Flattens flat regions while
##                    keeping edges crisp → the canonical "oil-painting" / brush-flattened look.
##                    params.radius:int>=1.
##   "generalized_kuwahara" — anisotropic Kuwahara approximation: 8 overlapping sectors instead of 4
##                    quadrants → smoother, more brush-like strokes that follow local structure. Same
##                    least-variance pick, finer directionality. params.radius:int>=1, params.sectors:int.
##   "edge_darken"  — watercolor edge-darkening: multiply each pixel's RGB toward black in proportion to
##                    the local Sobel edge magnitude (Apeiron's ID-edge outline, intensity-driven). Gives
##                    the pigment-pooling-at-edges look. params.strength:float (0..1+), params.threshold:float.
##   "outline"      — pure edge map: Sobel edge magnitude rendered as a (color) line over a (bg) fill.
##                    The structural/ink-outline layer. params.threshold:float, params.color, params.bg.
##   "paper_grain"  — paper-texture grain: a deterministic value-noise field multiplied onto luminance,
##                    so the look "sits on paper". Seeded → reproducible (an evolvable knob). params.seed,
##                    params.amount:float (0..1), params.scale:float.
##   LATER (deferred): normal-mapping + lighting + temporal coherence as their OWN later layers (require
##                    depth/normal/motion channels the source frame doesn't yet carry — out of scope here).

## Machine-readable vocabulary + param schema, read by EffectGenome (the evolver) so the genome's
## mutate/crossover stays in sync with what the applier actually understands — adding an effect here is
## the SINGLE edit that teaches both the applier and the evolver about it (no parallel list to drift).
## Each entry: { "params": { name -> { "type", "min", "max", "default" } } }. Numeric params carry a
## range the mutator samples within; "int" params are rounded. Params with no range are left untouched
## by the generic mutator (the evolver only perturbs declared numeric knobs — no auto-generalization).
const EFFECT_TYPES := {
	"passthrough": { "params": {} },
	"posterize": { "params": {
		"levels": { "type": "int", "min": 2, "max": 16, "default": 4 },
	} },
	"kuwahara": { "params": {
		"radius": { "type": "int", "min": 1, "max": 6, "default": 2 },
	} },
	"generalized_kuwahara": { "params": {
		"radius": { "type": "int", "min": 1, "max": 6, "default": 3 },
		"sectors": { "type": "int", "min": 4, "max": 8, "default": 8 },
	} },
	"edge_darken": { "params": {
		"strength": { "type": "float", "min": 0.0, "max": 2.0, "default": 1.0 },
		"threshold": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.1 },
	} },
	"outline": { "params": {
		"threshold": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.25 },
	} },
	"paper_grain": { "params": {
		"amount": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.15 },
		"scale": { "type": "float", "min": 1.0, "max": 32.0, "default": 8.0 },
		"seed": { "type": "int", "min": 0, "max": 65535, "default": 1337 },
	} },
}

## Apply an effect_stack descriptor to a source Image, returning a NEW Image (source untouched).
## Unknown effect types are skipped with a warning (forward-compatible: a descriptor authored against
## a richer delegate still runs the layers THIS applier understands, the rest are no-ops here).
static func apply(desc: Dictionary, src: Image) -> Image:
	var img := src.duplicate() as Image
	for layer in desc.get("stack", []):
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = layer.get("params", {})
		match String(layer.get("type", "passthrough")):
			"passthrough":
				pass
			"posterize":
				_posterize(img, p)
			"kuwahara":
				img = _kuwahara(img, p)
			"generalized_kuwahara":
				img = _generalized_kuwahara(img, p)
			"edge_darken":
				img = _edge_darken(img, p)
			"outline":
				img = _outline(img, p)
			"paper_grain":
				_paper_grain(img, p)
			_:
				push_warning("EffectStackCpu: unknown effect '%s' (skipped)" % layer.get("type"))
	return img

# ---------------------------------------------------------------------------------------------------
# posterize (L0) — per-pixel palette quantization
# ---------------------------------------------------------------------------------------------------

## Palette quantization: each channel snapped to one of `levels` evenly-spaced bands. levels=2 →
## hard 2-tone per channel; higher levels → smoother. Pure per-pixel function (no neighbourhood), so
## it is order-independent of itself and trivially correct to verify. Mutates `img` in place.
static func _posterize(img: Image, params: Dictionary) -> void:
	var levels := int(params.get("levels", 4))
	if levels < 2:
		levels = 2
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(
				_quantize(c.r, levels),
				_quantize(c.g, levels),
				_quantize(c.b, levels),
				c.a
			))

## Snap a [0,1] value to the nearest of `levels` evenly-spaced bands at 0, 1/(L-1), ..., 1. So a
## channel value is reduced to one of L discrete tones — the defining operation of posterization.
static func _quantize(v: float, levels: int) -> float:
	var steps := float(levels - 1)
	return round(clampf(v, 0.0, 1.0) * steps) / steps

# ---------------------------------------------------------------------------------------------------
# kuwahara (L2) — edge-preserving smoothing (the brush-flattening oil-paint look)
# ---------------------------------------------------------------------------------------------------

## Classic Kuwahara filter. For each pixel, consider the four overlapping (radius+1)x(radius+1)
## quadrants that share the centre pixel (top-left, top-right, bottom-left, bottom-right). Compute the
## mean colour + luminance variance of each quadrant; output the MEAN of the quadrant with the LOWEST
## variance. This averages within flat regions (smoothing) but, at an edge, the lowest-variance
## quadrant lies on one side of the edge → the edge is preserved. The canonical painterly smoother.
## Reads from a snapshot (the input image) and writes a fresh output → a true convolution, not in-place
## corruption. Returns a NEW image. CC0 algorithm (Kuwahara et al., 1976).
static func _kuwahara(img: Image, params: Dictionary) -> Image:
	var radius := int(params.get("radius", 2))
	if radius < 1:
		radius = 1
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, img.get_format())
	# The four quadrant offset windows, each [x0,x1,y0,y1] relative to the centre pixel.
	var quadrants := [
		[-radius, 0, -radius, 0],  # top-left
		[0, radius, -radius, 0],   # top-right
		[-radius, 0, 0, radius],   # bottom-left
		[0, radius, 0, radius],    # bottom-right
	]
	for y in h:
		for x in w:
			var best_var := INF
			var best := img.get_pixel(x, y)
			for q in quadrants:
				var res := _region_mean_variance(img, x, y, q[0], q[1], q[2], q[3], w, h)
				if res["var"] < best_var:
					best_var = res["var"]
					best = res["mean"]
			out.set_pixel(x, y, best)
	return out

## Anisotropic / generalized Kuwahara approximation. Instead of 4 axis-aligned quadrants, sample
## `sectors` (4..8) overlapping angular sectors of the radius disc around the centre and pick the
## lowest-variance sector's mean. More sectors → directionality follows local structure → smoother,
## more brush-stroke-like result than the blocky 4-quadrant classic. A faithful-enough CPU oracle of
## the generalized/anisotropic Kuwahara family (Papari et al., 2007) without the full structure tensor
## (the GPU delegate can add the tensor-steered weighting later against this same descriptor).
static func _generalized_kuwahara(img: Image, params: Dictionary) -> Image:
	var radius := int(params.get("radius", 3))
	if radius < 1:
		radius = 1
	var sectors := int(params.get("sectors", 8))
	if sectors < 4:
		sectors = 4
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, img.get_format())
	var two_pi := TAU
	for y in h:
		for x in w:
			# Accumulate per-sector sums; assign each disc pixel to the sector its angle falls in.
			var sum_r := []
			var sum_g := []
			var sum_b := []
			var sum_a := []
			var sum_l := []
			var sum_l2 := []
			var cnt := []
			sum_r.resize(sectors); sum_g.resize(sectors); sum_b.resize(sectors); sum_a.resize(sectors)
			sum_l.resize(sectors); sum_l2.resize(sectors); cnt.resize(sectors)
			for i in sectors:
				sum_r[i] = 0.0; sum_g[i] = 0.0; sum_b[i] = 0.0; sum_a[i] = 0.0
				sum_l[i] = 0.0; sum_l2[i] = 0.0; cnt[i] = 0
			for dy in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					if dx * dx + dy * dy > radius * radius:
						continue
					var sx := clampi(x + dx, 0, w - 1)
					var sy := clampi(y + dy, 0, h - 1)
					var c := img.get_pixel(sx, sy)
					var lum := _luma(c)
					var si := 0
					if dx != 0 or dy != 0:
						var ang := atan2(float(dy), float(dx))  # -PI..PI
						if ang < 0.0:
							ang += two_pi
						si = int(floor(ang / two_pi * float(sectors))) % sectors
					sum_r[si] += c.r; sum_g[si] += c.g; sum_b[si] += c.b; sum_a[si] += c.a
					sum_l[si] += lum; sum_l2[si] += lum * lum; cnt[si] += 1
			var best_var := INF
			var best := img.get_pixel(x, y)
			for i in sectors:
				if cnt[i] == 0:
					continue
				var n := float(cnt[i])
				var mean_l: float = sum_l[i] / n
				var variance: float = max(0.0, sum_l2[i] / n - mean_l * mean_l)
				if variance < best_var:
					best_var = variance
					best = Color(sum_r[i] / n, sum_g[i] / n, sum_b[i] / n, sum_a[i] / n)
			out.set_pixel(x, y, best)
	return out

## Mean colour + luminance variance of a rectangular region clamped to image bounds. Returns
## { "mean": Color, "var": float }. Shared by the classic Kuwahara quadrants.
static func _region_mean_variance(img: Image, cx: int, cy: int, x0: int, x1: int, y0: int, y1: int, w: int, h: int) -> Dictionary:
	var sr := 0.0; var sg := 0.0; var sb := 0.0; var sa := 0.0
	var sl := 0.0; var sl2 := 0.0
	var n := 0
	for dy in range(y0, y1 + 1):
		for dx in range(x0, x1 + 1):
			var sx := clampi(cx + dx, 0, w - 1)
			var sy := clampi(cy + dy, 0, h - 1)
			var c := img.get_pixel(sx, sy)
			var lum := _luma(c)
			sr += c.r; sg += c.g; sb += c.b; sa += c.a
			sl += lum; sl2 += lum * lum
			n += 1
	if n == 0:
		return { "mean": img.get_pixel(cx, cy), "var": INF }
	var fn := float(n)
	var mean_l := sl / fn
	var variance: float = max(0.0, sl2 / fn - mean_l * mean_l)
	return { "mean": Color(sr / fn, sg / fn, sb / fn, sa / fn), "var": variance }

# ---------------------------------------------------------------------------------------------------
# edge_darken (L2) — watercolor pigment-pooling-at-edges
# ---------------------------------------------------------------------------------------------------

## Watercolor edge-darkening. Compute the Sobel luminance-gradient magnitude at each pixel; where it
## exceeds `threshold`, darken the pixel's RGB toward black in proportion to (magnitude * strength).
## Mimics watercolour pigment pooling / darkening along contours. Reads luminance from the input
## snapshot, writes a fresh output. CC0 (Sobel operator). Returns a NEW image.
static func _edge_darken(img: Image, params: Dictionary) -> Image:
	var strength := float(params.get("strength", 1.0))
	var threshold := float(params.get("threshold", 0.1))
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var mag := _sobel_magnitude(img, x, y, w, h)
			var e: float = max(0.0, mag - threshold)
			var darken := clampf(e * strength, 0.0, 1.0)
			var k := 1.0 - darken
			out.set_pixel(x, y, Color(c.r * k, c.g * k, c.b * k, c.a))
	return out

# ---------------------------------------------------------------------------------------------------
# outline (L2) — pure edge map (ink-line layer)
# ---------------------------------------------------------------------------------------------------

## Pure edge map: where the Sobel magnitude exceeds `threshold`, paint `color` (default black, opaque);
## elsewhere paint `bg` (default fully transparent, so the outline composites over the layer below).
## color/bg are [r,g,b,a] arrays in the descriptor (JSON-portable). Returns a NEW image.
static func _outline(img: Image, params: Dictionary) -> Image:
	var threshold := float(params.get("threshold", 0.25))
	var color := _color_param(params.get("color", [0.0, 0.0, 0.0, 1.0]), Color(0, 0, 0, 1))
	var bg := _color_param(params.get("bg", [0.0, 0.0, 0.0, 0.0]), Color(0, 0, 0, 0))
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			var mag := _sobel_magnitude(img, x, y, w, h)
			out.set_pixel(x, y, color if mag >= threshold else bg)
	return out

# ---------------------------------------------------------------------------------------------------
# paper_grain (L2) — deterministic paper-texture grain over luminance
# ---------------------------------------------------------------------------------------------------

## Paper-texture grain: a deterministic value-noise field (seeded → reproducible) multiplied onto each
## pixel's RGB so the image "sits on paper". `amount` is the depth of the grain (0 = none), `scale` the
## noise cell size in pixels, `seed` the reproducibility knob (an evolvable param). Per-pixel given the
## noise field, so it mutates `img` in place. The noise is plain integer-hash value noise — no Godot
## Noise resource — so it is identical across renderers (the portability law).
static func _paper_grain(img: Image, params: Dictionary) -> void:
	var amount := clampf(float(params.get("amount", 0.15)), 0.0, 1.0)
	var scale: float = max(1.0, float(params.get("scale", 8.0)))
	var seed := int(params.get("seed", 1337))
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var n := _value_noise(float(x) / scale, float(y) / scale, seed)  # 0..1
			# Centre the grain around 1.0 so amount=0 is identity and grain both lightens + darkens.
			var factor := 1.0 + (n - 0.5) * 2.0 * amount
			factor = clampf(factor, 0.0, 2.0)
			var c := img.get_pixel(x, y)
			img.set_pixel(x, y, Color(
				clampf(c.r * factor, 0.0, 1.0),
				clampf(c.g * factor, 0.0, 1.0),
				clampf(c.b * factor, 0.0, 1.0),
				c.a
			))

# ---------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------

## Rec.601 luminance of a colour — the perceptual grey used by every neighbourhood effect.
static func _luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

## Sobel luminance-gradient magnitude at (x,y), clamped to image bounds. The standard 3x3 Sobel pair.
static func _sobel_magnitude(img: Image, x: int, y: int, w: int, h: int) -> float:
	var l := func(ix: int, iy: int) -> float:
		return _luma(img.get_pixel(clampi(ix, 0, w - 1), clampi(iy, 0, h - 1)))
	var tl: float = l.call(x - 1, y - 1); var tc: float = l.call(x, y - 1); var tr: float = l.call(x + 1, y - 1)
	var ml: float = l.call(x - 1, y);     var mr: float = l.call(x + 1, y)
	var bl: float = l.call(x - 1, y + 1); var bc: float = l.call(x, y + 1); var br: float = l.call(x + 1, y + 1)
	var gx := (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)
	var gy := (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)
	return sqrt(gx * gx + gy * gy)

## Coerce a descriptor colour param ([r,g,b,a] array, or a Color, or absent) into a Color.
static func _color_param(v, fallback: Color) -> Color:
	if v is Color:
		return v
	if typeof(v) == TYPE_ARRAY and v.size() >= 3:
		var a: float = float(v[3]) if v.size() >= 4 else 1.0
		return Color(float(v[0]), float(v[1]), float(v[2]), a)
	return fallback

## Deterministic integer-hash value noise in [0,1] at (fx,fy), bilinearly interpolated between lattice
## corners. Seeded, renderer-independent (no Godot Noise / FastNoiseLite), so the same (x,y,seed) gives
## the identical grain in any engine — the portability invariant the whole effect stack holds.
static func _value_noise(fx: float, fy: float, seed: int) -> float:
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	# Smoothstep the interpolants for a softer, paper-like field.
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var v00 := _hash01(x0, y0, seed)
	var v10 := _hash01(x0 + 1, y0, seed)
	var v01 := _hash01(x0, y0 + 1, seed)
	var v11 := _hash01(x0 + 1, y0 + 1, seed)
	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, ty)

## A stable [0,1] hash of (x, y, seed) — integer mixing, no float platform variance.
static func _hash01(x: int, y: int, seed: int) -> float:
	var n := (x * 374761393 + y * 668265263 + seed * 1442695040888963407) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	n = n & 0x7fffffff
	return float(n) / float(0x7fffffff)
