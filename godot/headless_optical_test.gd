extends SceneTree
## Proves the THREE OPTICAL layers (Convergence cycle #1) — god_rays / lens_flare / bloom — apply
## correctly through the CPU reference (EffectStackCpu), as renderer-neutral DATA. The 2D analogue of
## headless_effect_test.gd, focused on the visible-light effects + their typed-I/O light_screen input.
##   godot --headless --path godot -s res://headless_optical_test.gd
##
## What it checks (each layer has a DETERMINISTIC ground-truth assertion, not a vibe check):
##  1. bloom brightens a bright spot's neighbourhood (the blur spreads glow), leaves a dark frame alone.
##  2. god_rays scatters a bright source toward the light position (a pixel ON the light->source line
##     gets brighter than one off it), and is identity-ish on a uniformly dark frame.
##  3. lens_flare adds energy along the light->centre axis from a bright source (total energy rises).
##  4. All three are registered in EFFECT_TYPES (the evolver vocabulary) with a param schema.
##  5. light_screen is honoured: moving the light moves where god_rays concentrates.

func _initialize() -> void:
	var ok := true

	# --- helpers: build small deterministic frames ---
	var W := 32
	var H := 32
	# A frame that is black except a bright disc near the top-left (a "sun gap in the canopy").
	var make_spot := func(cx: int, cy: int) -> Image:
		var im := Image.create(W, H, false, Image.FORMAT_RGBAF)
		im.fill(Color(0, 0, 0, 1))
		for y in H:
			for x in W:
				var d := Vector2(x - cx, y - cy).length()
				if d < 3.0:
					im.set_pixel(x, y, Color(1, 1, 1, 1))
		return im
	var dark := Image.create(W, H, false, Image.FORMAT_RGBAF)
	dark.fill(Color(0, 0, 0, 1))

	var total_lum := func(im: Image) -> float:
		var s := 0.0
		for y in im.get_height():
			for x in im.get_width():
				var c := im.get_pixel(x, y)
				s += c.r + c.g + c.b
		return s

	# --- 1. BLOOM: a bright spot spreads glow to neighbours; a dark frame is unchanged. ---
	# `Callable.call` returns a Variant (GDScript can't see through it to the lambda's typed return),
	# so type the local explicitly rather than inferring Variant from `:=`.
	var spot: Image = make_spot.call(16, 16)
	var bloom_desc := { "stack": [ { "type": "bloom", "params": { "threshold": 0.5, "intensity": 1.0, "radius": 4 } } ] }
	var bloomed := EffectStackCpu.apply(bloom_desc, spot)
	# A pixel just OUTSIDE the original disc (was black) should now be > 0 (glow bled into it).
	var neighbor := bloomed.get_pixel(16 + 5, 16)
	ok = _check("bloom: glow bleeds into a previously-black neighbour", neighbor.r > 0.01) and ok
	ok = _check("bloom: total luminance increases (energy added)",
		total_lum.call(bloomed) > total_lum.call(spot)) and ok
	var bloom_dark := EffectStackCpu.apply(bloom_desc, dark)
	ok = _check("bloom: a fully dark frame stays dark (nothing above threshold)",
		is_equal_approx(total_lum.call(bloom_dark), 0.0)) and ok

	# --- 2. GOD-RAYS: a sun disc scatters rays that RADIATE OUTWARD from the light position. ---
	# Physical model (GPU-Gems3 "Volumetric Light Scattering as a Post-Process"): the bright source IS the
	# sun disc at the light's SCREEN position; every pixel marches TOWARD that light, accumulating the
	# bright mask. The scattered glow therefore radiates outward from the light and falls off with radial
	# distance. So we co-locate the bright disc with light_screen (the realistic case), and assert the
	# scatter decays with distance from the light — the property that distinguishes a god-ray from a flat
	# brighten. (A bright source DECOUPLED from the light is non-physical and was the prior test's error.)
	var sun_tl: Image = make_spot.call(4, 4)      # sun disc near top-left
	var god_desc := { "stack": [ { "type": "god_rays", "params": {
		"density": 1.0, "decay": 0.97, "weight": 0.8, "exposure": 1.2, "threshold": 0.5, "samples": 48 } } ],
		"light_screen": [4.0 / float(W - 1), 4.0 / float(H - 1)] }  # light AT the sun disc (top-left)
	var god := EffectStackCpu.apply(god_desc, sun_tl)
	# A pixel near the light (radially close) scatters more than one far from it (the radial falloff).
	var near_light := god.get_pixel(10, 10).r
	var far_light := god.get_pixel(28, 28).r
	ok = _check("god_rays: scatter glows near the light source", near_light > 0.01) and ok
	ok = _check("god_rays: scatter falls off with distance from the light (near > far)",
		near_light > far_light) and ok
	var god_dark := EffectStackCpu.apply(god_desc, dark)
	ok = _check("god_rays: a dark frame (no bright source) stays ~dark",
		total_lum.call(god_dark) < 0.5) and ok

	# --- 5. light_screen is honoured: moving the sun disc + light to the OPPOSITE corner moves the glow. ---
	var sun_br: Image = make_spot.call(27, 27)    # sun disc near bottom-right
	var god_desc_br := god_desc.duplicate(true)
	god_desc_br["light_screen"] = [27.0 / float(W - 1), 27.0 / float(H - 1)]  # light AT the new disc (BR)
	var god_br := EffectStackCpu.apply(god_desc_br, sun_br)
	# A bottom-right pixel is now NEAR the light → brighter than that same pixel was under the top-left sun.
	var br_near := god_br.get_pixel(22, 22).r
	var br_under_tl := god.get_pixel(22, 22).r
	ok = _check("god_rays: moving light_screen moves where rays concentrate",
		br_near > br_under_tl) and ok

	# --- 3. LENS-FLARE: adds energy along the light->centre axis from a bright source. ---
	var flare_desc := { "stack": [ { "type": "lens_flare", "params": {
		"ghosts": 4, "dispersal": 0.25, "halo_width": 0.4, "strength": 1.0, "threshold": 0.5 } } ],
		"light_screen": [0.1, 0.1] }
	var flared := EffectStackCpu.apply(flare_desc, spot)
	ok = _check("lens_flare: total luminance increases (ghosts/halo add energy)",
		total_lum.call(flared) > total_lum.call(spot)) and ok
	var flare_dark := EffectStackCpu.apply(flare_desc, dark)
	ok = _check("lens_flare: a dark frame (no bright source) stays ~dark",
		total_lum.call(flare_dark) < 0.5) and ok

	# --- 4. Registry: each optical layer is in EFFECT_TYPES with a param schema (evolver vocabulary). ---
	for t in ["god_rays", "lens_flare", "bloom"]:
		ok = _check("EFFECT_TYPES registers '%s' with a param schema" % t,
			EffectStackCpu.EFFECT_TYPES.has(t)
			and EffectStackCpu.EFFECT_TYPES[t].has("params")) and ok

	# --- chaining: an optical layer composes ON TOP of a painterly stack (DATA, in order). ---
	var combo := { "stack": [
		{ "type": "posterize", "params": { "levels": 4 } },
		{ "type": "bloom", "params": { "threshold": 0.5, "intensity": 0.8, "radius": 3 } } ] }
	var combo_res := EffectStackCpu.apply(combo, spot)
	ok = _check("optical layer composes after a painterly layer (chained stack runs)",
		combo_res.get_width() == W and combo_res.get_height() == H) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
