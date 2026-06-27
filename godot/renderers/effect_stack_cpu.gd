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
##   "normal_map"   — (L4) surface-relief from luminance: treat luminance as a height field, take its
##                    Sobel x/y gradients as the slope, and encode the resulting unit normal into RGB
##                    (the standard tangent-space [0..1] packing nx=r*2-1, ny=g*2-1, nz=b*2-1). The
##                    "embossed/relief" painterly layer — gives the look a sculpted surface WITHOUT a real
##                    geometric normal channel (derived from the source frame, so the CPU oracle stays
##                    headless). params.strength:float (height scale; 0 = flat → pure (0.5,0.5,1.0) blue).
##   "lighting"     — (L4) directional lighting response: derive a normal from luminance (same height-
##                    from-luma slope as normal_map), light it with a fixed directional light (Lambert
##                    N·L) plus an ambient floor, and multiply the shading onto the pixel's RGB. The "lit
##                    painterly surface" layer — makes brush relief catch light. params.light_x/light_y/
##                    light_z (light DIRECTION, normalized internally), params.ambient:float (0..1),
##                    params.strength:float (height scale feeding the derived normal).
##   "temporal_stability" — (L4) frame-to-frame coherence so the painterly look does not shimmer in the
##                    3D walkabout: blend each pixel toward the SAME pixel of a PREVIOUS frame supplied on
##                    the descriptor (params.prev, a serialized image payload — see _prev_image), by a
##                    fixed `blend` factor (0 = ignore history → identity; 1 = freeze to prev). The
##                    temporal low-pass that kills per-frame flicker. With no/mismatched prev it is
##                    identity (the first frame has no history). params.blend:float (0..1).
##   LATER (deferred): true depth/normal/motion-vector CHANNELS from the 3D backend (so normal_map and
##                    lighting can read a real geometric normal instead of the luminance-derived one, and
##                    temporal_stability can reproject by motion vectors) — out of scope here; these three
##                    layers are the renderer-neutral, source-frame-only first cut.

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
	"normal_map": { "params": {
		"strength": { "type": "float", "min": 0.0, "max": 8.0, "default": 2.0 },
	} },
	"lighting": { "params": {
		"strength": { "type": "float", "min": 0.0, "max": 8.0, "default": 2.0 },
		"ambient": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.3 },
		"light_x": { "type": "float", "min": -1.0, "max": 1.0, "default": -0.5 },
		"light_y": { "type": "float", "min": -1.0, "max": 1.0, "default": -0.5 },
		"light_z": { "type": "float", "min": 0.0, "max": 1.0, "default": 1.0 },
	} },
	"temporal_stability": { "params": {
		"blend": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.5 },
		# `prev` (the previous-frame payload) carries no numeric range → the evolver leaves it untouched
		# (it is supplied by the render loop, not a tunable knob), exactly as color/bg are on `outline`.
	} },
	# ── OPTICAL layers (Convergence cycle #1) — screen-space VISIBLE-LIGHT effects ────────────────────
	# These three read the SAME color frame as the painterly layers, plus (optionally) the light's
	# SCREEN POSITION supplied as DATA on the descriptor (`light_screen:[u,v]`, normalized 0..1) via the
	# typed-I/O contract (see apply_io). With no light_screen they fall back to the frame centre, so they
	# stay color-in/color-out compatible — a legacy `{stack:[...]}` still runs them, just centred. The
	# bright pixels of the frame ARE the occlusion mask (a luminance threshold), so no real depth buffer
	# is required for the renderer-neutral first cut (a true depth channel is the deferred richer input).
	"god_rays": { "params": {
		"density": { "type": "float", "min": 0.0, "max": 1.5, "default": 0.9 },
		"decay": { "type": "float", "min": 0.5, "max": 1.0, "default": 0.95 },
		"weight": { "type": "float", "min": 0.0, "max": 2.0, "default": 0.5 },
		"exposure": { "type": "float", "min": 0.0, "max": 2.0, "default": 0.6 },
		"threshold": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.7 },
		"samples": { "type": "int", "min": 8, "max": 128, "default": 48 },
	} },
	"lens_flare": { "params": {
		"ghosts": { "type": "int", "min": 0, "max": 8, "default": 4 },
		"dispersal": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.3 },
		"halo_width": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.45 },
		"strength": { "type": "float", "min": 0.0, "max": 2.0, "default": 0.7 },
		"threshold": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.75 },
	} },
	"bloom": { "params": {
		"threshold": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.7 },
		"intensity": { "type": "float", "min": 0.0, "max": 3.0, "default": 0.9 },
		"radius": { "type": "int", "min": 1, "max": 16, "default": 6 },
	} },
}

## ── Typed-I/O contract (SPEC-748a) ──────────────────────────────────────────────────────────────────
## The canonical input bundle the typed applier consumes. The ONLY required channel is `color`; every
## other channel is optional and defaults to "absent" so a layer self-derives it (e.g. the optical
## layers derive their occlusion mask from `color`'s bright pixels when no `mask`/`depth` is supplied).
## A renderer hands these in as DATA (Images + a normalized [u,v] light position); nothing here is
## renderer-specific. The whole reformat is BACKWARD-COMPATIBLE: apply(desc, src) wraps src as
## {color: src} and runs unchanged, and a legacy {stack:[...]} descriptor (no light_screen) still
## passes — the optical layers just centre their light. See test_effect_stack_io_backcompat.gd.
##   { "color": Image (required),
##     "depth": Image|null,    # linear depth, 0=near..1=far — DEFERRED richer input; null today
##     "normal": Image|null,   # geometric normal (tangent/world) — DEFERRED richer input; null today
##     "mask": Image|null,     # explicit occlusion/bright mask; null → derived from color luminance
##     "light_screen": [u,v]|null }  # the light's normalized screen position; null → frame centre

## Apply an effect_stack descriptor to a source Image, returning a NEW Image (source untouched).
## LEGACY color-in/color-out entry point — UNCHANGED contract. It is now a thin wrapper over the typed
## apply_io: it bundles `src` as the `color` channel (no depth/normal/mask, light defaults to centre),
## so every pre-existing caller and every legacy `{stack:[...]}` descriptor behaves exactly as before.
## Unknown effect types are skipped with a warning (forward-compatible: a descriptor authored against
## a richer delegate still runs the layers THIS applier understands, the rest are no-ops here).
static func apply(desc: Dictionary, src: Image) -> Image:
	return apply_io(desc, { "color": src })

## TYPED-I/O applier (SPEC-748a). Consumes the typed input bundle (see the contract above) plus the
## effect_stack descriptor, returns a NEW color Image. The descriptor MAY carry a top-level
## `light_screen:[u,v]` (DATA) which seeds the optical layers' light position; an explicit `light_screen`
## key inside `inputs` overrides it; absent both, the optical layers centre the light. All non-optical
## layers ignore the extra channels entirely, so they are bit-identical to the old apply() path.
static func apply_io(desc: Dictionary, inputs: Dictionary) -> Image:
	var color = inputs.get("color")
	assert(color is Image, "EffectStackCpu.apply_io requires a `color` Image input")
	var img := (color as Image).duplicate() as Image
	# Resolve the light's normalized screen position once: inputs override the descriptor, descriptor
	# overrides the default centre. Carried as a plain [u,v] (0..1), renderer-neutral DATA.
	var light_uv := _light_uv(inputs.get("light_screen", desc.get("light_screen", null)))
	var mask = inputs.get("mask")  # optional explicit bright/occlusion mask Image; null → derive
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
			"normal_map":
				img = _normal_map(img, p)
			"lighting":
				img = _lighting(img, p)
			"temporal_stability":
				img = _temporal_stability(img, p)
			"god_rays":
				img = _god_rays(img, p, light_uv, mask)
			"lens_flare":
				img = _lens_flare(img, p, light_uv, mask)
			"bloom":
				img = _bloom(img, p)
			_:
				push_warning("EffectStackCpu: unknown effect '%s' (skipped)" % layer.get("type"))
	return img

## Coerce a light_screen value ([u,v] array, or a Vector2, or null) into a clamped Vector2 in [0,1]^2.
## null (or malformed) → the frame centre (0.5, 0.5), so the optical layers degrade gracefully when no
## light position is supplied (the legacy color-in/color-out case). Renderer-neutral DATA in.
static func _light_uv(v) -> Vector2:
	if v is Vector2:
		return Vector2(clampf(v.x, 0.0, 1.0), clampf(v.y, 0.0, 1.0))
	if typeof(v) == TYPE_ARRAY and v.size() >= 2:
		return Vector2(clampf(float(v[0]), 0.0, 1.0), clampf(float(v[1]), 0.0, 1.0))
	return Vector2(0.5, 0.5)

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
# normal_map (L4) — surface relief from luminance, encoded as a tangent-space normal in RGB
# ---------------------------------------------------------------------------------------------------

## Height-from-luminance normal map. Treat the source luminance as a height field h(x,y); its surface
## normal is (-dh/dx, -dh/dy, 1) normalized, where the slopes are the Sobel x/y gradients scaled by
## `strength`. The unit normal is packed into RGB the standard way: r=nx*0.5+0.5, g=ny*0.5+0.5,
## b=nz*0.5+0.5 — so a flat region (zero gradient) is the canonical flat-normal blue (0.5,0.5,1.0).
## strength=0 → every pixel is exactly that flat blue (the identity-of-relief floor). Alpha is carried
## through from the source. Reads from the input snapshot, writes a fresh output → a true convolution.
## Returns a NEW image. CC0 (Sobel + the universal tangent-space normal packing).
static func _normal_map(img: Image, params: Dictionary) -> Image:
	var strength := float(params.get("strength", 2.0))
	if strength < 0.0:
		strength = 0.0
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			var n := _height_normal(img, x, y, w, h, strength)
			out.set_pixel(x, y, Color(
				n.x * 0.5 + 0.5,
				n.y * 0.5 + 0.5,
				n.z * 0.5 + 0.5,
				img.get_pixel(x, y).a
			))
	return out

# ---------------------------------------------------------------------------------------------------
# lighting (L4) — directional lighting response over the luminance-derived relief
# ---------------------------------------------------------------------------------------------------

## Directional lighting response. Derive the same luminance height-normal as normal_map, then shade it
## with one fixed directional light: Lambert term = max(0, N·L), final shade = clamp(ambient + (1-
## ambient) * N·L, 0, 1), and multiply that scalar onto the pixel's RGB. `light_x/y/z` give the light
## DIRECTION (normalized internally; a zero vector degrades to straight-down so it never divides by
## zero), `ambient` is the unlit floor (ambient=1 → fully lit → identity), `strength` is the height
## scale feeding the normal (strength=0 → flat normal → N·L is constant → uniform shade). Alpha carried
## through. Reads from the snapshot, writes a fresh output. Returns a NEW image. CC0 (Lambert N·L).
static func _lighting(img: Image, params: Dictionary) -> Image:
	var strength := float(params.get("strength", 2.0))
	if strength < 0.0:
		strength = 0.0
	var ambient := clampf(float(params.get("ambient", 0.3)), 0.0, 1.0)
	var lx := float(params.get("light_x", -0.5))
	var ly := float(params.get("light_y", -0.5))
	var lz := float(params.get("light_z", 1.0))
	var light := Vector3(lx, ly, lz)
	if light.length() < 0.000001:
		light = Vector3(0.0, 0.0, 1.0)  # degenerate light → straight down, never a NaN
	light = light.normalized()
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			var n := _height_normal(img, x, y, w, h, strength)
			var ndotl: float = max(0.0, n.dot(light))
			var shade := clampf(ambient + (1.0 - ambient) * ndotl, 0.0, 1.0)
			var c := img.get_pixel(x, y)
			out.set_pixel(x, y, Color(c.r * shade, c.g * shade, c.b * shade, c.a))
	return out

# ---------------------------------------------------------------------------------------------------
# temporal_stability (L4) — frame-to-frame coherence (anti-shimmer temporal low-pass)
# ---------------------------------------------------------------------------------------------------

## Temporal low-pass against a previous frame. For each pixel, out = lerp(current, prev, blend) — an
## exponential-moving-average toward history that suppresses the per-frame flicker the painterly
## neighbourhood effects produce as the camera moves. `blend`=0 → ignore history (identity), 1 → freeze
## to prev. The previous frame is supplied ON THE DESCRIPTOR as `params.prev` (a serialized image
## payload — see _prev_image — so the whole stack stays JSON-portable DATA, no live Image on the wire).
## If no prev is supplied, or its size does not match, it is identity (the first frame has no history,
## and a resized frame can't be blended pixel-wise — fail safe to the current frame, never a crash).
## Reads from the current snapshot, writes a fresh output. Returns a NEW image.
static func _temporal_stability(img: Image, params: Dictionary) -> Image:
	var blend := clampf(float(params.get("blend", 0.5)), 0.0, 1.0)
	var w := img.get_width()
	var h := img.get_height()
	var prev := _prev_image(params.get("prev"), w, h)
	if prev == null or blend <= 0.0:
		return img.duplicate() as Image  # identity: no history, or history ignored
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var pc := prev.get_pixel(x, y)
			out.set_pixel(x, y, Color(
				lerpf(c.r, pc.r, blend),
				lerpf(c.g, pc.g, blend),
				lerpf(c.b, pc.b, blend),
				lerpf(c.a, pc.a, blend)
			))
	return out

# ===================================================================================================
# OPTICAL layers (Convergence cycle #1) — visible-light effects: sunbeams / lens flares / bloom
# ===================================================================================================
# All three are screen-space and renderer-neutral by construction: same DATA descriptor, same per-pixel
# algebra a GPU shader (Godot Compositor or three.js post-pass) reproduces. They share ONE occlusion
# mask derived from the frame's own bright pixels (`_bright_mask`) — so they need no real depth buffer,
# only the (optional) light SCREEN POSITION passed as DATA. The standard reference algorithm for each is
# CC0 / public-domain (Mitchell's GPU-Gems3 radial scattering god-rays; the Kawase/GPU-Gems lens-flare
# feature generation; the threshold→blur→add bloom). A future tier can swap the derived mask for a true
# depth/light-occlusion channel via the typed-I/O `depth`/`mask` inputs — no descriptor change.

## GOD-RAYS (sunbeams / crepuscular rays). Screen-space radial light scattering: from each pixel, march
## `samples` steps TOWARD the light's screen position, accumulating the BRIGHT mask with exponential
## `decay` and `weight`, then add `exposure * accumulated` back onto the pixel. `density` scales the
## per-step march distance (how far the rays reach). `threshold` is the brightness above which a pixel
## emits rays (the sun disc / sky gaps through the canopy). The canonical GPU-Gems3 ch.13 "Volumetric
## Light Scattering as a Post-Process" formula, on the CPU. light_uv (0..1) is the radial origin.
## Returns a NEW image. Additive over the source → the beams glow, the rest of the frame is unchanged.
static func _god_rays(img: Image, params: Dictionary, light_uv: Vector2, mask) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var density := float(params.get("density", 0.9))
	var decay := clampf(float(params.get("decay", 0.95)), 0.0, 1.0)
	var weight := float(params.get("weight", 0.5))
	var exposure := float(params.get("exposure", 0.6))
	var threshold := clampf(float(params.get("threshold", 0.7)), 0.0, 1.0)
	var samples: int = max(1, int(params.get("samples", 48)))
	var bright := _bright_mask(img, mask, threshold)  # the ray-emitting source (sun / sky gaps)
	var lx := light_uv.x * float(w - 1)
	var ly := light_uv.y * float(h - 1)
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			# Vector from this pixel toward the light, divided into `samples` decaying steps.
			var dx := (lx - float(x)) * density / float(samples)
			var dy := (ly - float(y)) * density / float(samples)
			var sx := float(x)
			var sy := float(y)
			var illum := 0.0
			var w_acc := 1.0
			for _s in samples:
				sx += dx
				sy += dy
				var ix := clampi(int(round(sx)), 0, w - 1)
				var iy := clampi(int(round(sy)), 0, h - 1)
				illum += bright[iy * w + ix] * w_acc * weight
				w_acc *= decay
			illum = clampf(illum / float(samples) * exposure, 0.0, 4.0)
			var c := img.get_pixel(x, y)
			out.set_pixel(x, y, Color(
				clampf(c.r + illum, 0.0, 1.0),
				clampf(c.g + illum, 0.0, 1.0),
				clampf(c.b + illum, 0.0, 1.0),
				c.a))
	return out

## LENS-FLARE. Screen-space ghosts + halo along the light→frame-centre axis. The bright mask is
## down-thresholded into a "feature" buffer; `ghosts` copies of it are sampled at evenly-spaced offsets
## along the vector from the light position through the centre (`dispersal` = spacing), plus a chromatic
## HALO ring at radius `halo_width` from the centre. The classic GPU-Gems / Kawase lens-flare feature
## generation, on the CPU. `strength` scales the additive composite. Returns a NEW image.
static func _lens_flare(img: Image, params: Dictionary, light_uv: Vector2, mask) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var ghosts: int = max(0, int(params.get("ghosts", 4)))
	var dispersal := float(params.get("dispersal", 0.3))
	var halo_width := clampf(float(params.get("halo_width", 0.45)), 0.0, 1.0)
	var strength := float(params.get("strength", 0.7))
	var threshold := clampf(float(params.get("threshold", 0.75)), 0.0, 1.0)
	var bright := _bright_mask(img, mask, threshold)
	# Work in normalized [0,1] UV centred on the frame so dispersal/halo are resolution-independent.
	var center := Vector2(0.5, 0.5)
	# Ghosts march from the light, through the centre, to the far side (the flare "string of pearls").
	var to_center := (center - light_uv)
	var out := img.duplicate() as Image
	for y in h:
		for x in w:
			var uv := Vector2(float(x) / float(maxi(1, w - 1)), float(y) / float(maxi(1, h - 1)))
			var add := 0.0
			# Ghosts: sample the bright feature buffer at uv reflected+stepped along the light axis.
			for g in range(1, ghosts + 1):
				var ghost_uv := uv + to_center * (dispersal * float(g))
				add += _sample_mask_uv(bright, w, h, ghost_uv) * (1.0 / float(g))
			# Halo: a soft ring at halo_width from the centre, pulling from the bright buffer radially.
			if halo_width > 0.0:
				var dir := (uv - center)
				var halo_uv := center + dir.normalized() * halo_width if dir.length() > 0.0001 else center
				var ring := 1.0 - clampf(absf(dir.length() - halo_width) / 0.06, 0.0, 1.0)
				add += _sample_mask_uv(bright, w, h, halo_uv) * ring * 0.8
			add = clampf(add * strength, 0.0, 2.0)
			if add > 0.0:
				var c := out.get_pixel(x, y)
				# Subtle chromatic tint so flares read as lens artefacts, not flat white blobs.
				out.set_pixel(x, y, Color(
					clampf(c.r + add * 1.0, 0.0, 1.0),
					clampf(c.g + add * 0.9, 0.0, 1.0),
					clampf(c.b + add * 1.1, 0.0, 1.0),
					c.a))
	return out

## BLOOM (glare). Bright-threshold → box-blur → additive composite: pixels above `threshold` are
## extracted, blurred by a separable box of half-width `radius`, and added back at `intensity`. The
## standard threshold/blur/add bloom; the box blur is the cheap renderer-neutral kernel (a Gaussian /
## dual-Kawase is the GPU refinement against this same descriptor). Returns a NEW image.
static func _bloom(img: Image, params: Dictionary) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var threshold := clampf(float(params.get("threshold", 0.7)), 0.0, 1.0)
	var intensity := float(params.get("intensity", 0.9))
	var radius: int = max(1, int(params.get("radius", 6)))
	# 1) Extract the bright pass (soft knee at the threshold so it ramps in, not a hard cut).
	var bright_r := PackedFloat32Array(); bright_r.resize(w * h)
	var bright_g := PackedFloat32Array(); bright_g.resize(w * h)
	var bright_b := PackedFloat32Array(); bright_b.resize(w * h)
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var lum := _luma(c)
			var knee := clampf((lum - threshold) / max(0.0001, 1.0 - threshold), 0.0, 1.0)
			bright_r[y * w + x] = c.r * knee
			bright_g[y * w + x] = c.g * knee
			bright_b[y * w + x] = c.b * knee
	# 2) Separable box blur (horizontal then vertical) of the bright pass.
	bright_r = _box_blur_1d(bright_r, w, h, radius, true)
	bright_g = _box_blur_1d(bright_g, w, h, radius, true)
	bright_b = _box_blur_1d(bright_b, w, h, radius, true)
	bright_r = _box_blur_1d(bright_r, w, h, radius, false)
	bright_g = _box_blur_1d(bright_g, w, h, radius, false)
	bright_b = _box_blur_1d(bright_b, w, h, radius, false)
	# 3) Additive composite at `intensity`.
	var out := Image.create(w, h, false, img.get_format())
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			var i := y * w + x
			out.set_pixel(x, y, Color(
				clampf(c.r + bright_r[i] * intensity, 0.0, 1.0),
				clampf(c.g + bright_g[i] * intensity, 0.0, 1.0),
				clampf(c.b + bright_b[i] * intensity, 0.0, 1.0),
				c.a))
	return out

## The frame's bright pixels as a flat luminance mask (row-major float array, length w*h). If an explicit
## `mask` Image is supplied (typed-I/O), its red channel is used directly; otherwise the mask is derived
## from the color frame's luminance above `threshold` (soft-kneed). This is the shared occlusion source
## the optical layers scatter — no real depth buffer needed for the renderer-neutral first cut.
static func _bright_mask(img: Image, mask, threshold: float) -> PackedFloat32Array:
	var w := img.get_width()
	var h := img.get_height()
	var out := PackedFloat32Array()
	out.resize(w * h)
	if mask is Image and (mask as Image).get_width() == w and (mask as Image).get_height() == h:
		var m := mask as Image
		for y in h:
			for x in w:
				out[y * w + x] = m.get_pixel(x, y).r
		return out
	for y in h:
		for x in w:
			var lum := _luma(img.get_pixel(x, y))
			out[y * w + x] = clampf((lum - threshold) / max(0.0001, 1.0 - threshold), 0.0, 1.0)
	return out

## Bilinear sample of a flat float mask at a normalized UV (clamped). The CPU twin of texture(mask, uv).
static func _sample_mask_uv(m: PackedFloat32Array, w: int, h: int, uv: Vector2) -> float:
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return 0.0  # off-screen features do not contribute (standard flare clamp-to-zero)
	var fx := uv.x * float(w - 1)
	var fy := uv.y * float(h - 1)
	var x0 := int(floor(fx)); var y0 := int(floor(fy))
	var x1 := clampi(x0 + 1, 0, w - 1); var y1 := clampi(y0 + 1, 0, h - 1)
	x0 = clampi(x0, 0, w - 1); y0 = clampi(y0, 0, h - 1)
	var tx := fx - floorf(fx); var ty := fy - floorf(fy)
	var a := lerpf(m[y0 * w + x0], m[y0 * w + x1], tx)
	var b := lerpf(m[y1 * w + x0], m[y1 * w + x1], tx)
	return lerpf(a, b, ty)

## One pass of a separable box blur over a flat float buffer. `horizontal` selects the axis; `radius` is
## the half-width (window = 2*radius+1). Clamped at the edges. Returns a NEW buffer.
static func _box_blur_1d(src: PackedFloat32Array, w: int, h: int, radius: int, horizontal: bool) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	var norm := 1.0 / float(2 * radius + 1)
	for y in h:
		for x in w:
			var acc := 0.0
			for k in range(-radius, radius + 1):
				var sx := x
				var sy := y
				if horizontal:
					sx = clampi(x + k, 0, w - 1)
				else:
					sy = clampi(y + k, 0, h - 1)
				acc += src[sy * w + sx]
			out[y * w + x] = acc * norm
	return out

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

## Sobel luminance GRADIENT (gx, gy) at (x,y) as a Vector2 — the signed slope, not just the magnitude.
## Shared by the relief layers (normal_map, lighting) which need the gradient direction, where
## _sobel_magnitude only gives the strength. Same 3x3 Sobel pair, bounds-clamped.
static func _sobel_gradient(img: Image, x: int, y: int, w: int, h: int) -> Vector2:
	var l := func(ix: int, iy: int) -> float:
		return _luma(img.get_pixel(clampi(ix, 0, w - 1), clampi(iy, 0, h - 1)))
	var tl: float = l.call(x - 1, y - 1); var tc: float = l.call(x, y - 1); var tr: float = l.call(x + 1, y - 1)
	var ml: float = l.call(x - 1, y);     var mr: float = l.call(x + 1, y)
	var bl: float = l.call(x - 1, y + 1); var bc: float = l.call(x, y + 1); var br: float = l.call(x + 1, y + 1)
	var gx := (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)
	var gy := (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)
	return Vector2(gx, gy)

## The unit surface normal of the luminance height field at (x,y), with the slope scaled by `strength`.
## normal = normalize(-strength*gx, -strength*gy, 1): a flat region (zero gradient) is exactly the
## up-facing normal (0,0,1), and steeper luminance ramps tilt the normal more. Shared by normal_map
## (which packs it into RGB) and lighting (which dots it with the light). strength=0 → always (0,0,1).
static func _height_normal(img: Image, x: int, y: int, w: int, h: int, strength: float) -> Vector3:
	var g := _sobel_gradient(img, x, y, w, h)
	return Vector3(-strength * g.x, -strength * g.y, 1.0).normalized()

## Decode a serialized previous-frame payload (params.prev) into an Image, or null if absent/invalid.
## The payload is renderer-neutral DATA so the whole stack stays JSON-portable (no live Image on the
## wire): { "w": int, "h": int, "pixels": [ [r,g,b,a], ... ] } in row-major order (length w*h). A live
## Godot Image is also accepted directly (the render loop may hand one in without serializing). Returns
## null on any mismatch (wrong size, malformed payload) → the caller treats "no usable history" as
## identity, never a crash. Only decodes when the declared size matches the current frame (the temporal
## blend is pixel-aligned; a differently-sized history can't be blended and is dropped).
static func _prev_image(payload, w: int, h: int) -> Image:
	if payload is Image:
		var im := payload as Image
		return im if (im.get_width() == w and im.get_height() == h) else null
	if typeof(payload) != TYPE_DICTIONARY:
		return null
	var pw := int(payload.get("w", -1))
	var ph := int(payload.get("h", -1))
	if pw != w or ph != h:
		return null
	var pixels = payload.get("pixels", null)
	if typeof(pixels) != TYPE_ARRAY or pixels.size() != w * h:
		return null
	var out := Image.create(w, h, false, Image.FORMAT_RGBAF)
	var i := 0
	for y in h:
		for x in w:
			out.set_pixel(x, y, _color_param(pixels[i], Color(0, 0, 0, 0)))
			i += 1
	return out

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
