class_name Clouds
extends RefCounted
## The CLOUD LAYER MODULE — an independently-iterable cloud layer that plugs into the SAME sky material
## as PainterlySky, wired purely as DATA (Liam's 2026-07-01 spec: "consider researching and integrating
## clouds"). Like the sky, it is its OWN module with its OWN params (`sky.clouds` in the hot-reload JSON),
## so clouds are tuned in parallel with the sky, the scene, and the painterly renderer — edit coverage /
## softness / tint / scale / seed and only the cloud layer re-bakes.
##
## ── RESEARCH → the chosen approach ──────────────────────────────────────────────────────────────────
## Options considered for clouds in this headless, portable, painterly engine:
##   1. Godot volumetric clouds  — Godot 4 has NO built-in volumetric cloud system; it would need a
##      custom sky shader or VolumetricFog hacks that don't render under the headless dummy driver.
##   2. ProceduralSkyMaterial analytic cloud params — 4.6's ProceduralSkyMaterial has NO procedural
##      cloud-coverage knob (only a `sky_cover` TEXTURE + `sky_cover_modulate` tint). So there is no
##      free analytic cloud to just switch on.
##   3. A procedural cloud COVER TEXTURE (chosen) — generate a soft cloud field on the CPU as an
##      equirectangular texture and hand it to the sky material's `sky_cover` slot, tinted by
##      `sky_cover_modulate`. This renders HEADLESS (pure Image, no GPU/compositor), is fully DATA-driven
##      (coverage / softness / tint / scale / seed / octaves), reuses the SAME integer-hash value-noise
##      family as effect_stack_cpu.gd's paper_grain (the portability invariant — identical noise in any
##      renderer), and produces SOFT, brush-like cloud shapes that sit naturally under the painterly pass.
## Choice: (3) — the simplest thing that looks good, renders headless, and stays portable DATA, exactly
## the "do as little as possible; build the seam" law. A later delegate can swap in a real volumetric
## cloud renderer against this SAME `clouds` descriptor with zero caller change.
##
## THE MECHANISM: fractal Brownian motion (fBm) of value noise → a [0..1] density field → a soft
## coverage threshold (density above `coverage` becomes cloud, feathered by `softness`) → an equirect
## RGBA texture (white cloud on transparent sky) tinted by `tint`. Bright near the top of the sky dome
## (`horizon_fade` fades clouds toward the horizon so they don't smear the skyline). Applied to the sky
## material's `sky_cover` + `sky_cover_modulate`. All knobs are JSON DATA.

## Default cloud descriptor — gentle scattered daytime clouds. Overridable from `sky.clouds` in the JSON.
static func default_descriptor() -> Dictionary:
	return {
		"enabled": true,
		"coverage": 0.50,      # 0 = clear sky, 1 = fully overcast (the density threshold)
		"softness": 0.18,      # edge feather of the cloud shapes (0 = hard cut, 1 = very soft)
		"scale": 3.4,          # size of the cloud cells (higher = smaller, more numerous puffs)
		"octaves": 5,          # fBm detail octaves (more = wispier detail)
		"seed": 21,            # reproducibility knob (an evolvable param)
		"tint": [1.0, 1.0, 1.0],   # cloud color (white); tinted via sky_cover_modulate
		"opacity": 0.95,       # overall cloud strength (the modulate alpha)
		"horizon_fade": 0.10,  # fade clouds toward the horizon so the skyline stays clean (0 = none)
		"tex_width": 640,      # cover-texture resolution (equirect); 640x320 keeps cloud edges crisp
	}

## Apply the cloud layer to a ProceduralSkyMaterial: bake a procedural cloud cover texture from the
## descriptor and bind it to the material's `sky_cover` slot (tinted by `sky_cover_modulate`). A disabled
## or absent descriptor clears the cover (no clouds) — so toggling `enabled:false` in the JSON removes the
## clouds live. Pure DATA in → the sky material gains a cloud layer, nothing else touched.
static func apply(sky_mat: ProceduralSkyMaterial, desc) -> void:
	var d: Dictionary = desc if typeof(desc) == TYPE_DICTIONARY else {}
	if not bool(d.get("enabled", true)):
		sky_mat.sky_cover = null
		return
	var tex := build_cover_texture(d)
	sky_mat.sky_cover = tex
	var tint := _col(d.get("tint", [1.0, 1.0, 1.0]))
	var opacity := clampf(float(d.get("opacity", 0.9)), 0.0, 1.0)
	sky_mat.sky_cover_modulate = Color(tint.r, tint.g, tint.b, opacity)

## Build the equirectangular cloud cover texture (white cloud on transparent sky) from the descriptor.
## Returns an ImageTexture. This is the whole cloud model: fBm value noise → soft-thresholded density →
## horizon-faded RGBA. Deterministic (seeded), headless (pure Image), portable (same noise as paper_grain).
static func build_cover_texture(desc: Dictionary) -> ImageTexture:
	var w: int = maxi(16, int(desc.get("tex_width", 512)))
	var h: int = maxi(8, w / 2)  # equirect is 2:1
	var coverage := clampf(float(desc.get("coverage", 0.42)), 0.0, 1.0)
	var softness: float = clampf(float(desc.get("softness", 0.28)), 0.001, 1.0)
	var scale: float = max(0.25, float(desc.get("scale", 3.2)))
	var octaves: int = clampi(int(desc.get("octaves", 5)), 1, 8)
	var seed := int(desc.get("seed", 21))
	var horizon_fade := clampf(float(desc.get("horizon_fade", 0.35)), 0.0, 1.0)

	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	# The density threshold: cloud where fBm density > (1 - coverage). Higher coverage lowers the bar.
	var thresh := 1.0 - coverage
	for y in h:
		# v ∈ [0..1] top→bottom of the sky dome. Fade clouds toward the horizon (v→1) so the skyline stays
		# clean; the fade band width is horizon_fade of the lower dome.
		var v := float(y) / float(maxi(1, h - 1))
		var horizon_w := 1.0
		if horizon_fade > 0.0:
			# Full strength in the upper sky, ramping to 0 across the bottom `horizon_fade` fraction.
			var band := clampf((v - (1.0 - horizon_fade)) / max(0.0001, horizon_fade), 0.0, 1.0)
			horizon_w = 1.0 - band
		for x in w:
			var u := float(x) / float(maxi(1, w - 1))
			var density := _fbm(u * scale, v * scale * 0.5, seed, octaves)  # 0..1 fBm density
			# Soft coverage: feather the threshold by `softness` → smooth cloud edges (not a hard cut).
			var cloud := smoothstep(thresh - softness, thresh + softness, density)
			cloud *= horizon_w
			# White cloud, alpha = cloud amount. Sky shows through where alpha ≈ 0 (transparent).
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, cloud))
	img.convert(Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(img)

## Fractal Brownian motion of value noise: sum `octaves` of value noise at doubling frequency + halving
## amplitude, normalized to [0..1]. The standard cloud/terrain density primitive. Uses the SAME
## integer-hash value noise as effect_stack_cpu.gd's paper_grain, so the field is identical in any
## renderer (the portability invariant every module here holds).
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
	return clampf(total / max(0.0001, norm), 0.0, 1.0)

## Deterministic integer-hash value noise in [0,1] at (fx,fy), bilinearly interpolated between lattice
## corners with a smoothstep interpolant — the identical algorithm as EffectStackCpu._value_noise, kept
## local so the cloud module is self-contained (RefCounted static libs can't call another class's private).
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
	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, ty)

## A stable [0,1] hash of (x, y, seed) — integer mixing, no float platform variance. Matches
## EffectStackCpu._hash01 exactly (the portable-noise invariant).
static func _hash01(x: int, y: int, seed: int) -> float:
	var n := (x * 374761393 + y * 668265263 + seed * 1442695040888963407) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	n = n & 0x7fffffff
	return float(n) / float(0x7fffffff)

static func _col(a) -> Color:
	if a is Color:
		return a
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		var alpha: float = float(a[3]) if (a as Array).size() >= 4 else 1.0
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color(1, 1, 1, 1)
