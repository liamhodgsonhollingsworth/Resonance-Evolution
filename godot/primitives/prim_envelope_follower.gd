class_name PrimEnvelopeFollower
extends Primitive
## The ATTACK/RELEASE ENVELOPE FOLLOWER (visi-sonor Slice 1B) — the "fall" smoother every reactive
## light/effect needs so it snaps UP on an onset but eases DOWN afterwards, instead of flickering 1:1
## with a jittery band value. It is a one-pole low-pass with an ASYMMETRIC coefficient: a fast `attack`
## when the input RISES above the held level, a slow `release` when it FALLS below — the classic
## compressor/VU-meter envelope. This is what turns a raw band number into a musically-usable curve.
##
## Like PrimState it is the substrate's explicitly STATEFUL kind: it holds the last emitted level across
## evaluate()s (a one-sample memory). Everything else in the pipeline stays pure; the "memory" lives in
## this named, inspectable node — not the runtime floor (COMMUNICATION-ARCHITECTURE.md, the state law).
## Because it is stateful it is NOT cacheable.
##
## params:
##   attack   <f> 0..1 rise coefficient per evaluate   (default 0.5; 1.0 = instant, no smoothing)
##   release  <f> 0..1 fall coefficient per evaluate    (default 0.1; smaller = slower decay)
##            Both are per-FRAME blend factors: held += coeff * (target - held). Coeffs are clamped
##            to 0..1 so an out-of-range param is a declared no-op-shaped floor/ceil, never a crash (C).
##   init     <f> the level held before the first input (default 0.0).
##
## input:   x — the raw feature to follow (as_num; unconnected wire = 0.0).
## output:  y — the smoothed level. On the FIRST evaluate the follower ADOPTS the input (seeds at x) so
##              it does not have to climb from init on frame 1; thereafter it eases per attack/release.

var _held: float = 0.0
var _seeded: bool = false

func _init() -> void:
	prim_type = "EnvelopeFollower"

func input_ports() -> Array:
	return [{ "name": "x", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "y", "type": "number" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var target := as_num(inputs.get("x"))
	var attack: float = clamp(float(params.get("attack", 0.5)), 0.0, 1.0)
	var release: float = clamp(float(params.get("release", 0.1)), 0.0, 1.0)
	if not _seeded:
		# First observation: adopt the input directly (seed), so the demo starts at the real level.
		_held = float(params.get("init", target))
		if not params.has("init"):
			_held = target
		_seeded = true
		return { "y": _held }
	# Asymmetric one-pole: rise fast (attack), fall slow (release).
	var coeff := attack if target >= _held else release
	_held += coeff * (target - _held)
	return { "y": _held }

## Restore the initial level (symmetry with PrimState.reset_state — a reproducible run re-seeds).
func reset_state() -> void:
	_held = float(params.get("init", 0.0))
	_seeded = false

## Impure: the output depends on the held level (prior frames), not just this frame's input. Never memoize.
func is_cacheable() -> bool:
	return false
