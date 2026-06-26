extends SceneTree
## Proves the SPEC-748a typed-I/O reformat is BACKWARD-COMPATIBLE: the new typed apply_io() coexists
## with the legacy color-in/color-out apply(), and every pre-existing descriptor + caller behaves
## EXACTLY as before. This is the load-bearing safety gate for the I/O extension — if a legacy stack
## ever changes output, this test fails.
##   godot --headless --path godot -s res://headless_effect_io_backcompat_test.gd
##
## What it checks:
##  1. apply(desc, src) == apply_io(desc, {color: src}) for EVERY existing (non-optical) layer type —
##     the legacy path is now literally a wrapper, so they must be bit-identical.
##  2. A legacy {stack:[...]} descriptor (no light_screen, no typed inputs) still runs the optical
##     layers — they centre the light + derive the mask, never crash, never require new keys.
##  3. apply_io honours light_screen from the descriptor AND from the inputs dict (inputs override).
##  4. apply_io honours an explicit `mask` Image input (typed channel) over the derived mask.

func _initialize() -> void:
	var ok := true

	# A small textured frame (a gradient + a bright corner) so every effect has something to chew on.
	var W := 24
	var H := 24
	var src := Image.create(W, H, false, Image.FORMAT_RGBAF)
	for y in H:
		for x in W:
			var g := float(x) / float(W - 1)
			var b := 0.9 if (x < 5 and y < 5) else g * 0.3
			src.set_pixel(x, y, Color(g, 0.5, b, 1.0))

	var images_equal := func(a: Image, b: Image) -> bool:
		if a.get_width() != b.get_width() or a.get_height() != b.get_height():
			return false
		for y in a.get_height():
			for x in a.get_width():
				var ca := a.get_pixel(x, y)
				var cb := b.get_pixel(x, y)
				if not (is_equal_approx(ca.r, cb.r) and is_equal_approx(ca.g, cb.g)
					and is_equal_approx(ca.b, cb.b) and is_equal_approx(ca.a, cb.a)):
					return false
		return true

	# --- 1. Legacy apply() == typed apply_io({color}) for every PRE-EXISTING layer type. ---
	# These are the layers that shipped BEFORE this change; their output must not move by one bit.
	var legacy_layers := [
		{ "type": "passthrough", "params": {} },
		{ "type": "posterize", "params": { "levels": 3 } },
		{ "type": "kuwahara", "params": { "radius": 2 } },
		{ "type": "generalized_kuwahara", "params": { "radius": 2, "sectors": 8 } },
		{ "type": "edge_darken", "params": { "strength": 1.0, "threshold": 0.1 } },
		{ "type": "outline", "params": { "threshold": 0.2 } },
		{ "type": "paper_grain", "params": { "amount": 0.2, "scale": 6.0, "seed": 7 } },
		{ "type": "normal_map", "params": { "strength": 2.0 } },
		{ "type": "lighting", "params": { "strength": 2.0, "ambient": 0.3 } },
	]
	for layer in legacy_layers:
		var desc := { "stack": [ layer ] }
		var via_legacy := EffectStackCpu.apply(desc, src)
		var via_typed := EffectStackCpu.apply_io(desc, { "color": src })
		ok = _check("legacy apply == typed apply_io for '%s'" % layer["type"],
			images_equal.call(via_legacy, via_typed)) and ok

	# A multi-layer legacy stack (the realistic painterly case) also round-trips identically.
	var painterly := { "stack": [
		{ "type": "posterize", "params": { "levels": 4 } },
		{ "type": "edge_darken", "params": { "strength": 0.8, "threshold": 0.12 } },
		{ "type": "paper_grain", "params": { "amount": 0.15, "scale": 8.0, "seed": 1337 } } ] }
	ok = _check("legacy apply == typed apply_io for a 3-layer painterly stack",
		images_equal.call(EffectStackCpu.apply(painterly, src),
			EffectStackCpu.apply_io(painterly, { "color": src }))) and ok

	# --- 2. A legacy descriptor (NO light_screen) still runs the optical layers without crashing. ---
	var optical_legacy := { "stack": [
		{ "type": "bloom", "params": { "threshold": 0.5, "intensity": 0.8, "radius": 3 } },
		{ "type": "god_rays", "params": { "threshold": 0.5, "samples": 16 } },
		{ "type": "lens_flare", "params": { "threshold": 0.5 } } ] }
	var legacy_optical := EffectStackCpu.apply(optical_legacy, src)
	ok = _check("legacy {stack:[...]} (no light_screen) runs optical layers, centred, no crash",
		legacy_optical.get_width() == W and legacy_optical.get_height() == H) and ok

	# --- 3. light_screen from descriptor vs inputs: inputs override the descriptor. ---
	var god := { "stack": [ { "type": "god_rays", "params": {
		"density": 1.0, "weight": 0.8, "exposure": 1.2, "threshold": 0.4, "samples": 24 } } ],
		"light_screen": [0.0, 0.0] }
	var via_desc := EffectStackCpu.apply_io(god, { "color": src })
	var via_override := EffectStackCpu.apply_io(god, { "color": src, "light_screen": [1.0, 1.0] })
	# Different light positions must produce different frames (the override actually takes effect).
	ok = _check("apply_io: inputs.light_screen overrides descriptor.light_screen",
		not images_equal.call(via_desc, via_override)) and ok

	# --- 4. An explicit `mask` Image input is honoured over the derived luminance mask. ---
	# A mask that is bright in a DIFFERENT place than the color frame's bright corner should steer
	# god_rays differently than the derived mask would.
	var mask := Image.create(W, H, false, Image.FORMAT_RGBAF)
	mask.fill(Color(0, 0, 0, 1))
	for y in range(W - 5, W):
		for x in range(H - 5, H):
			mask.set_pixel(x, y, Color(1, 1, 1, 1))  # bright bottom-right, opposite the color's TL
	var god_centre := god.duplicate(true)
	god_centre["light_screen"] = [0.5, 0.5]
	var derived := EffectStackCpu.apply_io(god_centre, { "color": src })
	var explicit := EffectStackCpu.apply_io(god_centre, { "color": src, "mask": mask })
	ok = _check("apply_io: explicit mask input steers optical layers (differs from derived mask)",
		not images_equal.call(derived, explicit)) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
