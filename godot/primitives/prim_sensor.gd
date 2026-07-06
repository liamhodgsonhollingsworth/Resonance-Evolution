class_name PrimSensor
extends Primitive
## The SENSOR SOURCE node (Dreams-arc Slice 4) — a source sibling of Const and Input, but for a
## SENSED CONTINUOUS SIGNAL. Where Const emits a fixed params.value and Input emits a per-frame lookup
## from the runtime's abstract input FRAME, a Sensor emits a scalar it SENSES from the world for a
## bound target: how NEAR the target is, how much VOLUME/magnitude its sensed vector carries, or a
## continuous external band (a camera brightness, an audio band) injected through the SAME per-frame
## portability seam Input reads (GraphRuntime.set_input_frame / get_input_frame). It is the continuous
## READ-side companion to Input's discrete read: the same "when the sensed value crosses X, do Y"
## arrangement runs on any host because a Sensor BINDS TO NOTHING concrete — the host's injector decides
## what a camera/audio band resolves to, exactly like Input.
##
## NODE-NOT-EDIT: this is a NEW source primitive that WRAPS PrimContext's existing proximity math. It
## does not re-implement distance/vector math and it does not touch any existing primitive — the
## proximity/magnitude computation is REUSED by instantiating a PrimContext and calling its already-
## shipped _as_vec + _vec_sq_distance helpers (the exact math the proximity Context handler gates on).
## A Sensor is "the proximity gate's DISTANCE, surfaced as a scalar" instead of "near/not-near as a
## boolean" — same math, read as a continuous value.
##
## params:
##   mode      — "proximity" | "volume" | "frame"  (default "proximity")
##                 proximity: emit the Euclidean DISTANCE between the two implicit position inputs
##                            "pos_a"/"pos_b" (reusing Context's _vec_sq_distance, sqrt'd to a real
##                            distance). This is the scalar the proximity Context handler thresholds
##                            against `radius` — a Sensor exposes it directly so an arrangement can
##                            compare/select on HOW near, not just near-or-not.
##                 volume:    emit the MAGNITUDE (Euclidean length) of the single implicit vector input
##                            "vec" — the sensed vector's size (an audio band's amplitude vector, a
##                            motion vector). Reuses the SAME _vec_sq_distance machinery (magnitude =
##                            distance from the origin), so no new math.
##                 frame:     emit a continuous external signal read from the runtime's per-frame input
##                            FRAME by params.sensor_id (the camera/audio-band injection path) — the
##                            EXACT seam PrimInput reads, so a Sensor and an Input share one injector.
##   target_id — (proximity/volume) an OPTIONAL label for the sensed target; carried for provenance and
##               for a future host that injects a named target's live position. Not load-bearing for the
##               math (the positions/vector arrive on the implicit ports); default "".
##   sensor_id — (frame mode) the abstract key to look up in the current input frame. Default "".
##   default   — (frame mode) the value emitted when the frame lacks sensor_id (frame absent or key
##               absent). Default 0 — an un-driven Sensor is a harmless constant, the same "unknown =
##               declared no-op" portability posture Input has, here on the sensed read side.

# REUSE, not re-implement: a throwaway PrimContext supplies the shipped proximity math (_as_vec +
# _vec_sq_distance). Instantiated lazily and kept for the node's lifetime so we don't re-new it every
# evaluate(); freed with the node (add_child'd so the tree owns it). It carries no per-instance state
# we depend on — we only call its pure vector helpers.
var _ctx: PrimContext = null

func _init() -> void:
	prim_type = "Sensor"

func _mode() -> String:
	# str() (not String()) so a numeric/Variant params.mode coerces safely; String() throws on a non-string.
	return str(params.get("mode", "proximity"))

## The implicit inputs depend on the mode: "proximity" reads two positions "pos_a"/"pos_b" (exactly the
## proximity Context handler's implicit ports); "volume" reads one vector "vec"; "frame" reads nothing
## off wires (the value arrives through the runtime's input frame). Handler-implicit names mirror
## PrimContext's reserved position-port names so a Sensor wires into the same position sources.
func input_ports() -> Array:
	match _mode():
		"volume":
			return [{ "name": "vec", "type": "vector" }]
		"frame":
			return []
		_:
			return [
				{ "name": "pos_a", "type": "vector" },
				{ "name": "pos_b", "type": "vector" },
			]

func output_ports() -> Array:
	return [{ "name": "value", "type": "number" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	match _mode():
		"frame":
			return { "value": _sense_frame() }
		"volume":
			return { "value": _sense_volume(inputs) }
		_:
			return { "value": _sense_proximity(inputs) }

# --- proximity: the distance the proximity Context handler thresholds, surfaced as a scalar ----------

## Euclidean distance between the two implicit position inputs, REUSING PrimContext's _as_vec +
## _vec_sq_distance (no re-implemented math). A missing / unconnected position (null) means "no
## reading" -> 0.0, the same fail-safe direction Context's proximity uses (a missing endpoint is not
## an interaction). sqrt of the squared distance gives the real, comparable distance a downstream
## Compare/Select thresholds against — this IS the proximity handler's inner value, read continuously.
func _sense_proximity(inputs: Dictionary) -> float:
	var ctx := _context()
	var a: Array = ctx._as_vec(inputs.get("pos_a"))
	var b: Array = ctx._as_vec(inputs.get("pos_b"))
	if a.is_empty() or b.is_empty():
		return 0.0
	return sqrt(ctx._vec_sq_distance(a, b))

# --- volume: the sensed vector's magnitude, reusing the same distance machinery ----------------------

## Magnitude (Euclidean length) of the single implicit "vec" input. Magnitude is exactly the distance
## from the origin, so we REUSE _vec_sq_distance against an empty (origin) vector rather than writing a
## second length routine — same math as proximity, one endpoint pinned at 0. A missing vector -> 0.0.
func _sense_volume(inputs: Dictionary) -> float:
	var ctx := _context()
	var v: Array = ctx._as_vec(inputs.get("vec"))
	if v.is_empty():
		return 0.0
	return sqrt(ctx._vec_sq_distance(v, []))

# --- frame: a continuous external band read off the runtime's input frame (the Input seam) -----------

## Read the sensed signal from the runtime's per-frame input FRAME by params.sensor_id — the EXACT seam
## PrimInput reads (GraphRuntime.get_input_frame). This is how a camera-brightness / audio-band frame
## drives a Sensor: a host injector deposits { "<sensor_id>": <value> } via set_input_frame and this
## node reads its own key out. A frame that lacks sensor_id (or no frame / no runtime) falls back to
## params.default, so the node is always defined. Mirrors PrimInput.evaluate() exactly (str() coercion,
## get_input_frame off the parent runtime) so the two sources share one injection path.
func _sense_frame():
	var sensor_id := str(params.get("sensor_id", ""))
	var fallback = params.get("default", 0)
	var rt := get_parent()
	if rt != null and rt.has_method("get_input_frame"):
		var frame: Dictionary = rt.call("get_input_frame")
		if frame.has(sensor_id):
			return frame[sensor_id]
	return fallback

## The reused PrimContext math delegate, created lazily and parented so the tree owns its lifetime.
func _context() -> PrimContext:
	if _ctx == null:
		_ctx = PrimContext.new()
		add_child(_ctx)
	return _ctx

## Impure: proximity/volume depend on wired inputs (fine), but frame mode depends on the runtime's
## per-frame input frame — not just params — exactly like Input. So a Sensor is NOT safe to memoize
## (the same reasoning PrimInput.is_cacheable() gives). Const, the pure source, opts in; Sensor does not.
func is_cacheable() -> bool:
	return false
