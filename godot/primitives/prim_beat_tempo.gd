class_name PrimBeatTempo
extends Primitive
## BEAT / TEMPO ESTIMATOR (visi-sonor light-show Slice 2A, item 7 beat family; feeds item-13
## ANTICIPATION). Given a stream of onset events (0/1 per frame, typically from prim_onset_detect),
## it estimates the tempo in BPM and the current PHASE within the beat (0..1). Phase is what lets
## downstream lighting PRE-EMPT a beat (a scene-cut cue can fire slightly AHEAD because the phase says
## the beat is imminent) rather than only reacting after the fact.
##
## METHOD (inter-onset-interval with EMA smoothing — simple, deterministic, headless-testable):
##   on each onset, measure the gap (frames) since the previous onset -> a period estimate;
##   EMA-smooth the period so a stray double-hit does not thrash the estimate;
##   BPM = 60 / (period_frames * dt_seconds); clamp to [min_bpm, max_bpm].
##   PHASE advances by dt/period each frame and wraps at 1.0; an onset re-syncs the phase to 0.
## No autocorrelation / FFT needed for the demo; a period tracker matches a steady click track and is
## the sib of the projection-calibration EMA (same "smooth a noisy running estimate" shape).
##
## params:
##   dt        seconds per frame (default 1/60). BPM is period_frames -> seconds via this.
##   min_bpm   clamp floor (default 40).
##   max_bpm   clamp ceiling (default 240).
##   period_ema EMA coefficient for the period estimate (default 0.3).
##   onset_threshold  a driving `onset` >= this counts as a beat (default 0.5).
##
## input:  onset — 0/1 onset stream (as_num; unconnected = 0 -> phase free-runs on the last estimate, C).
## output: bpm    — estimated beats-per-minute (0 until two onsets seen).
##         phase  — 0..1 position within the current beat.
##         beat   — 1.0 on the frame an onset re-synced the phase, else 0.0 (a cleaned beat pulse).

var _frames_since_onset: int = 0
var _period_frames: float = 0.0     # 0 = not yet estimated
var _phase: float = 0.0
var _seen_first: bool = false

func _init() -> void:
	prim_type = "BeatTempo"

func input_ports() -> Array:
	return [{ "name": "onset", "type": "number" }]

func output_ports() -> Array:
	return [
		{ "name": "bpm", "type": "number" },
		{ "name": "phase", "type": "number" },
		{ "name": "beat", "type": "number" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var dt := float(params.get("dt", 1.0 / 60.0))
	if dt <= 0.0:
		dt = 1.0 / 60.0
	var min_bpm := float(params.get("min_bpm", 40.0))
	var max_bpm := float(params.get("max_bpm", 240.0))
	var period_ema: float = clamp(float(params.get("period_ema", 0.3)), 0.0, 1.0)
	var on_thr := float(params.get("onset_threshold", 0.5))

	var is_onset := as_num(inputs.get("onset")) >= on_thr
	var beat_pulse := 0.0

	_frames_since_onset += 1
	if is_onset:
		if _seen_first and _frames_since_onset > 0:
			# Inter-onset interval -> a period estimate, EMA-smoothed.
			var measured := float(_frames_since_onset)
			if _period_frames <= 0.0:
				_period_frames = measured
			else:
				_period_frames += period_ema * (measured - _period_frames)
		_seen_first = true
		_frames_since_onset = 0
		_phase = 0.0            # re-sync phase on a beat
		beat_pulse = 1.0
	else:
		# Free-run the phase on the current period estimate.
		if _period_frames > 0.0:
			_phase += 1.0 / _period_frames
			while _phase >= 1.0:
				_phase -= 1.0

	var bpm := 0.0
	if _period_frames > 0.0:
		bpm = clamp(60.0 / (_period_frames * dt), min_bpm, max_bpm)

	return { "bpm": bpm, "phase": clamp(_phase, 0.0, 1.0), "beat": beat_pulse }

func reset_state() -> void:
	_frames_since_onset = 0
	_period_frames = 0.0
	_phase = 0.0
	_seen_first = false

## Impure: carries the running period + phase across frames. Never memoize.
func is_cacheable() -> bool:
	return false
