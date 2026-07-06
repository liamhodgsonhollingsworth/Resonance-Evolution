class_name PrimInput
extends Primitive
## The INPUT SOURCE node (Dreams-arc Slice 2) — the universal source sibling of Const. Where Const
## emits a fixed params.value, Input emits a value looked up EACH FRAME from the GraphRuntime's
## per-frame external-input FRAME (set via GraphRuntime.set_input_frame). It is the READ side of the
## one portability seam: an arrangement says "when action.interact is present, do X" in ABSTRACT
## vocabulary, and the per-host INJECTOR (a later slice) decides what "action.interact" resolves to on
## THIS host — a keyboard E, a controller face button, a swipe, a camera gesture, an audio band. The
## same arrangement therefore runs on a game host, a website, or a phone with only the injector swapped.
##
## input_id is ABSTRACT vocabulary ONLY — e.g. "action.interact", "ui.menu", "axis1", "axis2",
## "pointer", "signal". This node BINDS TO NOTHING concrete: no InputMap action, no device, no key.
## Per-host resolution is the injector's job (a later slice); this node only reads the frame the seam
## already deposited. That is what keeps it portable and node-not-edit: a new input is a new frame key
## a host chooses to populate, never a new primitive.
##
## params:
##   input_id — the abstract key to look up in the current input frame. Default "".
##   default  — the value emitted when the current frame lacks input_id (frame absent or key absent).
##              Default 0, so an un-driven Input is a harmless constant — the same "unknown = declared
##              no-op" portability posture WorldActions has on the write side, here on the read side.

func _init() -> void:
	prim_type = "Input"

func output_ports() -> Array:
	return [{ "name": "value", "type": "any" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	# Read the per-frame FRAME off the runtime this primitive is mounted in (its parent — every
	# primitive is add_child'd to its GraphRuntime in load_arrangement). We reach it through the
	# runtime's public accessor so we never touch the runtime's internals: a frame that lacks our
	# input_id (or no frame at all) falls back to params.default, so the node is always defined.
	# str() (not String()) so a numeric/Variant params.input_id coerces safely; String() throws on a non-string.
	var input_id := str(params.get("input_id", ""))
	var fallback = params.get("default", 0)
	var rt := get_parent()
	if rt != null and rt.has_method("get_input_frame"):
		var frame: Dictionary = rt.call("get_input_frame")
		if frame.has(input_id):
			return { "value": frame[input_id] }
	return { "value": fallback }

## Impure: the output depends on the runtime's per-frame input frame, not just params — so it must be
## re-read every evaluate() and is NOT safe to memoize. (Const, the pure sibling, opts in; Input does not.)
func is_cacheable() -> bool:
	return false
