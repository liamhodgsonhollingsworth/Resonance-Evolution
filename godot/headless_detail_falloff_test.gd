extends SceneTree
## Headless test for the generic detail-field seam (DetailField) + the painterly falloff applier
## (PainterlyFalloff) — the first instantiation of project-generic-detail-falloff-2026-07-01. Pure
## DATA/logic, no GPU: builds detail fields from a single knob × a generic falloff curve and asserts
## the field behaves per the spec, then asserts the painterly applier VARIES the paint by that field
## (center/high-detail differs from periphery/low-detail, and the knob is the master budget).
##
## Run: <Godot> --headless --path godot -s res://headless_detail_falloff_test.gd

var _pass := 0
var _fail := 0

func _init() -> void:
	_test_uniform_is_just_the_knob()
	_test_radial_peaks_at_center_falls_to_edge()
	_test_knob_scales_the_whole_field()
	_test_vertical_and_horizontal_ramps()
	_test_unknown_curve_degrades_to_uniform()
	_test_paint_varies_by_field()
	_test_paint_knob_zero_is_all_coarse()
	_test_coarsen_stack_pushes_knobs_coarser()
	_test_lod_near_within_threshold()
	_test_lod_far_beyond_threshold()
	_test_lod_detail_extends_near_boundary()
	_test_lod_hysteresis_prevents_thrash_at_boundary()
	_test_lod_hysteresis_still_swaps_past_the_dead_zone()
	_test_lod_distance_and_near_distance_clamp_non_negative()
	_test_lod_tracker_reports_swap_only_on_change()
	_test_lod_tracker_unseen_item_defaults_far()
	_test_lod_tracker_forget_resets_state()
	print("\n[detail_falloff_test] RESULT: %s  (%d passed, %d failed)" % [
		"ALL PASS" if _fail == 0 else "FAIL", _pass, _fail])
	quit(0 if _fail == 0 else 1)

# ── DetailField ────────────────────────────────────────────────────────────────────────────────────

func _test_uniform_is_just_the_knob() -> void:
	var f := DetailField.build(8, 8, 0.6, { "type": "uniform" })
	_check(f.size() == 64, "uniform field is w*h")
	var all_knob := true
	for v in f:
		if abs(v - 0.6) > 1e-5:
			all_knob = false
	_check(all_knob, "uniform: every pixel == knob (falloff≡1)")

func _test_radial_peaks_at_center_falls_to_edge() -> void:
	var w := 33
	var h := 33
	var f := DetailField.build(w, h, 1.0, { "type": "radial", "center": [0.5, 0.5], "radius": 0.9, "edge": 0.1, "curve": 2.0 })
	var center := f[16 * w + 16]        # middle pixel
	var corner := f[0]                  # top-left corner (farthest from center)
	_check(center > 0.95, "radial: center ~= 1 (got %.3f)" % center)
	_check(corner < center, "radial: corner < center (%.3f < %.3f)" % [corner, center])
	_check(corner <= 0.2, "radial: corner near the edge floor (got %.3f)" % corner)

func _test_knob_scales_the_whole_field() -> void:
	var curve := { "type": "radial", "center": [0.5, 0.5], "radius": 0.9, "edge": 0.1, "curve": 2.0 }
	var full := DetailField.build(16, 16, 1.0, curve)
	var half := DetailField.build(16, 16, 0.5, curve)
	# The knob is a linear master multiplier, so every pixel of the half-knob field is <= the full-knob
	# field, and the center (which is un-clamped at 0.5) is exactly halved.
	var monotone := true
	for i in full.size():
		if half[i] > full[i] + 1e-5:
			monotone = false
	_check(monotone, "knob: lower knob never raises any pixel's detail")
	var cf := full[8 * 16 + 8]
	var ch := half[8 * 16 + 8]
	_check(abs(ch - cf * 0.5) < 0.02, "knob: center detail scales ~linearly with the knob")

func _test_vertical_and_horizontal_ramps() -> void:
	var vf := DetailField.build(4, 16, 1.0, { "type": "vertical", "top": 1.0, "bottom": 0.0, "curve": 1.0 })
	_check(vf[0] > vf[15 * 4], "vertical: top row > bottom row")
	var hf := DetailField.build(16, 4, 1.0, { "type": "horizontal", "left": 1.0, "right": 0.0, "curve": 1.0 })
	_check(hf[0] > hf[15], "horizontal: left col > right col")

func _test_unknown_curve_degrades_to_uniform() -> void:
	var f := DetailField.build(6, 6, 0.7, { "type": "no_such_curve" })
	var ok := true
	for v in f:
		if abs(v - 0.7) > 1e-5:
			ok = false
	_check(ok, "unknown curve degrades to uniform (== knob), never crashes")

# ── PainterlyFalloff ─────────────────────────────────────────────────────────────────────────────

func _stack() -> Dictionary:
	return { "stack": [
		{ "type": "kuwahara", "params": { "radius": 2 } },
		{ "type": "posterize", "params": { "levels": 6 } },
	] }

func _test_paint_varies_by_field() -> void:
	# A source with structure so the painterly passes actually differ between fine + coarse.
	var src := PrimRender2D.synthetic_source(48, 48)
	# A vertical field: top = full detail (fine paint), bottom = ~zero (coarse paint). The painted output
	# in the top band must therefore differ from a uniformly-coarse paint of the same band, proving the
	# field is load-bearing (the paint is NOT uniform — it follows the detail field).
	var falloff := { "type": "vertical", "top": 1.0, "bottom": 0.0, "curve": 1.0 }
	var painted := PainterlyFalloff.paint(src, _stack(), 1.0, falloff, 1.0)
	_check(painted.get_width() == 48 and painted.get_height() == 48, "paint: output matches source size")
	# Compare a top-band pixel of the field-varied paint to the SAME pixel of an all-coarse paint. Where
	# the field is high (top), the varied paint should track the FINE pass, not the coarse one → they differ.
	var all_coarse := PainterlyFalloff.paint(src, _stack(), 0.0, falloff, 1.0)  # knob 0 → field ≈ 0 → all coarse
	var diff := _max_channel_diff(painted, all_coarse, 6, 4)  # a pixel in the high-detail top band
	_check(diff > 0.001, "paint: high-detail region differs from the all-coarse paint (Δ=%.4f) — field is load-bearing" % diff)

func _test_paint_knob_zero_is_all_coarse() -> void:
	# knob=0 → field≡0 everywhere → the paint is the coarse pass everywhere. Assert it equals a direct
	# coarse-stack apply (the low pole), confirming the blend endpoint is exactly the coarse look.
	var src := PrimRender2D.synthetic_source(32, 32)
	var falloff := { "type": "radial" }
	var painted := PainterlyFalloff.paint(src, _stack(), 0.0, falloff, 1.0)
	var coarse := EffectStackCpu.apply(PainterlyFalloff.coarsen_stack(_stack(), 1.0), src)
	var d := _max_channel_diff(painted, coarse, 16, 16)
	_check(d < 0.01, "paint: knob=0 collapses to the coarse pass everywhere (Δ=%.4f)" % d)

func _test_coarsen_stack_pushes_knobs_coarser() -> void:
	var coarse := PainterlyFalloff.coarsen_stack(_stack(), 1.0)
	var layers: Array = coarse.get("stack", [])
	_check(layers.size() == 2, "coarsen: preserves layer count/order")
	var kuw: Dictionary = layers[0]
	var post: Dictionary = layers[1]
	_check(int(kuw["params"]["radius"]) > 2, "coarsen: kuwahara radius grows (broader strokes)")
	_check(int(post["params"]["levels"]) <= 6, "coarsen: posterize levels drop (flatter paint)")

# ── Truncate/LOD unification (GZ-RENDER.5, Wave 1 item 1.2) ────────────────────────────────────────

func _test_lod_near_within_threshold() -> void:
	# distance well inside near_distance, full detail budget, first-seen (starts FAR) -> swaps NEAR.
	var tier := DetailField.lod_tier_for(5.0, 1.0, DetailField.LOD_FAR, 10.0, 0.15)
	_check(tier == DetailField.LOD_NEAR, "lod_tier_for: close distance within threshold -> NEAR")

func _test_lod_far_beyond_threshold() -> void:
	var tier := DetailField.lod_tier_for(50.0, 1.0, DetailField.LOD_FAR, 10.0, 0.15)
	_check(tier == DetailField.LOD_FAR, "lod_tier_for: distance far beyond threshold -> FAR")

func _test_lod_detail_extends_near_boundary() -> void:
	# Same raw distance, two different detail budgets: a high-detail (fovea-center) item keeps NEAR
	# geometry at a distance a low-detail (periphery) item has already swapped away from — the field
	# is load-bearing on the LOD decision, not just the paint.
	var dist := 8.0
	var near_distance := 10.0
	var high_detail := DetailField.lod_tier_for(dist, 1.0, DetailField.LOD_FAR, near_distance, 0.0)
	var low_detail := DetailField.lod_tier_for(dist, 0.2, DetailField.LOD_FAR, near_distance, 0.0)
	_check(high_detail == DetailField.LOD_NEAR, "lod_tier_for: detail=1.0 at dist=8/near=10 -> NEAR")
	_check(low_detail == DetailField.LOD_FAR,
		"lod_tier_for: detail=0.2 at the SAME distance swaps to FAR sooner (boundary scales w/ detail)")

func _test_lod_hysteresis_prevents_thrash_at_boundary() -> void:
	# boundary = 10.0 at detail=1.0. An item already NEAR, wobbling just past the raw boundary but
	# still inside the hysteresis dead zone, must STAY near (no pop every frame).
	var near_distance := 10.0
	var hysteresis := 0.2  # dead zone = 2.0 world units on the "away from current tier" side
	var still_near := DetailField.lod_tier_for(11.0, 1.0, DetailField.LOD_NEAR, near_distance, hysteresis)
	_check(still_near == DetailField.LOD_NEAR,
		"lod_tier_for: NEAR item just past raw boundary (11 > 10) stays NEAR inside the hysteresis dead zone")
	# Symmetric check the other direction: an item already FAR, wobbling just inside the raw boundary
	# but still outside the dead zone on the FAR side, must STAY far.
	var still_far := DetailField.lod_tier_for(9.0, 1.0, DetailField.LOD_FAR, near_distance, hysteresis)
	_check(still_far == DetailField.LOD_FAR,
		"lod_tier_for: FAR item just inside raw boundary (9 < 10) stays FAR inside the hysteresis dead zone")

func _test_lod_hysteresis_still_swaps_past_the_dead_zone() -> void:
	var near_distance := 10.0
	var hysteresis := 0.2
	# NEAR -> FAR requires distance > boundary + margin = 10 + 2 = 12.
	var swapped_to_far := DetailField.lod_tier_for(13.0, 1.0, DetailField.LOD_NEAR, near_distance, hysteresis)
	_check(swapped_to_far == DetailField.LOD_FAR,
		"lod_tier_for: NEAR item well past the dead zone (13 > 12) swaps to FAR")
	# FAR -> NEAR requires distance < boundary - margin = 10 - 2 = 8.
	var swapped_to_near := DetailField.lod_tier_for(7.0, 1.0, DetailField.LOD_FAR, near_distance, hysteresis)
	_check(swapped_to_near == DetailField.LOD_NEAR,
		"lod_tier_for: FAR item well inside the dead zone (7 < 8) swaps to NEAR")

func _test_lod_distance_and_near_distance_clamp_non_negative() -> void:
	var tier_neg_distance := DetailField.lod_tier_for(-5.0, 1.0, DetailField.LOD_FAR, 10.0, 0.0)
	_check(tier_neg_distance == DetailField.LOD_NEAR,
		"lod_tier_for: negative distance clamps to 0 (always within any positive threshold) -> NEAR")
	var tier_zero_near := DetailField.lod_tier_for(1.0, 1.0, DetailField.LOD_FAR, 0.0, 0.0)
	_check(tier_zero_near == DetailField.LOD_FAR,
		"lod_tier_for: near_distance clamps to a tiny positive minimum, never divides by/produces zero")

func _test_lod_tracker_reports_swap_only_on_change() -> void:
	var tracker := DetailField.DetailLODTracker.new()
	var r1 := tracker.update("item_a", 5.0, 1.0, 10.0, 0.15)
	_check(r1["tier"] == DetailField.LOD_NEAR and r1["swapped"] == true and r1["previous_tier"] == DetailField.LOD_FAR,
		"DetailLODTracker: first update to NEAR reports swapped=true, previous=FAR")
	var r2 := tracker.update("item_a", 5.5, 1.0, 10.0, 0.15)
	_check(r2["tier"] == DetailField.LOD_NEAR and r2["swapped"] == false,
		"DetailLODTracker: staying NEAR next frame reports swapped=false")
	_check(tracker.tier_of("item_a") == DetailField.LOD_NEAR, "DetailLODTracker: tier_of reflects committed state")

func _test_lod_tracker_unseen_item_defaults_far() -> void:
	var tracker := DetailField.DetailLODTracker.new()
	_check(tracker.tier_of("never_seen") == DetailField.LOD_FAR,
		"DetailLODTracker: tier_of an unseen item defaults to FAR (cheap default)")

func _test_lod_tracker_forget_resets_state() -> void:
	var tracker := DetailField.DetailLODTracker.new()
	tracker.update("item_b", 5.0, 1.0, 10.0, 0.15)  # -> NEAR
	tracker.forget("item_b")
	_check(tracker.tier_of("item_b") == DetailField.LOD_FAR,
		"DetailLODTracker: forget() resets an item to the unseen/FAR default")
	var r := tracker.update("item_b", 5.0, 1.0, 10.0, 0.15)
	_check(r["swapped"] == true and r["previous_tier"] == DetailField.LOD_FAR,
		"DetailLODTracker: a forgotten item that reappears starts fresh (swap from FAR again), not stale hysteresis")

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────

func _max_channel_diff(a: Image, b: Image, x: int, y: int) -> float:
	var ca := a.get_pixel(x, y)
	var cb := b.get_pixel(x, y)
	return maxf(maxf(abs(ca.r - cb.r), abs(ca.g - cb.g)), abs(ca.b - cb.b))

func _check(cond: bool, label: String) -> void:
	if cond:
		_pass += 1
		print("  ok   %s" % label)
	else:
		_fail += 1
		printerr("  FAIL %s" % label)
