extends SceneTree
## Proves the L2 PAINTERLY EFFECT LIBRARY: each new effect type emits renderer-neutral DATA the CPU
## oracle (EffectStackCpu) applies deterministically. Companion to headless_effect_test.gd (which
## proves the L0 seam + posterize). Every effect here is verified against a hand-checkable ground truth
## on a tiny synthetic image — no shaders, no GPU, headless.
##   godot --headless --path godot -s res://headless_effect_library_test.gd
##
## Covers: kuwahara, generalized_kuwahara, edge_darken, outline, paper_grain — plus the EFFECT_TYPES
## vocabulary mirror (so the evolver and the applier never drift), and a multi-layer painterly stack.

func _initialize() -> void:
	var ok := true

	# A 4x4 test image: left half dark grey (0.2), right half light grey (0.8) → a clean vertical edge
	# down the middle. Hand-checkable ground truth for every neighbourhood effect.
	var edge := func() -> Image:
		var im := Image.create(4, 4, false, Image.FORMAT_RGBAF)
		for y in 4:
			for x in 4:
				var v: float = 0.2 if x < 2 else 0.8
				im.set_pixel(x, y, Color(v, v, v, 1.0))
		return im

	# --- 0. The vocabulary mirror exists and lists every implemented effect with a param schema. ---
	for t in ["passthrough", "posterize", "kuwahara", "generalized_kuwahara", "edge_darken", "outline", "paper_grain", "normal_map", "lighting", "temporal_stability"]:
		ok = _check("EFFECT_TYPES knows '%s'" % t, EffectStackCpu.EFFECT_TYPES.has(t)) and ok

	# --- 1. KUWAHARA: edge-preserving. On the vertical-edge image it must NOT blur the edge to a
	# uniform grey — a left-column pixel stays near 0.2, a right-column near 0.8 (the lowest-variance
	# quadrant lies wholly on one side of the edge). A naive box blur would average to ~0.5. ---
	var k := EffectStackCpu.apply({ "stack": [ { "type": "kuwahara", "params": { "radius": 1 } } ] }, edge.call())
	var kl := k.get_pixel(0, 1).r
	var kr := k.get_pixel(3, 1).r
	ok = _check("kuwahara keeps the dark side dark (left ~0.2, not blurred to 0.5)", kl < 0.35) and ok
	ok = _check("kuwahara keeps the light side light (right ~0.8, not blurred to 0.5)", kr > 0.65) and ok
	ok = _check("kuwahara preserves alpha", is_equal_approx(k.get_pixel(0, 0).a, 1.0)) and ok

	# On a perfectly FLAT image kuwahara is identity (every quadrant has zero variance, mean = value).
	var flat := Image.create(3, 3, false, Image.FORMAT_RGBAF)
	for y in 3:
		for x in 3:
			flat.set_pixel(x, y, Color(0.5, 0.4, 0.3, 1.0))
	var kf := EffectStackCpu.apply({ "stack": [ { "type": "kuwahara", "params": { "radius": 1 } } ] }, flat)
	ok = _check("kuwahara on a flat image is identity", _approx_color(kf.get_pixel(1, 1), Color(0.5, 0.4, 0.3, 1.0))) and ok

	# --- 2. GENERALIZED KUWAHARA: also edge-preserving (different sector geometry, same invariant). ---
	var gk := EffectStackCpu.apply({ "stack": [ { "type": "generalized_kuwahara", "params": { "radius": 2, "sectors": 8 } } ] }, edge.call())
	ok = _check("generalized_kuwahara keeps the edge (left dark, right light)",
		gk.get_pixel(0, 1).r < 0.5 and gk.get_pixel(3, 1).r > 0.5) and ok
	var gkf := EffectStackCpu.apply({ "stack": [ { "type": "generalized_kuwahara", "params": { "radius": 1, "sectors": 8 } } ] }, flat)
	ok = _check("generalized_kuwahara on a flat image is identity", _approx_color(gkf.get_pixel(1, 1), Color(0.5, 0.4, 0.3, 1.0))) and ok

	# --- 3. EDGE_DARKEN: pixels AT the edge get darker; pixels in the flat interior are untouched. ---
	var ed := EffectStackCpu.apply({ "stack": [ { "type": "edge_darken", "params": { "strength": 1.0, "threshold": 0.05 } } ] }, edge.call())
	# Column 1 and 2 straddle the edge → high Sobel magnitude → darkened. A far-corner flat pixel is not.
	var edge_px := ed.get_pixel(1, 1).r
	ok = _check("edge_darken darkens the contour (col-1 < original 0.2)", edge_px < 0.2) and ok
	# A fully-uniform image has zero gradient everywhere → edge_darken is identity.
	var edf := EffectStackCpu.apply({ "stack": [ { "type": "edge_darken", "params": { "strength": 1.0, "threshold": 0.0 } } ] }, flat)
	ok = _check("edge_darken on a flat image is identity (no gradient → no darkening)",
		_approx_color(edf.get_pixel(1, 1), Color(0.5, 0.4, 0.3, 1.0))) and ok

	# --- 4. OUTLINE: edge pixels become the line color, flat pixels become bg. With default black/clear,
	# the edge columns are opaque black and the flat far edges are transparent. ---
	var ol := EffectStackCpu.apply({ "stack": [ { "type": "outline", "params": { "threshold": 0.1 } } ] }, edge.call())
	ok = _check("outline marks the contour black+opaque", _approx_color(ol.get_pixel(1, 1), Color(0, 0, 0, 1))) and ok
	# The leftmost column on a flat-clamped border has no horizontal gradient → bg (transparent).
	var ol_flat_corner := ol.get_pixel(0, 0)
	ok = _check("outline leaves flat regions as transparent bg", ol_flat_corner.a < 0.5) and ok
	# Custom colors round-trip through the descriptor (JSON-portable [r,g,b,a]).
	var ol2 := EffectStackCpu.apply({ "stack": [ { "type": "outline", "params": {
		"threshold": 0.1, "color": [1.0, 0.0, 0.0, 1.0], "bg": [0.0, 0.0, 1.0, 1.0]
	} } ] }, edge.call())
	ok = _check("outline honours custom color param (edge → red)", _approx_color(ol2.get_pixel(1, 1), Color(1, 0, 0, 1))) and ok

	# --- 5. PAPER_GRAIN: deterministic (same seed → same output) and seed-sensitive (different seed →
	# different output). amount=0 is identity. ---
	var g_a := EffectStackCpu.apply({ "stack": [ { "type": "paper_grain", "params": { "amount": 0.5, "scale": 2.0, "seed": 7 } } ] }, flat)
	var g_b := EffectStackCpu.apply({ "stack": [ { "type": "paper_grain", "params": { "amount": 0.5, "scale": 2.0, "seed": 7 } } ] }, flat)
	ok = _check("paper_grain is deterministic (same seed → identical pixel)", _approx_color(g_a.get_pixel(1, 1), g_b.get_pixel(1, 1))) and ok
	var g_c := EffectStackCpu.apply({ "stack": [ { "type": "paper_grain", "params": { "amount": 0.5, "scale": 2.0, "seed": 99 } } ] }, flat)
	ok = _check("paper_grain is seed-sensitive (different seed → different field)", not _approx_color(g_a.get_pixel(0, 0), g_c.get_pixel(0, 0))) and ok
	var g_zero := EffectStackCpu.apply({ "stack": [ { "type": "paper_grain", "params": { "amount": 0.0, "scale": 4.0, "seed": 7 } } ] }, flat)
	ok = _check("paper_grain amount=0 is identity", _approx_color(g_zero.get_pixel(1, 1), Color(0.5, 0.4, 0.3, 1.0))) and ok

	# --- L4.1 NORMAL_MAP: a FLAT image (zero gradient) → the canonical flat-normal blue (0.5,0.5,1.0).
	# A vertical luminance edge → a non-flat normal whose RED channel (encoding nx) departs from 0.5 at
	# the edge columns (the slope is horizontal). Alpha is carried through. ---
	var nm_flat := EffectStackCpu.apply({ "stack": [ { "type": "normal_map", "params": { "strength": 2.0 } } ] }, flat)
	ok = _check("normal_map on a flat image is the flat-normal blue (0.5,0.5,1.0)",
		_approx_color(nm_flat.get_pixel(1, 1), Color(0.5, 0.5, 1.0, 1.0))) and ok
	var nm_edge := EffectStackCpu.apply({ "stack": [ { "type": "normal_map", "params": { "strength": 2.0 } } ] }, edge.call())
	ok = _check("normal_map tilts the normal at a luminance edge (red channel leaves 0.5)",
		absf(nm_edge.get_pixel(1, 1).r - 0.5) > 0.01) and ok
	ok = _check("normal_map preserves alpha", is_equal_approx(nm_edge.get_pixel(1, 1).a, 1.0)) and ok
	var nm_zero := EffectStackCpu.apply({ "stack": [ { "type": "normal_map", "params": { "strength": 0.0 } } ] }, edge.call())
	ok = _check("normal_map strength=0 is flat blue everywhere (no relief)",
		_approx_color(nm_zero.get_pixel(1, 1), Color(0.5, 0.5, 1.0, 1.0))) and ok

	# --- L4.2 LIGHTING: ambient=1 is identity (fully lit). On a flat image (constant normal (0,0,1)) the
	# shade is uniform → every pixel scaled by the same factor (relative tone preserved). strength=0 also
	# → constant normal → uniform shade. The edge gets a NON-uniform shade (relief catches the light). ---
	var lit_amb1 := EffectStackCpu.apply({ "stack": [ { "type": "lighting", "params": { "ambient": 1.0, "strength": 2.0 } } ] }, flat)
	ok = _check("lighting ambient=1 is identity (fully lit)", _approx_color(lit_amb1.get_pixel(1, 1), Color(0.5, 0.4, 0.3, 1.0))) and ok
	var lit_flat := EffectStackCpu.apply({ "stack": [ { "type": "lighting", "params": { "ambient": 0.3, "strength": 2.0, "light_x": 0.0, "light_y": 0.0, "light_z": 1.0 } } ] }, flat)
	# Flat normal (0,0,1) dot straight-down light (0,0,1) = 1 → shade = ambient + (1-ambient)*1 = 1 → identity.
	ok = _check("lighting on a flat image with top light is fully lit (shade=1)", _approx_color(lit_flat.get_pixel(1, 1), Color(0.5, 0.4, 0.3, 1.0))) and ok
	var lit_dark := EffectStackCpu.apply({ "stack": [ { "type": "lighting", "params": { "ambient": 0.2, "strength": 2.0, "light_x": 1.0, "light_y": 0.0, "light_z": 0.0 } } ] }, flat)
	# Flat normal (0,0,1) dot a purely-SIDEWAYS light (1,0,0) = 0 → shade = ambient only = 0.2 → darkened.
	ok = _check("lighting with a grazing (sideways) light darkens a flat surface to ambient",
		lit_dark.get_pixel(1, 1).r < 0.5 * 0.5) and ok
	ok = _check("lighting preserves alpha", is_equal_approx(lit_dark.get_pixel(0, 0).a, 1.0)) and ok

	# --- L4.3 TEMPORAL_STABILITY: blend toward a previous frame. blend=0 (or no prev) → identity; blend=1
	# → freeze to prev; blend=0.5 → the exact midpoint of current and prev (per channel). prev is supplied
	# as the renderer-neutral serialized payload {w,h,pixels:[[r,g,b,a],...]} (JSON-portable). ---
	var cur := Image.create(2, 2, false, Image.FORMAT_RGBAF)
	for y in 2:
		for x in 2:
			cur.set_pixel(x, y, Color(0.8, 0.8, 0.8, 1.0))  # current = light grey
	var prev_payload := { "w": 2, "h": 2, "pixels": [
		[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0],
		[0.0, 0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0],
	] }  # prev = black
	var ts_id := EffectStackCpu.apply({ "stack": [ { "type": "temporal_stability", "params": { "blend": 0.0, "prev": prev_payload } } ] }, cur)
	ok = _check("temporal_stability blend=0 is identity (history ignored)", _approx_color(ts_id.get_pixel(0, 0), Color(0.8, 0.8, 0.8, 1.0))) and ok
	var ts_noprev := EffectStackCpu.apply({ "stack": [ { "type": "temporal_stability", "params": { "blend": 0.9 } } ] }, cur)
	ok = _check("temporal_stability with no prev is identity (first frame has no history)", _approx_color(ts_noprev.get_pixel(0, 0), Color(0.8, 0.8, 0.8, 1.0))) and ok
	var ts_freeze := EffectStackCpu.apply({ "stack": [ { "type": "temporal_stability", "params": { "blend": 1.0, "prev": prev_payload } } ] }, cur)
	ok = _check("temporal_stability blend=1 freezes to prev (→ black)", _approx_color(ts_freeze.get_pixel(0, 0), Color(0.0, 0.0, 0.0, 1.0))) and ok
	var ts_half := EffectStackCpu.apply({ "stack": [ { "type": "temporal_stability", "params": { "blend": 0.5, "prev": prev_payload } } ] }, cur)
	ok = _check("temporal_stability blend=0.5 is the midpoint of current(0.8) and prev(0.0) → 0.4", is_equal_approx(ts_half.get_pixel(0, 0).r, 0.4)) and ok
	# A size-mismatched prev is dropped (can't blend pixel-wise) → identity, never a crash.
	var ts_mismatch := EffectStackCpu.apply({ "stack": [ { "type": "temporal_stability", "params": { "blend": 0.9, "prev": { "w": 4, "h": 4, "pixels": [] } } } ] }, cur)
	ok = _check("temporal_stability with a size-mismatched prev is identity (fail-safe)", _approx_color(ts_mismatch.get_pixel(0, 0), Color(0.8, 0.8, 0.8, 1.0))) and ok

	# --- 6. A MULTI-LAYER PAINTERLY STACK applies all layers in order, returns a valid image, leaves
	# the source untouched (the renderer-neutral "arcane painted look" recipe the char-creation arc reuses). ---
	var src: Image = edge.call()
	var painted := EffectStackCpu.apply({ "stack": [
		{ "type": "kuwahara", "params": { "radius": 1 } },
		{ "type": "posterize", "params": { "levels": 4 } },
		{ "type": "edge_darken", "params": { "strength": 0.8, "threshold": 0.1 } },
		{ "type": "paper_grain", "params": { "amount": 0.1, "scale": 4.0, "seed": 1337 } },
	] }, src)
	ok = _check("multi-layer painterly stack returns a same-size image", painted.get_width() == 4 and painted.get_height() == 4) and ok
	ok = _check("multi-layer stack leaves the source image untouched", is_equal_approx(src.get_pixel(0, 0).r, 0.2)) and ok

	# --- 7. Every effect_stack descriptor in this test round-trips through JSON (portability). ---
	var sample := { "stack": [
		{ "type": "kuwahara", "params": { "radius": 2 } },
		{ "type": "outline", "params": { "threshold": 0.2, "color": [0.0, 0.0, 0.0, 1.0] } },
	] }
	var rep = JSON.parse_string(JSON.stringify(sample))
	ok = _check("L2 descriptors round-trip through JSON (renderer-neutral DATA)",
		rep != null and rep.get("stack", []).size() == 2 and String(rep["stack"][0]["type"]) == "kuwahara") and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _approx_color(a: Color, b: Color) -> bool:
	return is_equal_approx(a.r, b.r) and is_equal_approx(a.g, b.g) and is_equal_approx(a.b, b.b) and is_equal_approx(a.a, b.a)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
