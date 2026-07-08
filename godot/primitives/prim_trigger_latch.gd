class_name PrimTriggerLatch
extends Primitive
## TRIGGER LATCH (visi-sonor light-show Slice 2A, item 7 beat family) — turns a DISCRETE one-frame
## onset (from prim_onset_detect / prim_beat_tempo) into a CONTINUOUS decaying envelope that a viz
## flash / a strobe / a light-brightness bind can actually USE. A raw onset is a single 1.0 frame;
## a flash needs "bright now, fade over the next ~200 ms". This node is that fade — the same "trigger
## -> usable envelope" shape a synth's AD envelope has.
##
##   env_t = max(onset_t, env_{t-1} * decay)     with an optional attack smoothing toward the target
##
## An onset SNAPS the envelope up (attack=1 = instant, the default) then it DECAYS geometrically by
## `decay` each frame until the next onset. attack<1 eases the rise for a softer look. The envelope is
## a plain 0..1 float on the wire (T), consumed identically by a light brightness or a viz flash alpha
## (item-8: one binding op serves lighting AND screen).
##
## params:
##   decay    per-frame multiplier 0..1 (default 0.85; larger = slower fade). env *= decay each frame.
##   attack   0..1 rise coefficient toward a new higher trigger (default 1.0 = instant snap).
##   onset_threshold  a driving `onset` >= this arms the latch (default 0.5).
##   hold     frames to HOLD at full before decay begins (default 0 = decay immediately).
##
## input:  onset — 0/1 (or continuous) trigger. A continuous value > env also lifts the envelope, so it
##                 doubles as a peak-follower. Unconnected = 0 -> the envelope just decays out (C).
## output: value — the 0..1 decaying envelope (plain float DATA, T).

var _env: float = 0.0
var _hold_left: int = 0

func _init() -> void:
	prim_type = "TriggerLatch"

func input_ports() -> Array:
	return [{ "name": "onset", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "value", "type": "number" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var decay: float = clamp(float(params.get("decay", 0.85)), 0.0, 1.0)
	var attack: float = clamp(float(params.get("attack", 1.0)), 0.0, 1.0)
	var on_thr := float(params.get("onset_threshold", 0.5))
	var hold := int(params.get("hold", 0))

	var trig := as_num(inputs.get("onset"))
	# The target this frame: a fired onset (or a continuous value above the current env) pulls the
	# envelope UP toward `trig` (clamped 0..1); otherwise there is no upward target.
	var target := clampf(trig, 0.0, 1.0)
	var fired := trig >= on_thr

	if fired or target > _env:
		# Rise toward the target with the attack coefficient (attack=1 -> instant).
		_env += attack * (target - _env)
		if fired:
			_hold_left = maxi(hold, 0)
	else:
		# Decay phase (respecting an optional hold-at-peak).
		if _hold_left > 0:
			_hold_left -= 1
		else:
			_env *= decay

	_env = clampf(_env, 0.0, 1.0)
	return { "value": _env }

func reset_state() -> void:
	_env = 0.0
	_hold_left = 0

## Impure: carries the envelope across frames. Never memoize.
func is_cacheable() -> bool:
	return false
