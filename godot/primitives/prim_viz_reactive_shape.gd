class_name PrimVizReactiveShape
extends Primitive
## REACTIVE SHAPE (visi-sonor light-show Slice 2A, items 7+8) — a pulsing circle / blob: its overall
## RADIUS is driven by one feature and its PER-VERTEX DEFORM (the lumpy, breathing wobble) by another.
## This is Milkdrop-in-miniature: a single closed polygon whose vertices ride sine perturbations whose
## amplitude is an audio feature, so the blob throbs on the bass and ripples on the treble.
##
## RENDERER-NEUTRAL DATA (T): emits an ordered CLOSED polygon as {kind:"vertex", x,y} points in a
## draw-list dict (the shared PrimVizSpectrumBars.rasterize consumes it — R, one rasterizer for all).
##
## ITEM-8 REWIREABLE: `radius` and `deform` are WIRES (prim_feature_pick), so which part of the music
## drives size vs wobble is a re-param, never an engine edit. NEVER hardwired to a band.
##
## DEFORM MODEL: each vertex k gets radius = base + radius_gain*radius_feat + deform_gain*deform_feat*
## sin(lobes*theta_k + phase). deform_feat=0 -> a clean circle; deform_feat>0 -> a lumpy blob. The
## deform raises the per-vertex radius VARIANCE (the test's Milkdrop-in-miniature assertion).
##
## params:
##   sides       polygon vertex count (default 48). More = smoother blob.
##   base_radius pixels of radius at zero signal (default 8).
##   radius_gain pixels added per unit `radius` feature (default 20).
##   deform_gain pixels of per-vertex wobble per unit `deform` feature (default 10).
##   lobes       spatial frequency of the wobble around the ring (default 5).
##   width,height  canvas size (default 128x128). Centre = canvas centre.
##   color       [r,g,b] outline color (default [1.0,0.5,0.9]).
##
## inputs:  radius — overall size feature 0..1. Unconnected = 0 -> the base circle (C).
##          deform — per-vertex wobble feature 0..1. Unconnected = 0 -> a clean circle (C).
## output:  out — the draw-list descriptor (a closed polygon).

func _init() -> void:
	prim_type = "VizReactiveShape"

func input_ports() -> Array:
	return [
		{ "name": "radius", "type": "number" },
		{ "name": "deform", "type": "number" },
	]

func output_ports() -> Array:
	return [{ "name": "out", "type": "image" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var w := int(params.get("width", 128))
	var h := int(params.get("height", 128))
	var sides := maxi(3, int(params.get("sides", 48)))
	var base_r := float(params.get("base_radius", 8.0))
	var radius_gain := float(params.get("radius_gain", 20.0))
	var deform_gain := float(params.get("deform_gain", 10.0))
	var lobes := float(params.get("lobes", 5.0))
	var col: Array = params.get("color", [1.0, 0.5, 0.9])

	var radius_feat: float = clampf(as_num(inputs.get("radius")), 0.0, 1.0)
	var deform_feat: float = clampf(as_num(inputs.get("deform")), 0.0, 1.0)

	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	var r_mean := base_r + radius_gain * radius_feat

	var viz: Array = []
	for k in sides:
		var theta := TAU * float(k) / float(sides)
		# Per-vertex radius: mean + deform wobble. The wobble uses the vertex angle so different
		# vertices push in/out differently -> variance rises with deform_feat (Milkdrop-in-miniature).
		var wobble := deform_gain * deform_feat * sin(lobes * theta)
		var r := maxf(0.5, r_mean + wobble)
		viz.append({ "kind": "vertex", "x": cx + cos(theta) * r, "y": cy + sin(theta) * r,
			"r": float(col[0]), "g": float(col[1]), "b": float(col[2]) })

	return { "out": {
		"kind": "reactive_shape",
		"viz": viz,
		"width": w,
		"height": h,
		"closed": true,
	} }

## Pure: deterministic function of inputs + params. Safe to memoize per-frame.
func is_cacheable() -> bool:
	return true
