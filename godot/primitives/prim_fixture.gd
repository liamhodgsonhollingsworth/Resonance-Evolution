class_name PrimFixture
extends Primitive
## PrimFixture — a lighting-FIXTURE DESCRIPTOR as plain DATA. (Visi-sonor arc, Wave 3A.)
##
## A fixture (a par-can, a moving head, an RGB LED bar) has an ordered list of DMX channels, each a
## named function (dimmer, red, green, blue, ...) occupying one slot in the universe from a base address.
## This primitive emits that descriptor — an OFL/GDTF-aligned JSON schema — on the `fixture` port as
## plain DATA. prim_channel_map consumes it to route logical light params to actual channel indices.
##
## The schema (OFL = Open Fixture Library / GDTF = General Device Type Format, simplified to the fields
## the transport path needs):
##   { kind:"fixture", name:<str>, address:<int base DMX channel, 1-based like a real desk>,
##     color_mode:"rgb"|"rgbw"|"dimmer"|"generic",
##     channels:[ { name:"dimmer"|"red"|"green"|"blue"|"white"|..., offset:<int 0-based from address>,
##                  range:[<lo>,<hi>] (the 0..255 DMX range this function spans, default [0,255]) }, ... ] }
##
## color_mode is a convenience label; the AUTHORITATIVE routing is the `channels` list (a real host reads
## the channel names). A minimal RGB fixture defaults to r,g,b at offsets 0,1,2 when channels is empty.
##
## IDEALS: T — a fixture is DATA, no Godot object. N — a new primitive TYPE. C — a malformed/absent
## channel list degrades to the default RGB triple; nothing crashes.
##
## params:
##   name        fixture name (default "fixture").
##   address     base DMX channel, 1-based (default 1). channel offset i lands at (address-1)+offset.
##   color_mode  "rgb"|"rgbw"|"dimmer"|"generic" (default "rgb").
##   channels    [{ name, offset, range? }, ...] — explicit channel layout. When empty, derived from
##               color_mode (rgb -> red/green/blue at 0/1/2; rgbw adds white at 3; dimmer -> dimmer at 0).
##
## inputs: (none — a fixture is authored config).  outputs: fixture (dict).

func _init() -> void:
	prim_type = "Fixture"


func output_ports() -> Array:
	return [{ "name": "fixture", "type": "any" }]


func evaluate(_inputs: Dictionary) -> Dictionary:
	var mode := str(params.get("color_mode", "rgb"))
	var channels: Array = params.get("channels", [])
	if typeof(channels) != TYPE_ARRAY or channels.is_empty():
		channels = _default_channels(mode)
	# Normalize each channel to the full schema (default range, integer offset).
	var norm: Array = []
	for c in channels:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var rng = c.get("range", [0, 255])
		norm.append({
			"name": str(c.get("name", "generic")),
			"offset": int(_num(c.get("offset", 0))),
			"range": [int(_num(rng[0])) if rng is Array and rng.size() > 0 else 0,
					  int(_num(rng[1])) if rng is Array and rng.size() > 1 else 255],
		})
	return { "fixture": {
		"kind": "fixture",
		"name": str(params.get("name", "fixture")),
		"address": int(_num(params.get("address", 1))),
		"color_mode": mode,
		"channels": norm,
	}}


## Derive the standard channel layout for a color_mode when none is authored.
static func _default_channels(mode: String) -> Array:
	match mode:
		"rgbw":
			return [{ "name": "red", "offset": 0 }, { "name": "green", "offset": 1 },
					{ "name": "blue", "offset": 2 }, { "name": "white", "offset": 3 }]
		"dimmer":
			return [{ "name": "dimmer", "offset": 0 }]
		"generic":
			return [{ "name": "generic", "offset": 0 }]
		_:  # "rgb" and anything unknown
			return [{ "name": "red", "offset": 0 }, { "name": "green", "offset": 1 },
					{ "name": "blue", "offset": 2 }]


static func _num(v) -> float:
	match typeof(v):
		TYPE_INT, TYPE_FLOAT:
			return float(v)
		TYPE_BOOL:
			return 1.0 if v else 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			return float(v) if str(v).is_valid_float() else 0.0
		_:
			return 0.0
