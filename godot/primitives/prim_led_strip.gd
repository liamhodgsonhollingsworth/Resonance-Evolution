class_name PrimLedStrip
extends Primitive
## Emits an ARRAY of renderer-NEUTRAL prim_light descriptors sampled along a path — a controllable
## LED strip whose every pixel is INDIVIDUALLY ADDRESSABLE (drivable by device.set_led{r,g,b,addr}).
## As DATA, never live Godot lights: the array is `count` KHR_lights_punctual point-light descriptors
## (the EXACT shape PrimLight.evaluate emits — this node REUSES PrimLight per pixel, R-ideal), each at
## a position linearly interpolated between `start` and `end` (a straight spline; the general curve is
## a later data change, not an engine edit), and each carrying addr = base_addr + pixel_index.
##
## THE STRIP IS THE ARRAY-OF-prim_light CONVENIENCE the plan calls for: a fixture that is one wire but
## N addressable pixels. Because a pixel is a plain PrimLight descriptor AND a plain {r,g,b,addr}
## set_led payload, the SAME strip drives BOTH the 3D renderer (via the `lights` port -> the scene's
## light array) AND a real WLED / addressable-LED transport (via the `set_led` port -> per-pixel
## device.set_led). One descriptor, any sink — the substrate-independence law applied to a strip.
##
## params:
##   count       number of pixels (default 0 => an empty strip: empty arrays, no crash — C-ideal).
##   base_addr   addr of pixel 0; pixel i gets base_addr + i (default 0).
##   start       [x,y,z] position of the FIRST pixel (default [0,0,0]).
##   end         [x,y,z] position of the LAST pixel (default [1,0,0]).
##   color       default [r,g,b] linear for every pixel (default [1,1,1]); per-pixel `colors` input wins.
##   intensity   per-pixel light intensity/energy (default 1.0).
##   range       point-light falloff distance (default 0 = engine default).
##
## inputs (optional — all rewireable data, so 'point the strip at a different sound' is a wire change):
##   colors : an Array of per-pixel [r,g,b] (or {r,g,b}); entry i drives pixel i. Missing/short -> the
##            param `color` default. This is how an upstream freq_to_color / band feed lights the strip.
##
## outputs:
##   lights  Array of prim_light descriptors (renderer-neutral, one per pixel) — the 3D-render sink.
##   set_led Array of {r,g,b,addr} device.set_led payloads (one per pixel) — the real-transport sink.

const PrimLightScript := preload("res://primitives/prim_light.gd")

func _init() -> void:
	prim_type = "LedStrip"

func input_ports() -> Array:
	return [{ "name": "colors", "type": "any" }]

func output_ports() -> Array:
	return [
		{ "name": "lights", "type": "any" },
		{ "name": "set_led", "type": "any" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var count := maxi(int(params.get("count", 0)), 0)
	var base_addr := int(params.get("base_addr", 0))
	var start := _v3(params.get("start", [0.0, 0.0, 0.0]), [0.0, 0.0, 0.0])
	var end := _v3(params.get("end", [1.0, 0.0, 0.0]), [1.0, 0.0, 0.0])
	var def_color := _v3(params.get("color", [1.0, 1.0, 1.0]), [1.0, 1.0, 1.0])
	var intensity := float(params.get("intensity", 1.0))
	var colors_in = inputs.get("colors")

	var lights: Array = []
	var set_led: Array = []
	for i in count:
		# Position: linear-interpolate start..end. A 1-pixel strip sits at start (avoid div-by-zero).
		var t := 0.0 if count <= 1 else float(i) / float(count - 1)
		var pos := [
			lerp(start[0], end[0], t),
			lerp(start[1], end[1], t),
			lerp(start[2], end[2], t),
		]
		var color := _pixel_color(colors_in, i, def_color)
		var addr := base_addr + i

		# REUSE PrimLight verbatim (R-ideal): build the SAME descriptor a Light node would, per pixel.
		var pl := PrimLightScript.new()
		pl.params = {
			"type": "point",
			"color": color,
			"intensity": intensity,
			"position": pos,
		}
		if params.has("range"):
			pl.params["range"] = float(params.get("range"))
		var desc: Dictionary = pl.evaluate({}).get("light", {})
		pl.free()
		# Ride the device addr on the descriptor so the SAME pixel drives renderer + real WLED.
		desc["addr"] = addr
		lights.append(desc)

		# device.set_led-compatible payload (the { r,g,b,addr } shape DeviceActions._op_set_led reads).
		set_led.append({ "r": color[0], "g": color[1], "b": color[2], "addr": addr })

	return { "lights": lights, "set_led": set_led }

## The color for pixel i: the wired per-pixel `colors` entry if present + well-formed, else the default.
func _pixel_color(colors_in, i: int, fallback: Array) -> Array:
	if typeof(colors_in) == TYPE_ARRAY and i < (colors_in as Array).size():
		return _v3(colors_in[i], fallback)
	return fallback

# A plain 3-array [r,g,b] from an Array [r,g,b(...)] or a { r,g,b } dict — JSON-serialisable (gate T).
func _v3(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 3:
		return [float(a[0]), float(a[1]), float(a[2])]
	if a is Dictionary and a.has("r") and a.has("g") and a.has("b"):
		return [float(a["r"]), float(a["g"]), float(a["b"])]
	return fallback
