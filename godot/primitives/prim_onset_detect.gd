class_name PrimOnsetDetect
extends Primitive
## ONSET DETECTOR (visi-sonor light-show Slice 2A, item 7 beat family) — the node that turns a
## reactive feature stream into DISCRETE "a hit just happened" events (kick / snare / hihat / any
## transient). One node, band-parameterized: point params.feature at `bass` and it fires on kicks,
## at `treble` and it fires on hihats, at `energy` and it fires on full-mix onsets — the SAME node,
## a re-param never an engine edit (item-8 generality).
##
## METHOD (the standard energy-flux onset with an ADAPTIVE threshold — the load-bearing detail):
##   flux_t = max(0, level_t - level_{t-1})               (positive spectral/energy flux only)
##   thr_t  = EMA of past flux * sensitivity               (a running, self-adjusting threshold)
##   onset  = flux_t > thr_t AND flux_t > floor            (fire when the rise beats the running level)
## An ADAPTIVE threshold is what makes it robust: a sustained-loud passage has near-zero flux, so its
## EMA threshold rides UP with the running energy and the detector stops re-firing on held loudness —
## only a fresh rise fires. A fixed threshold would false-fire on any loud section; the EMA is the fix.
##
## It reads its driving value off the SAME band FRAME as FeaturePick (params.feature resolves through
## the shared PrimFeaturePick.FEATURE_KEYS table), OR off a wired `level` input (testability + explicit
## routing). Absent frame / unknown feature / unconnected wire = 0 -> a defined no-fire, never a crash (C).
##
## params:
##   feature       feature name to watch (default "energy"). Resolved via PrimFeaturePick's table, so a
##                 host's extra key works; "bass"/"treble"/... reproduce kick/hihat detectors from ONE node.
##   frame_key     optional literal frame key override (wins over feature).
##   sensitivity   multiplies the adaptive threshold (default 1.5; higher = fewer, stronger onsets).
##   threshold_ema EMA coefficient 0..1 for the running threshold (default 0.1 = slow adaptation).
##   floor         absolute minimum flux to ever count as an onset (default 0.02; rejects tiny jitter).
##
## input:  level — optional explicit driving value (overrides the frame feature when wired).
## output: onset — 1.0 on a detected onset this frame, else 0.0 (plain float DATA, T).
##         flux  — the positive flux this frame (for downstream latches / debugging).
##         threshold — the current adaptive threshold (so a tuner can see it).

const FeaturePickRef := preload("res://primitives/prim_feature_pick.gd")

var _prev_level: float = 0.0
var _thr_ema: float = 0.0
var _seeded: bool = false

func _init() -> void:
	prim_type = "OnsetDetect"

func input_ports() -> Array:
	return [{ "name": "level", "type": "number" }]

func output_ports() -> Array:
	return [
		{ "name": "onset", "type": "number" },
		{ "name": "flux", "type": "number" },
		{ "name": "threshold", "type": "number" },
	]

# Resolve the driving level: a wired `level` wins; else read params.feature off the runtime frame.
func _driving_level(inputs: Dictionary) -> float:
	var wired = inputs.get("level")
	if wired != null:
		return as_num(wired)
	var feature := str(params.get("feature", "energy"))
	var override := str(params.get("frame_key", ""))
	var key := FeaturePickRef.resolve_key(feature, override)
	var rt := get_parent()
	if rt != null and rt.has_method("get_input_frame"):
		var frame = rt.call("get_input_frame")
		if typeof(frame) == TYPE_DICTIONARY and (frame as Dictionary).has(key):
			return as_num((frame as Dictionary)[key])
	return 0.0

func evaluate(inputs: Dictionary) -> Dictionary:
	var level := _driving_level(inputs)
	if not _seeded:
		_prev_level = level
		_seeded = true
	var flux := maxf(0.0, level - _prev_level)
	_prev_level = level

	var sens := float(params.get("sensitivity", 1.5))
	var ema_c: float = clamp(float(params.get("threshold_ema", 0.1)), 0.0, 1.0)
	var flr := float(params.get("floor", 0.02))

	# Fire BEFORE folding this frame's flux into the threshold, so a spike is measured against the
	# threshold built from PAST flux (not partly against itself).
	var thr := _thr_ema * sens
	var is_onset := flux > thr and flux > flr

	# Adapt the running threshold toward the observed flux (EMA). Held-loud frames have ~0 flux, so the
	# threshold decays toward 0 during sustain — but the FIRST rise after quiet sees thr from the quiet
	# baseline (~0) and fires; the immediately-following sustained-loud frames have ~0 flux and do NOT.
	_thr_ema += ema_c * (flux - _thr_ema)

	return { "onset": 1.0 if is_onset else 0.0, "flux": flux, "threshold": thr }

func reset_state() -> void:
	_prev_level = 0.0
	_thr_ema = 0.0
	_seeded = false

## Impure: carries running flux + EMA state across frames. Never memoize.
func is_cacheable() -> bool:
	return false
