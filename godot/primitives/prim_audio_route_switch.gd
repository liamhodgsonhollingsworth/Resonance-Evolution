class_name PrimAudioRouteSwitch
extends Primitive
## The DEMO|LIVE PERFORMANCE TOGGLE (visi-sonor light-show Slice 2B, item 7). It chooses which frame
## SOURCE feeds a downstream effect: the SYNTHETIC demo loop (prim_demo_audio_loop) or the REAL analyzer
## (the runtime's set_input_frame seam that prim_audio_source -> prim_spectrum -> prim_spectrum_bands fill).
## It emits the chosen frame on a wire, so every downstream prim_feature_pick / effect reads the selected
## source WITHOUT being rewired — flipping this one node re-sources the whole graph.
##
## WHY A TOGGLE (the performance cost): an effects MENU may show many tiles at once; running EVERY tile off
## the LIVE analyzer is expensive (each tile re-reacts every frame). The demo mode lets idle tiles preview
## against the cheap synthetic loop and only the SELECTED / focused tile run live — per-tile or global. This
## is the exact demo-vs-live pattern slice5's hold-B already proved (synthetic oscillator vs real feed); this
## node makes that switch a first-class DATA node so it composes into any arrangement (T ideal).
##
## THE SEAM: it is source-agnostic — it never analyzes audio itself. `demo_frame` is wired from
## prim_demo_audio_loop; `live_frame` from the band chain (or, when unwired, it reads the runtime's
## set_input_frame seam directly, so a host that injects the live analyzer frame there needs no extra wire).
## Both branches emit the SAME frame-dict shape, so demo and live are interchangeable by construction.
##
## params:
##   mode   "demo" (default) | "live" — which source to emit. (A bound feature can drive this per-tile via a
##          wired `mode` input; the param is the static default.)
##
## inputs:
##   demo_frame  the synthetic frame dict from prim_demo_audio_loop (absent in live mode = fine).
##   live_frame  the real analyzer frame dict (absent => falls back to the runtime set_input_frame seam).
##   mode        OPTIONAL per-tile override of params.mode ("demo"/"live") — so one switch node can be driven
##               live by a menu selection wire without editing params.
##
## outputs:
##   frame   the chosen frame dict (plain DATA — T ideal). Absent source => an empty dict (declared no-op).
##   source  "demo" | "live" — which branch was emitted (a label for downstream / debugging).

func _init() -> void:
	prim_type = "AudioRouteSwitch"

func input_ports() -> Array:
	return [
		{ "name": "demo_frame", "type": "any" },
		{ "name": "live_frame", "type": "any" },
		{ "name": "mode", "type": "any" },
	]

func output_ports() -> Array:
	return [
		{ "name": "frame", "type": "any" },
		{ "name": "source", "type": "any" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	# A wired `mode` overrides the param (per-tile drive); else the param; default "demo".
	var mode_in = inputs.get("mode")
	var mode := str(mode_in) if mode_in != null and str(mode_in) != "" else str(params.get("mode", "demo"))

	if mode == "live":
		var live := _as_dict(inputs.get("live_frame"))
		# When no live_frame is wired, read the runtime's set_input_frame seam directly — the host that
		# fills the real analyzer frame there needs no extra wire. Absent everything => empty (no-op).
		if live.is_empty():
			var rt := get_parent()
			if rt != null and rt.has_method("get_input_frame"):
				var f = rt.call("get_input_frame")
				if f is Dictionary:
					live = (f as Dictionary).duplicate(true)
		return { "frame": live, "source": "live" }

	# demo (default): emit the synthetic loop's frame. Absent => empty (declared no-op, C ideal).
	var demo := _as_dict(inputs.get("demo_frame"))
	return { "frame": demo, "source": "demo" }

# --- helpers ---------------------------------------------------------------------------------------

## Coerce a wire value to a frame DICT; anything non-dict (null/unwired) => an empty dict (C ideal — a
## missing source is a declared no-op, never a crash). Duplicated so the store/upstream is never aliased.
func _as_dict(v) -> Dictionary:
	if v is Dictionary:
		return (v as Dictionary).duplicate(true)
	return {}

## Impure: the output depends on the wired frame sources (and optionally the runtime seam), not just params.
func is_cacheable() -> bool:
	return false
