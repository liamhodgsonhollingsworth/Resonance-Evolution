class_name TextureSynthCpu
extends RefCounted
## The CPU REFERENCE synthesizer for a `texture_ops` descriptor — the PROCEDURAL-TEXTURE twin of
## EffectStackCpu. Where EffectStackCpu POST-PROCESSES a source image through an ordered effect stack,
## this GENERATES an image from nothing but DATA: an ordered list of mathematical construction ops
## (noise / interference / partitions), each colored through a PALETTE-BY-HANDLE ramp and composited
## onto the running canvas with a blend op. A texture genome (evolver/texture_genome.gd) is exactly
## this op list; `synthesize()` is its phenotype.
##
## DETERMINISTIC + SEEDED: there is NO RandomNumberGenerator anywhere in here. Every "random" value is
## a pure integer-hash function of (lattice coords, op seed), so the SAME descriptor ALWAYS produces
## the byte-identical image — reproducibility is the evolvable invariant, exactly as in EffectStackCpu.
## RNGs exist only in the GENOME layer (sampling new genes), never in the RENDER layer.
##
## OP REGISTRY (this is where new construction ops land — a new branch in `_field` + a new OP_TYPES
## entry, never an edit to the evolver). Every op is a GENERATOR: it evaluates a scalar field
## t(u,v) ∈ [0,1] over normalized tile coords, then colors t through its palette ramp, then composites
## the color onto the canvas. Generator × palette × blend is fused into ONE gene, so every layer is a
## complete "construction + color + composition" unit the evolver can mutate along any of those axes:
##   "value_noise" — bilinear lattice value noise. params.scale (cells across the tile), params.seed.
##   "fbm"         — fractal Brownian motion: `octaves` stacked value-noise octaves, frequency ×
##                   `lacunarity` and amplitude × `gain` per octave (the classic octave stack).
##   "sine"        — two-wave sinusoidal INTERFERENCE: sin along direction `angle` at `freq` plus a
##                   second wave rotated by `angle2_delta` at `freq2`; their sum beats/interferes.
##   "stripes"     — soft-edged parallel bands along `angle`: `freq` bands, `duty` fill ratio,
##                   `softness` edge feather (a smoothstepped square wave).
##   "checker"     — hard checkerboard partition, `nx` × `ny` cells.
##   "radial"      — concentric rings around (`cx`,`cy`): sin of radial distance × `freq` + `phase`.
##   "voronoi"     — cellular partition from one seeded feature point per lattice cell (`cells` across
##                   the tile): `mode` 0 = F1 distance (bubbles), 1 = F2−F1 (cell walls).
##
## SHARED GENE PARAMS on every op (merged via _with_common):
##   palette   — a PALETTE HANDLE into PALETTES below (NEVER raw RGB in a genome — the Wavelet
##               one-relinkable-palette convention: colors are referenced by handle and resolved at
##               exactly one place, so relinking a handle re-skins every genome that references it).
##   invert    — 0|1: flip t before the ramp lookup.
##   blend     — how the colored field composites onto the canvas: replace|mix|multiply|add|screen.
##   opacity   — blend strength 0..1 (replace ignores it — the hard-reset gene).
##   warp_amp / warp_scale / warp_seed — DOMAIN WARPING: before sampling the field, (u,v) is offset by
##               two independent value-noise fields (the classic Perlin domain-warp construction).
##               warp_amp 0 → no warp (identity); every generator inherits warping for free.

# ---------------------------------------------------------------------------------------------------
# PALETTES — the ONE relinkable palette registry (colors by HANDLE, never raw values in genomes)
# ---------------------------------------------------------------------------------------------------
## Each handle → an ordered ramp of RGB stops, linearly interpolated by the field value t ∈ [0,1].
## Genomes store ONLY the handle string; this table is the single resolution point (relink a handle
## here and every genome referencing it re-skins — maximal-compatibility palette-by-handle).
const PALETTES := {
	"grayscale": [[0.05, 0.05, 0.05], [0.95, 0.95, 0.95]],
	"earth":     [[0.18, 0.11, 0.06], [0.45, 0.30, 0.15], [0.72, 0.56, 0.35], [0.90, 0.83, 0.65]],
	"ocean":     [[0.02, 0.09, 0.20], [0.05, 0.25, 0.45], [0.10, 0.50, 0.65], [0.75, 0.92, 0.95]],
	"ember":     [[0.08, 0.02, 0.02], [0.55, 0.10, 0.03], [0.95, 0.45, 0.08], [1.00, 0.85, 0.40]],
	"verdant":   [[0.04, 0.10, 0.04], [0.10, 0.32, 0.12], [0.35, 0.60, 0.25], [0.85, 0.90, 0.55]],
	"slate":     [[0.10, 0.11, 0.14], [0.28, 0.31, 0.38], [0.55, 0.58, 0.66], [0.85, 0.87, 0.92]],
	"sandstone": [[0.35, 0.22, 0.12], [0.62, 0.45, 0.28], [0.82, 0.68, 0.48], [0.95, 0.88, 0.72]],
}

const BLEND_MODES := ["replace", "mix", "multiply", "add", "screen"]

## The shared per-gene params every generator carries (see header). Handle-typed params declare an
## `options` list the genome samples/mutates from (the per-gene-type operator for enumerated genes);
## numeric params declare min/max ranges (the per-gene-type operator for continuous genes).
static func _with_common(own: Dictionary) -> Dictionary:
	var p := {
		"palette": { "type": "handle", "options": PALETTES.keys(), "default": "grayscale" },
		"invert": { "type": "int", "min": 0, "max": 1, "default": 0 },
		"blend": { "type": "handle", "options": BLEND_MODES, "default": "mix" },
		"opacity": { "type": "float", "min": 0.15, "max": 1.0, "default": 1.0 },
		"warp_amp": { "type": "float", "min": 0.0, "max": 0.35, "default": 0.0 },
		"warp_scale": { "type": "float", "min": 1.0, "max": 8.0, "default": 3.0 },
		"warp_seed": { "type": "int", "min": 0, "max": 65535, "default": 7 },
	}
	for k in own.keys():
		p[k] = own[k]
	return p

## Machine-readable op vocabulary + param schema, read by TextureGenome (the evolver side) exactly as
## EffectGenome reads EffectStackCpu.EFFECT_TYPES — adding an op here is the SINGLE edit that teaches
## both the synthesizer and the evolver about it (no parallel list to drift).
static var OP_TYPES := {
	"value_noise": { "params": _with_common({
		"scale": { "type": "float", "min": 1.5, "max": 16.0, "default": 5.0 },
		"seed": { "type": "int", "min": 0, "max": 65535, "default": 1 },
	}) },
	"fbm": { "params": _with_common({
		"scale": { "type": "float", "min": 1.0, "max": 10.0, "default": 3.0 },
		"octaves": { "type": "int", "min": 2, "max": 6, "default": 4 },
		"lacunarity": { "type": "float", "min": 1.6, "max": 3.0, "default": 2.0 },
		"gain": { "type": "float", "min": 0.3, "max": 0.7, "default": 0.5 },
		"seed": { "type": "int", "min": 0, "max": 65535, "default": 2 },
	}) },
	"sine": { "params": _with_common({
		"freq": { "type": "float", "min": 1.0, "max": 14.0, "default": 4.0 },
		"freq2": { "type": "float", "min": 1.0, "max": 14.0, "default": 5.0 },
		"angle": { "type": "float", "min": 0.0, "max": 3.14159, "default": 0.0 },
		"angle2_delta": { "type": "float", "min": 0.2, "max": 2.9, "default": 1.5708 },
		"phase": { "type": "float", "min": 0.0, "max": 6.28318, "default": 0.0 },
	}) },
	"stripes": { "params": _with_common({
		"freq": { "type": "float", "min": 2.0, "max": 24.0, "default": 8.0 },
		"angle": { "type": "float", "min": 0.0, "max": 3.14159, "default": 0.7854 },
		"duty": { "type": "float", "min": 0.2, "max": 0.8, "default": 0.5 },
		"softness": { "type": "float", "min": 0.02, "max": 0.35, "default": 0.1 },
	}) },
	"checker": { "params": _with_common({
		"nx": { "type": "int", "min": 2, "max": 12, "default": 4 },
		"ny": { "type": "int", "min": 2, "max": 12, "default": 4 },
	}) },
	"radial": { "params": _with_common({
		"cx": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.5 },
		"cy": { "type": "float", "min": 0.0, "max": 1.0, "default": 0.5 },
		"freq": { "type": "float", "min": 1.0, "max": 12.0, "default": 4.0 },
		"phase": { "type": "float", "min": 0.0, "max": 6.28318, "default": 0.0 },
	}) },
	"voronoi": { "params": _with_common({
		"cells": { "type": "int", "min": 2, "max": 9, "default": 4 },
		"mode": { "type": "int", "min": 0, "max": 1, "default": 0 },
		"seed": { "type": "int", "min": 0, "max": 65535, "default": 3 },
	}) },
}

# ---------------------------------------------------------------------------------------------------
# synthesize — descriptor → Image (pure function of DATA; byte-identical across runs)
# ---------------------------------------------------------------------------------------------------

## Synthesize a `texture_ops` descriptor ({ "texture_ops": [ {type, params}, ... ] }) into a w×h
## Image. Ops run IN ORDER over a flat mid-gray canvas; unknown op types are skipped with a warning
## (forward-compatible, mirroring EffectStackCpu.apply). An empty op list → the plain gray tile.
static func synthesize(desc: Dictionary, w: int, h: int) -> Image:
	w = maxi(2, w)
	h = maxi(2, h)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	for op in desc.get("texture_ops", []):
		if typeof(op) != TYPE_DICTIONARY:
			continue
		var t := String(op.get("type", ""))
		if not OP_TYPES.has(t):
			push_warning("TextureSynthCpu: unknown op '%s' (skipped)" % t)
			continue
		_apply_op(img, t, op.get("params", {}))
	return img

## Apply ONE generator op onto the canvas in place: field → invert → palette ramp → blend.
static func _apply_op(img: Image, type: String, p: Dictionary) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var ramp: Array = PALETTES.get(String(p.get("palette", "grayscale")), PALETTES["grayscale"])
	var invert := int(p.get("invert", 0)) == 1
	var blend := String(p.get("blend", "mix"))
	var opacity := clampf(float(p.get("opacity", 1.0)), 0.0, 1.0)
	var warp_amp := float(p.get("warp_amp", 0.0))
	var warp_scale := float(p.get("warp_scale", 3.0))
	var warp_seed := int(p.get("warp_seed", 7))
	for y in h:
		var v := float(y) / float(h)
		for x in w:
			var u := float(x) / float(w)
			var su := u
			var sv := v
			if warp_amp > 0.0:
				# Domain warping: offset the sample point by two independent noise fields.
				su += warp_amp * (_vnoise(u * warp_scale, v * warp_scale, warp_seed) - 0.5) * 2.0
				sv += warp_amp * (_vnoise(u * warp_scale, v * warp_scale, warp_seed + 131) - 0.5) * 2.0
			var t := _field(type, su, sv, p)
			if invert:
				t = 1.0 - t
			var c := _ramp(ramp, t)
			img.set_pixel(x, y, _blend(img.get_pixel(x, y), c, blend, opacity))

## The scalar field t(u,v) ∈ [0,1] for one op type — the mathematical construction itself.
static func _field(type: String, u: float, v: float, p: Dictionary) -> float:
	match type:
		"value_noise":
			var s := float(p.get("scale", 5.0))
			return _vnoise(u * s, v * s, int(p.get("seed", 1)))
		"fbm":
			return _fbm(u, v, float(p.get("scale", 3.0)), int(p.get("octaves", 4)),
				float(p.get("lacunarity", 2.0)), float(p.get("gain", 0.5)), int(p.get("seed", 2)))
		"sine":
			var a1 := float(p.get("angle", 0.0))
			var a2 := a1 + float(p.get("angle2_delta", 1.5708))
			var w1 := sin(TAU * float(p.get("freq", 4.0)) * (u * cos(a1) + v * sin(a1)) + float(p.get("phase", 0.0)))
			var w2 := sin(TAU * float(p.get("freq2", 5.0)) * (u * cos(a2) + v * sin(a2)))
			return 0.5 + 0.25 * w1 + 0.25 * w2
		"stripes":
			var a := float(p.get("angle", 0.7854))
			var band := fposmod(float(p.get("freq", 8.0)) * (u * cos(a) + v * sin(a)), 1.0)
			var d := absf(band - 0.5) * 2.0  # 0 at band center, 1 at band edge
			var duty := float(p.get("duty", 0.5))
			var soft := float(p.get("softness", 0.1))
			return 1.0 - smoothstep(duty - soft, duty + soft, d)
		"checker":
			var cx := int(floor(u * float(int(p.get("nx", 4)))))
			var cy := int(floor(v * float(int(p.get("ny", 4)))))
			return float(posmod(cx + cy, 2))
		"radial":
			var dx := u - float(p.get("cx", 0.5))
			var dy := v - float(p.get("cy", 0.5))
			return 0.5 + 0.5 * sin(TAU * float(p.get("freq", 4.0)) * sqrt(dx * dx + dy * dy) + float(p.get("phase", 0.0)))
		"voronoi":
			return _voronoi(u, v, int(p.get("cells", 4)), int(p.get("mode", 0)), int(p.get("seed", 3)))
	return 0.5

# ---------------------------------------------------------------------------------------------------
# constructions — hash / value noise / fbm / voronoi (all pure integer-hash based, NO RNG)
# ---------------------------------------------------------------------------------------------------

## 32-bit avalanche hash (lowbias32 constants) — the deterministic randomness source for every lattice.
static func _hash_u32(x: int) -> int:
	x = x & 0xFFFFFFFF
	x = (x ^ (x >> 16)) & 0xFFFFFFFF
	x = (x * 0x7feb352d) & 0xFFFFFFFF
	x = (x ^ (x >> 15)) & 0xFFFFFFFF
	x = (x * 0x846ca68b) & 0xFFFFFFFF
	x = (x ^ (x >> 16)) & 0xFFFFFFFF
	return x

## Uniform [0,1) from an integer lattice point + seed.
static func _hash01(ix: int, iy: int, seed: int) -> float:
	return float(_hash_u32(ix * 374761393 + iy * 668265263 + seed * 1274126177)) / 4294967296.0

## Bilinear value noise at continuous lattice coords (smoothstep-interpolated corner hashes).
static func _vnoise(fx: float, fy: float, seed: int) -> float:
	var ix := int(floorf(fx))
	var iy := int(floorf(fy))
	var tx := fx - floorf(fx)
	var ty := fy - floorf(fy)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var a := _hash01(ix, iy, seed)
	var b := _hash01(ix + 1, iy, seed)
	var c := _hash01(ix, iy + 1, seed)
	var d := _hash01(ix + 1, iy + 1, seed)
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)

## Octave-stacked value noise (fBm), normalized back into [0,1].
static func _fbm(u: float, v: float, scale: float, octaves: int, lacunarity: float, gain: float, seed: int) -> float:
	var total := 0.0
	var amp := 1.0
	var norm := 0.0
	var freq := scale
	for o in maxi(1, octaves):
		total += amp * _vnoise(u * freq, v * freq, seed + o * 101)
		norm += amp
		amp *= gain
		freq *= lacunarity
	return total / maxf(norm, 0.0001)

## Voronoi-like cellular field: one hashed feature point per lattice cell, F1/F2 over the 3×3
## neighborhood. mode 0 → F1 (distance to nearest point, bubble cells); 1 → F2−F1 (cell-wall ridges).
static func _voronoi(u: float, v: float, cells: int, mode: int, seed: int) -> float:
	cells = maxi(2, cells)
	var fx := u * float(cells)
	var fy := v * float(cells)
	var ix := int(floor(fx))
	var iy := int(floor(fy))
	var f1 := 99.0
	var f2 := 99.0
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			var cx2 := ix + ox
			var cy2 := iy + oy
			var px := float(cx2) + _hash01(cx2, cy2, seed)
			var py := float(cy2) + _hash01(cx2, cy2, seed + 977)
			var dx := fx - px
			var dy := fy - py
			var d := sqrt(dx * dx + dy * dy)
			if d < f1:
				f2 = f1
				f1 = d
			elif d < f2:
				f2 = d
	if mode == 1:
		return clampf((f2 - f1), 0.0, 1.0)
	return clampf(f1, 0.0, 1.0)

# ---------------------------------------------------------------------------------------------------
# color — palette ramp + blend compositing
# ---------------------------------------------------------------------------------------------------

## Linear ramp lookup: t ∈ [0,1] across the handle's ordered stops.
static func _ramp(stops: Array, t: float) -> Color:
	t = clampf(t, 0.0, 1.0)
	var n := stops.size()
	if n == 0:
		return Color(t, t, t, 1.0)
	if n == 1:
		var s0: Array = stops[0]
		return Color(s0[0], s0[1], s0[2], 1.0)
	var f := t * float(n - 1)
	var i := clampi(int(floor(f)), 0, n - 2)
	var k := f - float(i)
	var a: Array = stops[i]
	var b: Array = stops[i + 1]
	return Color(lerpf(a[0], b[0], k), lerpf(a[1], b[1], k), lerpf(a[2], b[2], k), 1.0)

## Composite the layer color over the destination pixel.
static func _blend(dst: Color, c: Color, mode: String, opacity: float) -> Color:
	match mode:
		"replace":
			return c
		"multiply":
			return dst.lerp(Color(dst.r * c.r, dst.g * c.g, dst.b * c.b, 1.0), opacity)
		"add":
			return dst.lerp(Color(minf(dst.r + c.r, 1.0), minf(dst.g + c.g, 1.0), minf(dst.b + c.b, 1.0), 1.0), opacity)
		"screen":
			return dst.lerp(Color(1.0 - (1.0 - dst.r) * (1.0 - c.r), 1.0 - (1.0 - dst.g) * (1.0 - c.g), 1.0 - (1.0 - dst.b) * (1.0 - c.b), 1.0), opacity)
		_:  # "mix"
			return dst.lerp(c, opacity)
