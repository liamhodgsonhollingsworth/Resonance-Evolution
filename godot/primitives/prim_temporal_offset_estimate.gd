class_name PrimTemporalOffsetEstimate
extends Primitive
## The TEMPORAL analog of the projection arc's spatial homography step, for LIGHT CALIBRATION
## (visi-sonor Wave 3B, spec item 5). The projection loop measures a SPATIAL offset — "I emit a dot
## at X, the camera sees it at Y" — and prim_projection_calibration solves it. A commanded light also
## has a TEMPORAL offset: over an IR / bluetooth / cheap-networked channel, "set_led NOW" actually
## lands some milliseconds LATER, and by a different amount per fixture (the "random offset" the spec
## names). This node measures that latency the SAME way the spatial step measures position error —
## by comparing what was EMITTED to what was OBSERVED — only along the TIME axis via cross-correlation
## of the emitted-pulse timeline vs the observed-brightness timeline. It is purely additive (a new
## registered TYPE, N ideal); it edits no existing primitive.
##
## It ALSO packs the per-light CORRECTION RECORD the transports apply transparently: a plain DATA dict
## { timing_offset_ms, color_offset, intensity_gain, method, addr }. `timing_offset_ms` is the measured
## latency; `color_offset` is the per-channel cast (observed - commanded) to add back; `intensity_gain`
## restores commanded luminance (commanded / observed). A transport rides these under every device.*
## command (via prim_param_bind where present, else this plain field) — so a calibrated offset is
## invisible to the arrangement above. The control-METHOD taxonomy (ir / bluetooth / networked_precise
## / random) is carried as metadata and echoed onto the record; the loop SOLVES the random offset and,
## re-run each frame at low rate with a damped gain, TRACKS its drift.
##
## Everything is a pure function of the inputs (T ideal), so it is deterministic + memoizable, and any
## absent / ragged / mistyped input is a graceful NO-OP (valid=false, zero offsets) — never a crash
## (C ideal): a host with no camera-brightness timeline simply gets valid=false and the loop rides the
## identity correction.
##
## params:
##   dt_ms    — sampling period of the timelines in milliseconds (default 10.0 = 100 Hz). Latency in ms
##              = best_lag_samples * dt_ms.
##   max_lag  — the widest lag (in samples) the cross-correlation searches, each direction (default 32).
##              A physical channel's latency is bounded, so a bounded search keeps this O(n * max_lag).
##   method   — the control-method tag (ir / bluetooth / networked_precise / random), echoed onto the
##              record; a per-node metadata field, not behaviour (default "networked_precise").
##
## inputs:
##   emitted        — Array<number>: the commanded brightness/pulse timeline (what we told the light).
##   observed       — Array<number>: the camera-observed brightness timeline of THAT light.
##   commanded_rgb  — optional [r,g,b]: the commanded color (for the color/intensity skew).
##   observed_rgb   — optional [r,g,b]: the camera-observed color.
##   method         — optional String: overrides params.method (a wire wins, so the taxonomy can be data).
##   addr           — optional int: the light's address, echoed onto the record.
##
## outputs:
##   timing_offset_ms — measured latency in ms (0.0 when valid=false).
##   correction       — { timing_offset_ms, color_offset:[r,g,b], intensity_gain, method, addr } DATA.
##   correlation      — the peak normalized cross-correlation (0..1; a confidence, 0.0 when invalid).
##   valid            — bool: false when timelines were absent / too short / ragged (a graceful no-op).

func _init() -> void:
	prim_type = "TemporalOffsetEstimate"

func input_ports() -> Array:
	return [
		{ "name": "emitted", "type": "array" },
		{ "name": "observed", "type": "array" },
		{ "name": "commanded_rgb", "type": "array" },
		{ "name": "observed_rgb", "type": "array" },
		{ "name": "method", "type": "string" },
		{ "name": "addr", "type": "number" },
	]

func output_ports() -> Array:
	return [
		{ "name": "timing_offset_ms", "type": "number" },
		{ "name": "correction", "type": "any" },
		{ "name": "correlation", "type": "number" },
		{ "name": "valid", "type": "bool" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var dt_ms := float(params.get("dt_ms", 10.0))
	var max_lag := int(params.get("max_lag", 32))
	var method := str(inputs.get("method", params.get("method", "networked_precise")))
	var addr := int(Primitive.as_num(inputs.get("addr", 0)))

	var emitted = inputs.get("emitted")
	var observed = inputs.get("observed")

	var offset_ms := 0.0
	var corr := 0.0
	var valid := false
	# Latency needs BOTH timelines as equal-length numeric arrays of a workable length. Anything else
	# (absent, mistyped, ragged, too short) is a graceful no-op — the C ideal, never a crash.
	if emitted is Array and observed is Array \
			and (emitted as Array).size() == (observed as Array).size() \
			and (emitted as Array).size() >= 4:
		var res := _best_lag(emitted, observed, max_lag)
		offset_ms = float(res["lag"]) * dt_ms
		corr = float(res["corr"])
		valid = true

	# The color / intensity skew is INDEPENDENT of the timelines — a host may have only a color reading,
	# or only a latency reading, or both. Each degrades to a neutral correction on its own.
	var color_offset := [0.0, 0.0, 0.0]
	var intensity_gain := 1.0
	var cmd = inputs.get("commanded_rgb")
	var obs = inputs.get("observed_rgb")
	if cmd is Array and obs is Array and (cmd as Array).size() >= 3 and (obs as Array).size() >= 3:
		for i in 3:
			# color_offset = observed - commanded: what the camera saw minus what we asked for; a
			# transport ADDS this back (pre-distorts the command) so the light lands on the commanded color.
			color_offset[i] = Primitive.as_num(obs[i]) - Primitive.as_num(cmd[i])
		var cmd_lum := _luminance(cmd)
		var obs_lum := _luminance(obs)
		# intensity_gain restores commanded luminance: a light observed DIMMER than commanded needs a
		# gain > 1. Guard the divide (a black observation can't be gained up — clamp to a sane range).
		if obs_lum > 1e-4:
			intensity_gain = clampf(cmd_lum / obs_lum, 0.0, 16.0)

	var correction := {
		"timing_offset_ms": offset_ms,
		"color_offset": color_offset,
		"intensity_gain": intensity_gain,
		"method": method,
		"addr": addr,
	}
	return {
		"timing_offset_ms": offset_ms,
		"correction": correction,
		"correlation": corr,
		"valid": valid,
	}

# --- cross-correlation -----------------------------------------------------------------------------

## Find the integer lag `k` (observed lags emitted by k samples, |k| <= max_lag) that MAXIMIZES the
## zero-normalized cross-correlation between emitted and observed. Returns { lag, corr } where corr is
## the peak normalized correlation in [-1, 1] clamped to [0, 1] as a confidence. This is the temporal
## twin of fit_homography: emitted-vs-observed, along time instead of space.
##
## Deterministic + pure. The two series are mean-subtracted so a DC brightness offset (ambient light)
## does not bias the peak; each candidate lag scores the overlap region only (no wraparound).
func _best_lag(emitted: Array, observed: Array, max_lag: int) -> Dictionary:
	var n := emitted.size()
	var lag_cap := clampi(max_lag, 1, n - 1)
	var e_mean := _mean(emitted)
	var o_mean := _mean(observed)
	var best_lag := 0
	var best_score := -INF
	# k > 0 means observed is DELAYED relative to emitted (the physical latency case). We also scan
	# k < 0 for completeness/robustness (a mis-tagged pair), but a real latency lands at k >= 0.
	for k in range(-lag_cap, lag_cap + 1):
		var num := 0.0
		var e_energy := 0.0
		var o_energy := 0.0
		for i in n:
			var j := i - k        # observed[i] pairs with emitted[i - k] when observed lags by k
			if j < 0 or j >= n:
				continue
			var ev := Primitive.as_num(emitted[j]) - e_mean
			var ov := Primitive.as_num(observed[i]) - o_mean
			num += ev * ov
			e_energy += ev * ev
			o_energy += ov * ov
		var denom := sqrt(e_energy * o_energy)
		var score := (num / denom) if denom > 1e-9 else 0.0
		if score > best_score:
			best_score = score
			best_lag = k
	return { "lag": best_lag, "corr": clampf(best_score, 0.0, 1.0) }

func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += Primitive.as_num(v)
	return s / float(a.size())

## Rec. 709 luminance of an [r,g,b] triple (the standard perceptual weighting).
func _luminance(rgb: Array) -> float:
	return 0.2126 * Primitive.as_num(rgb[0]) + 0.7152 * Primitive.as_num(rgb[1]) + 0.0722 * Primitive.as_num(rgb[2])

## Pure: outputs are a deterministic function of the inputs + params, no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
