class_name PrimResponseCurve
extends Primitive
## The SHAPING CURVE primitive (visi-sonor Slice 1B) — a reusable, wire-able DATA transform that bends
## a normalized 0..1 value through a response curve BEFORE it drives a light/effect. A knob turned by a
## VJ ("make the bass feel punchier") is a curve, not engine code: swap params.shape in the DATA and the
## running graph re-shapes — no new node. It is the pure sibling of Math, specialised to perceptual
## shaping (the "response" a fader has under a fixture): expand the quiet end, compress the loud end, or
## push a soft-knee S so onsets pop while the noise floor stays dark.
##
## Renderer-/target-NEUTRAL by construction: input is a plain float, output is a plain float (T ideal).
## It presumes NOTHING about what the value drives — brightness, a bar height, a strobe rate, an LED
## channel — so the SAME curve node shapes a light and a screen effect identically (item 8).
##
## params:
##   shape  "linear" | "exp" | "log" | "s"   (default "linear")
##            linear — y = x                       (identity; the do-nothing knob)
##            exp    — y = x^k                      (gamma / expand the quiet end; k>1 darkens mids)
##            log    — y = x^(1/k)                  (compress the quiet end; k>1 lifts mids)
##            s      — smooth soft-knee S curve     (contrast around 0.5, steepness k)
##   k      <f> steepness / exponent               (default 2.0; k<=0 coerced to 1.0 = linear-ish)
##
## input:   x — the value to shape (any-numeric; coerced via as_num, so an unconnected wire = 0.0).
## output:  y — the shaped value. For x in 0..1 every shape stays in 0..1; x outside 0..1 is passed to
##              the math as-is (the caller normalises first — ParamBind does exactly this in-line).

func _init() -> void:
	prim_type = "ResponseCurve"

func input_ports() -> Array:
	return [{ "name": "x", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "y", "type": "number" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var x := as_num(inputs.get("x"))
	var k := float(params.get("k", 2.0))
	if k <= 0.0:
		k = 1.0
	return { "y": shape_value(str(params.get("shape", "linear")), x, k) }

## Pure math — the shaping is a deterministic function of (shape, x, k). Exposed STATIC so ParamBind
## (and any other node) applies the SAME curve in-line without instancing a node — one definition of the
## shaping, reused (R ideal). str()/match keeps an unknown shape a declared no-op = identity, never a crash (C).
static func shape_value(shape: String, x: float, k: float) -> float:
	match shape:
		"linear":
			return x
		"exp":
			# x^k for x>=0; expands the quiet end (k>1). Guard negative base (undefined for frac k).
			return pow(x, k) if x >= 0.0 else -pow(-x, k)
		"log":
			# inverse of exp — compresses the quiet end / lifts mids.
			return pow(x, 1.0 / k) if x >= 0.0 else -pow(-x, 1.0 / k)
		"s":
			# Smooth soft-knee S around 0.5. Uses smoothstep's cubic, sharpened by k via repeated
			# application (k as an integer-ish contrast count, min once) — stays in 0..1 for x in 0..1.
			var t: float = clamp(x, 0.0, 1.0)
			var passes := int(max(1.0, round(k)))
			for _i in range(passes):
				t = t * t * (3.0 - 2.0 * t)
			return t
	# Unknown shape = identity (declared no-op), the portability posture on the read side.
	return x

## Pure: y is a deterministic function of (x, shape, k), no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
