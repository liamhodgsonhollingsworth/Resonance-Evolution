class_name PrimParamBind
extends Primitive
## THE UNIVERSAL BINDING NODE (visi-sonor Slice 1B, item 8 — the highest-leverage node in the arc).
## It takes ONE raw feature value and pushes it through the full binding pipeline that EVERY reactive
## target needs, then emits the bound value:
##
##   x  ->  [1 NORMALIZE]  ->  [2 RESPONSE CURVE]  ->  [3 ATTACK/RELEASE ENVELOPE]  ->  [4 GATE]  ->  [5 REMAP]  ->  value
##
## The load-bearing insight: a LIGHT's brightness and a visual BAR's height are BOTH "a bound feature".
## Build the binding ONCE here and lighting (items 2/3/6) and screen effects (item 7) share identical
## wiring — you point a ParamBind at a feature and at a target range, and the SAME node drives an LED
## channel, a bar height, a strobe Hz, a particle emit-rate. That is why it unifies items 2/3/6/7 into
## one operation (the plan's "makes items 2/3/6/7 the SAME binding operation").
##
## Composition-over-duplication (R ideal): the response-curve stage REUSES PrimResponseCurve.shape_value
## and the envelope stage is the same one-pole asymmetric smoother as PrimEnvelopeFollower — the SAME
## math, applied in-line, not re-implemented. (A caller who wants the stages as separate wire-able nodes
## can instead chain ResponseCurve + EnvelopeFollower explicitly; ParamBind is the batteries-included
## single node for the common case.) Output is a plain float (T). Stateful (envelope) so NOT cacheable.
##
## params (every stage is optional; an omitted stage is an identity pass-through = declared no-op, C):
##   [1] in_min, in_max        normalize x from [in_min,in_max] to 0..1, CLAMPED. (default 0..1)
##   [2] curve_shape, curve_k  response curve over the 0..1 (default "linear" = identity). See ResponseCurve.
##   [3] attack, release       envelope coeffs 0..1 (default 1.0 = no smoothing / instant). Asymmetric.
##   [4] gate_min, gate_max     if the NORMALIZED level is < gate_min or > gate_max, force output to
##                              out_min (a silence floor / ceiling reject). (default gate_min=0 gate_max=1
##                              => no gating.)
##   [5] out_min, out_max      remap the shaped 0..1 into the target range. (default 0..1)
##
## input:   x — the raw feature (as_num; an unconnected wire = 0.0 -> a defined floor, never a crash).
## output:  value — the fully-bound target value (float).

var _held: float = 0.0
var _seeded: bool = false

const ResponseCurveRef := preload("res://primitives/prim_response_curve.gd")

func _init() -> void:
	prim_type = "ParamBind"

func input_ports() -> Array:
	return [{ "name": "x", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "value", "type": "number" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var x := as_num(inputs.get("x"))

	# [1] NORMALIZE to 0..1, clamped. Degenerate range (in_max<=in_min) -> 0 to avoid div-by-zero.
	var in_min := float(params.get("in_min", 0.0))
	var in_max := float(params.get("in_max", 1.0))
	var n := 0.0
	if in_max > in_min:
		n = clamp((x - in_min) / (in_max - in_min), 0.0, 1.0)

	# [4-pre] GATE decision is on the NORMALIZED level (before curve/envelope) — a raw-loudness gate.
	var gate_min := float(params.get("gate_min", 0.0))
	var gate_max := float(params.get("gate_max", 1.0))
	var gated := n < gate_min or n > gate_max

	# [2] RESPONSE CURVE over the normalized value (reuses the shared shaping math — R ideal).
	var curve_k := float(params.get("curve_k", 2.0))
	if curve_k <= 0.0:
		curve_k = 1.0
	var shaped := ResponseCurveRef.shape_value(str(params.get("curve_shape", "linear")), n, curve_k)

	# [3] ATTACK/RELEASE ENVELOPE (same asymmetric one-pole as PrimEnvelopeFollower). attack=release=1.0
	# (the default) is an instant pass-through, so a bind with no smoothing is deterministic per-frame.
	var attack: float = clamp(float(params.get("attack", 1.0)), 0.0, 1.0)
	var release: float = clamp(float(params.get("release", 1.0)), 0.0, 1.0)
	if not _seeded:
		_held = shaped
		_seeded = true
	else:
		var coeff := attack if shaped >= _held else release
		_held += coeff * (shaped - _held)
	var enveloped := _held

	# [5] REMAP the shaped/enveloped 0..1 into the target range.
	var out_min := float(params.get("out_min", 0.0))
	var out_max := float(params.get("out_max", 1.0))
	if gated:
		# Gated-out: collapse to the silence floor (out_min) and reset the envelope memory so the next
		# ungated onset attacks cleanly from the floor rather than easing down from a stale level.
		_held = 0.0
		return { "value": out_min }
	var value := out_min + enveloped * (out_max - out_min)
	return { "value": value }

## Restore envelope memory (symmetry with PrimState/PrimEnvelopeFollower for reproducible runs).
func reset_state() -> void:
	_held = 0.0
	_seeded = false

## Impure: the envelope stage carries state across frames. Never memoize.
func is_cacheable() -> bool:
	return false
