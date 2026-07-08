class_name PrimVizFlash
extends Primitive
## FLASH (visi-sonor light-show Slice 2A, items 7+8) — a full-screen tint that a beat/onset TRIGGERS
## to full brightness then DECAYS away: the stage-strobe / camera-flash effect that punches on kicks.
## It is the screen-side twin of a strobe LIGHT — a light's brightness and a flash's alpha are the
## SAME bound envelope (item-8), so the same trigger drives both.
##
## RENDERER-NEUTRAL DATA (T): emits a single {kind:"fill", r,g,b,a} item in a draw-list dict, where `a`
## is the current decaying intensity. The shared PrimVizSpectrumBars.rasterize alpha-composites the
## fill over the background (R). No pixels held here.
##
## ITEM-8 REWIREABLE: the `trigger` arrives on a WIRE (a prim_onset_detect onset, a prim_trigger_latch
## envelope, a prim_beat_tempo beat, or any feature), so what fires the flash is a re-wire, never an
## engine edit.
##
## Internally it IS a trigger-latch on the tint alpha (same decay math as prim_trigger_latch): a
## trigger >= threshold snaps the intensity to (trigger, clamped); silent frames multiply it by decay.
## A tint COLOR can also come in on a `color` wire (e.g. from prim_freq_to_color) so the flash is warm
## on a bass hit and cool on a treble hit; absent color -> params.color (a defined default, C).
##
## params:
##   decay     per-frame multiplier 0..1 (default 0.8; larger = slower fade).
##   threshold trigger level that fires a flash (default 0.5).
##   color     [r,g,b] default tint (default [1,1,1] = white flash).
##   width,height  canvas size (default 128x128) — the fill covers it.
##
## inputs:  trigger — 0/1 (or continuous) fire signal. Unconnected = 0 -> the tint just decays out (C).
##          color   — optional {r,g,b} (or [r,g,b]) tint override (e.g. from freq_to_color).
## output:  out — the draw-list with the single decaying fill.

var _intensity: float = 0.0

func _init() -> void:
	prim_type = "VizFlash"

func input_ports() -> Array:
	return [
		{ "name": "trigger", "type": "number" },
		{ "name": "color", "type": "any" },
	]

func output_ports() -> Array:
	return [{ "name": "out", "type": "image" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var w := int(params.get("width", 128))
	var h := int(params.get("height", 128))
	var decay: float = clamp(float(params.get("decay", 0.8)), 0.0, 1.0)
	var thr := float(params.get("threshold", 0.5))

	var trig := as_num(inputs.get("trigger"))
	# A fired trigger (or any value above the current intensity) lifts the tint; else it decays.
	var target := clampf(trig, 0.0, 1.0)
	if trig >= thr or target > _intensity:
		_intensity = maxf(_intensity, target)
	else:
		_intensity *= decay
	_intensity = clampf(_intensity, 0.0, 1.0)

	var col := _tint_color(inputs)
	# Always emit the fill item (even at intensity 0) so the draw-list shape is stable and the test's
	# intensity read (viz[0].a) is well-defined — a 0-alpha fill is a declared no-op tint (C).
	var viz: Array = [{ "kind": "fill", "r": col[0], "g": col[1], "b": col[2], "a": _intensity }]

	return { "out": {
		"kind": "flash",
		"viz": viz,
		"width": w,
		"height": h,
	} }

# Tint color: a wired {r,g,b} dict (freq_to_color) or [r,g,b] array wins; else params.color; else white.
func _tint_color(inputs: Dictionary) -> Array:
	var wired = inputs.get("color")
	if typeof(wired) == TYPE_DICTIONARY and wired.has("r"):
		return [float(wired.get("r", 1.0)), float(wired.get("g", 1.0)), float(wired.get("b", 1.0))]
	if typeof(wired) == TYPE_ARRAY and (wired as Array).size() >= 3:
		return [float(wired[0]), float(wired[1]), float(wired[2])]
	var c: Array = params.get("color", [1.0, 1.0, 1.0])
	return [float(c[0]), float(c[1]), float(c[2])]

func reset_state() -> void:
	_intensity = 0.0

## Impure: carries the decaying intensity across frames. Never memoize.
func is_cacheable() -> bool:
	return false
