class_name MathPainting
extends RefCounted
## MATHEMATICAL CONSTRUCTIONS AS PAINTINGS — deterministic, seeded generators that render parametric
## curves, vector-field streamlines, and harmonic (standing-wave / Chladni) scalar fields as stroke
## images, which the existing painterly effect stack (EffectStackCpu) then paints. Everything is DATA:
## a `painting` descriptor (generator + its math knobs + palette + background) fully determines the
## image — same descriptor, same bytes, any run, any machine (the portability invariant: the only
## randomness is the same integer-hash noise family effect_stack_cpu/clouds use, plus a seeded LCG).
##
## Three generators (exactly the spec'd scope — no extra generalization):
##   "parametric_curve" — Lissajous (x=sin(a·t+δ), y=sin(b·t)) or rose (r=cos(k·θ)) traced as a round
##                        brush stroke, colored along t by the palette.
##   "flow_field"       — streamlines advected through the curl of seeded fBm value noise (rotated
##                        gradient → divergence-free flow), each stroke a chain of brush stamps,
##                        colored by heading angle.
##   "harmonic"         — a superposition of square-plate standing waves per mode (n,m,amp):
##                        f += amp·(cos(nπu)cos(mπv) − cos(mπu)cos(nπv)), mapped through the palette,
##                        with the nodal lines (|f|≈0, where sand would gather on a Chladni plate)
##                        inked dark.
##
## The caller applies the painterly stack after: EffectStackCpu.apply({"stack": …}, generate(cfg)).

## Render the `painting` descriptor to a new RGBAF Image. Pure function of cfg.
static func generate(cfg: Dictionary) -> Image:
	var w := maxi(16, int(cfg.get("width", 640)))
	var h := maxi(16, int(cfg.get("height", 400)))
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	var bg := _col(cfg.get("background", [0.93, 0.90, 0.84]))
	img.fill(bg)
	match String(cfg.get("generator", "parametric_curve")):
		"parametric_curve":
			_curve(img, cfg)
		"flow_field":
			_flow(img, cfg)
		"harmonic":
			_harmonic(img, cfg)
		_:
			push_warning("[math_painting] unknown generator '%s' (background only)" % cfg.get("generator"))
	return img

# ── parametric curves ────────────────────────────────────────────────────────────────────────────────

static func _curve(img: Image, cfg: Dictionary) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var kind := String(cfg.get("curve", "lissajous"))
	var a := float(cfg.get("a", 3.0))
	var b := float(cfg.get("b", 4.0))
	var delta := float(cfg.get("delta", PI / 2.0))
	var k := float(cfg.get("k", 5.0))
	var loops := float(cfg.get("loops", 1.0))
	var samples := maxi(16, int(cfg.get("samples", 6000)))
	var radius := maxi(1, int(cfg.get("stroke_radius", 3)))
	var stops: Array = cfg.get("palette", _default_palette())
	var margin := float(cfg.get("margin", 0.10))
	var box_w := float(w) * (1.0 - 2.0 * margin)
	var box_h := float(h) * (1.0 - 2.0 * margin)
	for i in samples:
		var s := float(i) / float(samples - 1)
		var t := TAU * loops * s
		var px: float
		var py: float
		if kind == "rose":
			var r := cos(k * t)
			px = r * cos(t)
			py = r * sin(t)
		else:
			px = sin(a * t + delta)
			py = sin(b * t)
		var x := float(w) * margin + (px * 0.5 + 0.5) * box_w
		var y := float(h) * margin + (py * 0.5 + 0.5) * box_h
		_stamp(img, int(round(x)), int(round(y)), radius, _palette(s, stops))

# ── vector-field streamlines (curl of fBm noise → divergence-free flow) ──────────────────────────────

static func _flow(img: Image, cfg: Dictionary) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var seed := int(cfg.get("seed", 7))
	var strokes := maxi(1, int(cfg.get("strokes", 800)))
	var steps := maxi(2, int(cfg.get("steps", 40)))
	var step_len := float(cfg.get("step_len", 2.2))
	var noise_scale := float(cfg.get("noise_scale", 3.0))
	var octaves := clampi(int(cfg.get("octaves", 3)), 1, 6)
	var radius := maxi(1, int(cfg.get("stroke_radius", 1)))
	var stops: Array = cfg.get("palette", _default_palette())
	var rng := [seed * 2654435761 + 1013904223]
	for s in strokes:
		var x := _rand01(rng) * float(w)
		var y := _rand01(rng) * float(h)
		for st in steps:
			if x < 0.0 or y < 0.0 or x >= float(w) or y >= float(h):
				break
			# curl of the scalar noise field: grad = (dn/dx, dn/dy); flow = (grad.y, -grad.x).
			var eps := 0.75
			var nx0 := _fbm((x - eps) / float(w) * noise_scale, y / float(h) * noise_scale, seed, octaves)
			var nx1 := _fbm((x + eps) / float(w) * noise_scale, y / float(h) * noise_scale, seed, octaves)
			var ny0 := _fbm(x / float(w) * noise_scale, (y - eps) / float(h) * noise_scale, seed, octaves)
			var ny1 := _fbm(x / float(w) * noise_scale, (y + eps) / float(h) * noise_scale, seed, octaves)
			var gx := nx1 - nx0
			var gy := ny1 - ny0
			var dir := Vector2(gy, -gx)
			if dir.length() < 0.000001:
				break
			dir = dir.normalized()
			var hue := clampf(dir.angle() / TAU + 0.5, 0.0, 1.0)
			_stamp(img, int(round(x)), int(round(y)), radius, _palette(hue, stops))
			x += dir.x * step_len
			y += dir.y * step_len

# ── harmonic standing waves (Chladni superposition) ─────────────────────────────────────────────────

static func _harmonic(img: Image, cfg: Dictionary) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var modes: Array = cfg.get("modes", [[3.0, 5.0, 1.0]])
	var stops: Array = cfg.get("palette", _default_palette())
	var ink_eps := float(cfg.get("ink_eps", 0.04))
	var ink := _col(cfg.get("ink", [0.10, 0.08, 0.12]))
	# range of f for normalization: sum of |amp|·2 is a safe bound per the antisymmetric construction.
	var bound := 0.0
	for m in modes:
		if m is Array and (m as Array).size() >= 3:
			bound += absf(float(m[2])) * 2.0
	bound = maxf(bound, 0.0001)
	for y in h:
		for x in w:
			var u := float(x) / float(w - 1)
			var v := float(y) / float(h - 1)
			var f := 0.0
			for m in modes:
				if not (m is Array) or (m as Array).size() < 2:
					continue
				var n := float(m[0])
				var mm := float(m[1])
				var amp := float(m[2]) if (m as Array).size() >= 3 else 1.0
				f += amp * (cos(n * PI * u) * cos(mm * PI * v) - cos(mm * PI * u) * cos(n * PI * v))
			var t := clampf(f / bound * 0.5 + 0.5, 0.0, 1.0)
			var c := _palette(t, stops)
			# nodal lines: where f ≈ 0 the plate is still — ink them (the classic Chladni figure).
			var nl := clampf(1.0 - absf(f) / (bound * ink_eps), 0.0, 1.0)
			c = c.lerp(ink, nl)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))

# ── shared helpers ──────────────────────────────────────────────────────────────────────────────────

## Filled-disc brush stamp with bounds clipping.
static func _stamp(img: Image, cx: int, cy: int, radius: int, col: Color) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var r2 := radius * radius
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if dx * dx + dy * dy > r2:
				continue
			var x := cx + dx
			var y := cy + dy
			if x >= 0 and y >= 0 and x < w and y < h:
				img.set_pixel(x, y, col)

## Piecewise-linear color palette from DATA stops [[t, r, g, b], ...] (t ascending in 0..1).
static func _palette(t: float, stops: Array) -> Color:
	if stops.is_empty():
		return Color(t, t, t, 1.0)
	t = clampf(t, 0.0, 1.0)
	var prev: Array = stops[0]
	for s in stops:
		if not (s is Array) or (s as Array).size() < 4:
			continue
		if float(s[0]) >= t:
			var t0 := float(prev[0])
			var t1 := float(s[0])
			var f := 0.0 if t1 <= t0 else (t - t0) / (t1 - t0)
			var c0 := Color(float(prev[1]), float(prev[2]), float(prev[3]), 1.0)
			var c1 := Color(float(s[1]), float(s[2]), float(s[3]), 1.0)
			return c0.lerp(c1, f)
		prev = s
	var last: Array = stops[stops.size() - 1]
	return Color(float(last[1]), float(last[2]), float(last[3]), 1.0)

static func _default_palette() -> Array:
	return [[0.0, 0.55, 0.12, 0.10], [0.5, 0.92, 0.68, 0.20], [1.0, 0.98, 0.94, 0.82]]

## Deterministic LCG in [0,1) — the seeded start-point stream for flow strokes. `state` is a one-cell
## Array so the caller's stream advances (GDScript ints are 64-bit; constants are Knuth's MMIX).
static func _rand01(state: Array) -> float:
	state[0] = int(state[0]) * 6364136223846793005 + 1442695040888963407
	var v := (int(state[0]) >> 17) & 0x7FFFFFFF
	return float(v) / float(0x80000000)

## fBm of the SAME integer-hash value noise family effect_stack_cpu/clouds use (portability invariant).
static func _fbm(fx: float, fy: float, seed: int, octaves: int) -> float:
	var total := 0.0
	var amp := 0.5
	var freq := 1.0
	var norm := 0.0
	for i in octaves:
		total += amp * _value_noise(fx * freq, fy * freq, seed + i * 1013)
		norm += amp
		amp *= 0.5
		freq *= 2.0
	return clampf(total / maxf(0.0001, norm), 0.0, 1.0)

static func _value_noise(fx: float, fy: float, seed: int) -> float:
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var v00 := _hash01(x0, y0, seed)
	var v10 := _hash01(x0 + 1, y0, seed)
	var v01 := _hash01(x0, y0 + 1, seed)
	var v11 := _hash01(x0 + 1, y0 + 1, seed)
	return lerpf(lerpf(v00, v10, tx), lerpf(v01, v11, tx), ty)

static func _hash01(x: int, y: int, seed: int) -> float:
	var n := (x * 374761393 + y * 668265263 + seed * 1442695040888963407) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	n = n & 0x7fffffff
	return float(n) / float(0x7fffffff)

static func _col(a) -> Color:
	if a is Color:
		return a
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Color(float(a[0]), float(a[1]), float(a[2]), 1.0)
	return Color(0.9, 0.9, 0.9, 1.0)
