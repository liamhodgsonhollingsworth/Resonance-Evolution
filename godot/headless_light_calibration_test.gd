extends SceneTree
## Headless verification of LIGHT CALIBRATION (visi-sonor Wave 3B, spec item 5): camera-feedback
## offset + drift for a room of addressable lights, built by RE-WIRING THE SAME projection nodes the
## projection-mapping arc already ships (Liam's explicit "SHOULD USE THE SAME NODES as projection-
## mapping"). The spatial closed loop is prim_projection_observe -> prim_projection_calibration ->
## re-map, VERBATIM; the only new engine code is prim_temporal_offset_estimate (the temporal analog of
## the existing spatial homography step) + a plain per-light correction record. The actuator differs
## (device.set_led instead of a projector output) but the observe -> fit -> invert -> refit ->
## damped-blend -> converge loop is byte-for-byte the projection loop.
##
##   godot --headless --path godot --editor --quit      (once, to build the class cache)
##   godot --headless --path godot -s res://headless_light_calibration_test.gd
##
## Asserts:
##   (A) prim_temporal_offset_estimate self-tests: cross-correlation of an emitted pulse vs a
##       LATENCY-SHIFTED observed brightness recovers the injected latency in ms; a zero-shift pair
##       reads ~0 ms; absent / ragged input is a graceful no-op (0 ms, valid=false) — NEVER a crash.
##   (B) The offset-correction record is plain DATA (timing_offset_ms / color_offset / intensity_gain),
##       JSON-round-trips, and the color/intensity skew are recovered from commanded-vs-observed pairs.
##   (C) The light_calibration.json arrangement wires up over the SAME projection primitives + a
##       device.set_led emit step: the initial random per-light spatial offset is REAL (> 15 px) and
##       every commanded light is observed by the witness camera.
##   (D) The camera-feedback loop REDUCES the measured offset over iterations (prim_compare_diff as the
##       convergence oracle) and lands under threshold — the same homography descent as calibration.
##   (E) LIVE DRIFT: inject a slowly-changing offset each frame and assert the damped loop (gain < 1)
##       TRACKS it down — the "re-run the loop at low rate with damped gain = live drift tracker" claim.
##   (F) The control-METHOD taxonomy (ir / bluetooth / networked_precise / random) rides as per-node
##       latency/offset metadata and is echoed on the correction record; a "random" channel with a big
##       offset still converges (the loop SOLVES the random offset).

const ARRANGEMENT := "res://arrangements/light_calibration.json"
const THRESHOLD := 1.0
const MAX_ITERS := 12

# WorldActions / DeviceActions are preload-only modules (extends RefCounted, no class_name), so they are
# NOT global identifiers — the existing device test preloads them the same way (headless_visisonor_device_test.gd).
const WorldActions := preload("res://runtime/world_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")

func _initialize() -> void:
	var ok := true

	# ── (A) temporal offset estimator self-tests ────────────────────────────────────────────
	# Build an emitted APERIODIC probe (a single flash burst — what a calibration pulse actually is:
	# one timed color pulse, not a periodic train, so the correlation peak is UNIQUE and the latency
	# is identifiable) and an observed-brightness timeline that is the SAME probe shifted by a known
	# latency. Cross-correlation must recover it. (A periodic probe is latency-ambiguous at multiples
	# of its period — a real calibrator flashes an aperiodic one-shot precisely to avoid that.)
	var dt_ms := 10.0                       # 100 Hz sampling
	var emitted := _burst(64, 12, 6)        # 64 samples, a single flash: ramp-up at 12, width 6
	var latency_samples := 5
	var observed := _shift(emitted, latency_samples)
	var est: Primitive = load("res://primitives/prim_temporal_offset_estimate.gd").new()
	est.params = { "dt_ms": dt_ms, "max_lag": 16 }
	var r_a := est.evaluate({ "emitted": emitted, "observed": observed })
	ok = _check("(A) cross-correlation recovers injected latency (%d samples = %.0f ms; got %.1f ms)"
			% [latency_samples, latency_samples * dt_ms, float(r_a["timing_offset_ms"])],
		bool(r_a["valid"]) and abs(float(r_a["timing_offset_ms"]) - latency_samples * dt_ms) < 0.5 * dt_ms) and ok

	var r_zero := est.evaluate({ "emitted": emitted, "observed": emitted })
	ok = _check("(A) zero-shift pair reads ~0 ms latency (got %.1f ms)" % float(r_zero["timing_offset_ms"]),
		bool(r_zero["valid"]) and abs(float(r_zero["timing_offset_ms"])) < 0.5 * dt_ms) and ok

	# Absent / ragged input must no-op gracefully (C ideal) — never crash.
	var r_absent := est.evaluate({})
	ok = _check("(A) absent input is a graceful no-op (valid=false, 0 ms)",
		bool(r_absent["valid"]) == false and float(r_absent["timing_offset_ms"]) == 0.0) and ok
	var r_ragged := est.evaluate({ "emitted": [1.0, 0.0, 1.0], "observed": "not-an-array" })
	ok = _check("(A) ragged/mistyped input is a graceful no-op (valid=false)",
		bool(r_ragged["valid"]) == false) and ok

	# ── (B) the correction RECORD is plain DATA + recovers color/intensity skew ───────────────
	# Commanded RGB vs observed RGB (a per-light color cast + a dim intensity). color_offset =
	# observed - commanded (added back to pre-correct); intensity_gain = commanded/observed.
	est.params = { "dt_ms": dt_ms, "max_lag": 16 }
	var r_b := est.evaluate({
		"emitted": emitted, "observed": observed,
		"commanded_rgb": [0.8, 0.6, 0.4], "observed_rgb": [0.6, 0.6, 0.5],
		"method": "random", "addr": 3,
	})
	var rec = r_b["correction"]
	ok = _check("(B) correction record carries the three declared fields",
		typeof(rec) == TYPE_DICTIONARY and rec.has("timing_offset_ms")
		and rec.has("color_offset") and rec.has("intensity_gain")) and ok
	ok = _check("(B) correction record JSON-round-trips (portable DATA)",
		typeof(JSON.parse_string(JSON.stringify(rec))) == TYPE_DICTIONARY) and ok
	var co = rec["color_offset"]
	ok = _check("(B) color_offset = observed - commanded per channel (R %.2f, G %.2f, B %.2f)"
			% [float(co[0]), float(co[1]), float(co[2])],
		abs(float(co[0]) - (0.6 - 0.8)) < 1e-6 and abs(float(co[1]) - (0.6 - 0.6)) < 1e-6
		and abs(float(co[2]) - (0.5 - 0.4)) < 1e-6) and ok
	ok = _check("(B) intensity_gain restores commanded luminance (gain %.3f > 1 for a dimmed light)"
			% float(rec["intensity_gain"]),
		float(rec["intensity_gain"]) > 1.0) and ok
	ok = _check("(B) the control-METHOD + addr ride through onto the record (item-F taxonomy)",
		str(rec.get("method", "")) == "random" and int(rec.get("addr", -1)) == 3) and ok

	# ── (C) the arrangement wires up over the SAME projection loop + a device.set_led emit ────
	DeviceActions.register_device_ops(WorldActions)  # a room boots its device.* op family
	var arr := _load_arr()
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var n_lights := (out["pattern"]["pattern"]["points"] as Array).size()
	ok = _check("(C) CalibrationPattern emits the light grid (>= 12 fiducials = commanded lights)",
		typeof(out["pattern"]["pattern"]) == TYPE_DICTIONARY and n_lights >= 12) and ok
	# Before correction the big random offset legitimately pushes an edge light off the camera frame
	# (the solver only needs >= 4 valid points; a per-light blackout never crashes it). The MEANINGFUL
	# claim is that CALIBRATION brings every light into view: after the loop converges, all are observed.
	ok = _check("(C) most lights are observed even before correction (>= n-2, a blackout is graceful)",
		int(out["observe"]["valid_count"]) >= n_lights - 2) and ok
	var conv := _run_loop(_load_arr(), MAX_ITERS, 0.0)
	ok = _check("(C) after calibration converges, the camera observes EVERY commanded light (%d/%d)"
			% [int(conv["final_valid"]), n_lights],
		int(conv["final_valid"]) == n_lights) and ok
	ok = _check("(C) the device.set_led emit step returns a receipt (the actuator half is wired)",
		typeof(out.get("emit")) == TYPE_DICTIONARY
		and typeof(out["emit"].get("result")) == TYPE_DICTIONARY
		and str(out["emit"]["result"].get("op", "")) == "device.set_led"
		and bool(out["emit"]["result"].get("ok", false))) and ok
	var err0 := float(out["calib"]["error"])
	ok = _check("(C) the initial random per-light offset is REAL: mean error %.2f px > 15" % err0, err0 > 15.0) and ok

	# ── (D) the loop REDUCES the measured offset (prim_compare_diff oracle) ────────────────────
	var run := _run_loop(_load_arr(), MAX_ITERS, 0.0)
	var errors: Array = run["errors"]
	print("    offset descent (gain 0.7): ", _fmt(errors))
	ok = _check("(D) prim_compare_diff scores the offset shrinking to ~0 over iterations",
		errors.size() >= 4 and _compare_l2(float(errors[3]), 0.0) < _compare_l2(float(errors[0]), 0.0)) and ok
	ok = _check("(D) offset strictly decreases over the first 3 corrections",
		errors.size() >= 4 and float(errors[1]) < float(errors[0])
		and float(errors[2]) < float(errors[1]) and float(errors[3]) < float(errors[2])) and ok
	ok = _check("(D) converges under %.1f px within %d iters (final %.3f px)"
			% [THRESHOLD, MAX_ITERS, float(errors[errors.size() - 1])], bool(run["converged"])) and ok

	# ── (E) LIVE DRIFT: a changing offset, damped loop must track it DOWN ──────────────────────
	# Each frame we nudge the target_rect (a slow physical drift of where the light actually aims);
	# the damped loop (gain 0.7) must keep the tracked error bounded + trending down, not diverge.
	var drift := _run_drift(_load_arr(), 16, 0.005)
	var derr: Array = drift["errors"]
	print("    live-drift tracking (gain 0.7, drift/frame 0.005 uv): ", _fmt(derr))
	var tail_max := 0.0
	for i in range(derr.size() - 5, derr.size()):
		tail_max = max(tail_max, float(derr[i]))
	ok = _check("(E) damped loop TRACKS a live drift: settled tail error stays bounded (%.3f px < 6)" % tail_max,
		tail_max < 6.0) and ok
	ok = _check("(E) tracked error is far below the untracked drift (loop is actually correcting)",
		float(derr[derr.size() - 1]) < 0.5 * float(drift["untracked_final"])) and ok

	# ── (F) the control-method taxonomy: a "random" big-offset channel still converges ─────────
	var arr_rand := _load_arr()
	# A "random" channel: crank the physical mounting offset (target_rect shifted hard) + tag method.
	_params(arr_rand, "observe")["target_rect"] = [0.42, 0.42, 0.86, 0.86]
	_params(arr_rand, "observe")["method"] = "random"
	var run_rand := _run_loop(arr_rand, MAX_ITERS, 0.0)
	var e_rand: Array = run_rand["errors"]
	print("    random-channel convergence: ", _fmt(e_rand))
	ok = _check("(F) a 'random' channel with a big offset (%.1f px) still converges (loop SOLVES it, final %.3f px)"
			% [float(e_rand[0]), float(e_rand[e_rand.size() - 1])], bool(run_rand["converged"])) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# ── the loop driver: evaluate -> copy calib.warp into map.matrix -> hotload -> repeat ────────
# Byte-for-byte the projection loop's data-driven feedback edge (headless_projection_test._run_loop):
# the graph stays pure dataflow; the driver commits the feedback by REWRITING NODE DATA (diff-hotload).
func _run_loop(arr: Dictionary, iters: int, _drift: float) -> Dictionary:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var errors := []
	var converged := false
	var final_valid := 0
	rt.load_arrangement(arr)
	for i in iters:
		var out := rt.evaluate()
		var err := float(out["calib"]["error"])
		errors.append(err)
		final_valid = int(out["observe"]["valid_count"])
		if bool(out["calib"]["converged"]):
			converged = true
			break
		_params(arr, "map")["matrix"] = out["calib"]["warp"]
		rt.load_arrangement(arr)
	rt.queue_free()
	return { "errors": errors, "converged": converged, "final_valid": final_valid }

# Live-drift driver: same loop, but each frame we ALSO nudge the physical target (target_rect) to
# simulate a light slowly drifting out of alignment; the damped loop must keep chasing it. Also runs
# an UNTRACKED baseline (identity map held) to prove the tracking is what keeps the error small.
func _run_drift(arr: Dictionary, iters: int, drift_per_frame: float) -> Dictionary:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var errors := []
	rt.load_arrangement(arr)
	var base_rect: Array = (_params(arr, "observe").get("target_rect", [0.25, 0.25, 0.75, 0.75])).duplicate()
	for i in iters:
		# Advance the physical drift BEFORE observing (the light moved since last correction).
		var d := drift_per_frame * float(i)
		_params(arr, "observe")["target_rect"] = [base_rect[0] + d, base_rect[1] + d, base_rect[2] + d, base_rect[3] + d]
		rt.load_arrangement(arr)
		var out := rt.evaluate()
		errors.append(float(out["calib"]["error"]))
		_params(arr, "map")["matrix"] = out["calib"]["warp"]
		rt.load_arrangement(arr)
	# Untracked baseline: hold identity, let the same drift accumulate — the error a NON-calibrating rig sees.
	var arr_u := _load_arr()
	var rt_u := GraphRuntime.new()
	get_root().add_child(rt_u)
	var base_u: Array = (_params(arr_u, "observe").get("target_rect", [0.25, 0.25, 0.75, 0.75])).duplicate()
	var d_u := drift_per_frame * float(iters - 1)
	_params(arr_u, "observe")["target_rect"] = [base_u[0] + d_u, base_u[1] + d_u, base_u[2] + d_u, base_u[3] + d_u]
	rt_u.load_arrangement(arr_u)
	var untracked := float(rt_u.evaluate()["calib"]["error"])
	rt_u.queue_free()
	rt.queue_free()
	return { "errors": errors, "untracked_final": untracked }

# prim_compare_diff as the convergence oracle: score the scalar offset against the target (0.0).
func _compare_l2(candidate: float, reference: float) -> float:
	var cd: Primitive = PrimCompareDiff.new()
	cd.params = { "metric": "l2" }
	return float(cd.evaluate({ "candidate": candidate, "reference": reference })["d"])

func _load_arr() -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(ARRANGEMENT))
	assert(typeof(data) == TYPE_DICTIONARY)
	return data

func _params(arr: Dictionary, id: String) -> Dictionary:
	for n in arr.get("nodes", []):
		if String(n.get("id")) == id:
			if typeof(n.get("params")) != TYPE_DICTIONARY:
				n["params"] = {}
			return n["params"]
	push_error("no node " + id)
	return {}

# A single aperiodic FLASH burst: `n` samples, a smooth triangular pulse of width `w` starting at
# `start`, 0 elsewhere. Aperiodic so the cross-correlation peak is unique (latency is identifiable).
func _burst(n: int, start: int, w: int) -> Array:
	var a := []
	for i in n:
		var v := 0.0
		if i >= start and i < start + w:
			# Triangular ramp up then down across the width — a distinctive, non-flat shape.
			var t := float(i - start) / float(w)
			v = 1.0 - abs(2.0 * t - 1.0)
		a.append(v)
	return a

# Shift an array RIGHT by k samples (zero-fill the head) — the observed timeline lags the emitted one.
func _shift(a: Array, k: int) -> Array:
	var out := []
	for i in a.size():
		out.append(a[i - k] if i - k >= 0 else 0.0)
	return out

func _fmt(errors: Array) -> String:
	var parts := []
	for e in errors:
		parts.append("%.3f" % float(e))
	return " -> ".join(parts)

func _check(label: String, passed: bool) -> bool:
	print(("  PASS  " if passed else "  FAIL  ") + label)
	return passed
