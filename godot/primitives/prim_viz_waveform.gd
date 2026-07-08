class_name PrimVizWaveform
extends Primitive
## WAVEFORM (visi-sonor light-show Slice 2A, items 7+8) — the oscilloscope / lissajous line. It draws
## a polyline whose vertical excursion is driven by a feature (an amplitude / energy WIRE), giving the
## classic scrolling-scope look OR, in lissajous mode, an X/Y figure driven by two features.
##
## RENDERER-NEUTRAL DATA (T): emits an ordered list of {kind:"vertex", x,y} points in a draw-list dict
## (the SAME shape the shared PrimVizSpectrumBars.rasterize consumes, so it renders through the
## EXISTING render seam — R). No pixels held here.
##
## ITEM-8 REWIREABLE: the driving amplitude arrives on a WIRE (prim_feature_pick), so the SAME scope
## can be pointed at bass, treble, energy, or a beat envelope — a re-param, never an engine edit.
##
## The demo does not have a raw PCM buffer on the wire (the audio front end emits BANDS, not samples),
## so the "waveform" is SYNTHESIZED: a fixed-frequency sine whose AMPLITUDE is the driving feature —
## a scope whose trace grows with loudness. (A future host that DOES wire a `samples` array plots it
## verbatim; absent samples -> the synthesized scope. Both are the same vertex list on the wire.)
##
## params:
##   mode        "oscilloscope" (a horizontal scrolling sine) | "lissajous" (x<-featA, y<-featB curve).
##   samples     number of polyline points (default 64).
##   cycles      sine cycles across the width in oscilloscope mode (default 3).
##   amp_gain    fraction of half-height the amplitude spans (default 0.9).
##   width,height  canvas size (default 128x64).
##   color       [r,g,b] line color (default [0.3,1.0,0.6]).
##
## inputs:  amplitude — the driving feature 0..1 (oscilloscope excursion). Unconnected = 0 -> a flat
##                      centre line, never a crash (C).
##          amplitude_y — the second feature for lissajous mode (default = amplitude).
##          samples    — optional explicit sample array (-1..1); plotted verbatim when present.
## output:  out — the draw-list descriptor.

func _init() -> void:
	prim_type = "VizWaveform"

func input_ports() -> Array:
	return [
		{ "name": "amplitude", "type": "number" },
		{ "name": "amplitude_y", "type": "number" },
		{ "name": "samples", "type": "any" },
	]

func output_ports() -> Array:
	return [{ "name": "out", "type": "image" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var w := int(params.get("width", 128))
	var h := int(params.get("height", 64))
	var n := maxi(2, int(params.get("samples", 64)))
	var mode := str(params.get("mode", "oscilloscope"))
	var amp_gain: float = clamp(float(params.get("amp_gain", 0.9)), 0.0, 1.0)
	var cycles := float(params.get("cycles", 3.0))
	var col: Array = params.get("color", [0.3, 1.0, 0.6])
	var amp: float = clampf(as_num(inputs.get("amplitude")), 0.0, 1.0)

	var viz: Array = []
	var explicit = inputs.get("samples")
	var cy := float(h) * 0.5
	var half := float(h) * 0.5 * amp_gain

	if typeof(explicit) == TYPE_ARRAY and (explicit as Array).size() >= 2:
		# Plot the explicit sample array verbatim (a real PCM/scope buffer if a host wires one).
		var arr := explicit as Array
		var m := arr.size()
		for i in m:
			var x := float(i) / float(m - 1) * float(w - 1)
			var s: float = clampf(as_num(arr[i]), -1.0, 1.0)
			viz.append(_vertex(x, cy - s * half, col))
	elif mode == "lissajous":
		# x <- ampA sine, y <- ampB cosine -> a figure whose size grows with the two features.
		var ampy: float = clampf(as_num(inputs.get("amplitude_y")) if inputs.get("amplitude_y") != null else amp, 0.0, 1.0)
		var cx := float(w) * 0.5
		var hx := float(w) * 0.5 * amp_gain
		for i in n:
			var tt := float(i) / float(n - 1)
			var ph := TAU * tt
			viz.append(_vertex(cx + sin(ph * 3.0) * hx * amp, cy - cos(ph * 2.0) * half * ampy, col))
	else:
		# Oscilloscope: a sine across the width whose excursion is the driving amplitude.
		for i in n:
			var tt := float(i) / float(n - 1)
			var x := tt * float(w - 1)
			var s := sin(TAU * cycles * tt)
			viz.append(_vertex(x, cy - s * half * amp, col))

	return { "out": {
		"kind": "waveform",
		"viz": viz,
		"width": w,
		"height": h,
		"closed": mode == "lissajous",
	} }

func _vertex(x: float, y: float, col: Array) -> Dictionary:
	return { "kind": "vertex", "x": x, "y": y, "r": float(col[0]), "g": float(col[1]), "b": float(col[2]) }

## Pure: deterministic function of inputs + params. Safe to memoize per-frame.
func is_cacheable() -> bool:
	return true
