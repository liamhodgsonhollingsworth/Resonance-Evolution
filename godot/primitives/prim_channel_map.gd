class_name PrimChannelMap
extends Primitive
## PrimChannelMap — routes LOGICAL light params (r,g,b,dimmer,white) to a fixture's DMX universe
## channels. (Visi-sonor arc, Wave 3A.) The bridge between the BRAIN's colour output and the wire.
##
## A fixture (prim_fixture) declares WHICH channel is red/green/blue/dimmer and its base address. This
## node takes a logical colour ({ r,g,b,dimmer? } 0..1) + that fixture descriptor and emits the set of
## absolute channel writes ({ "<abs_index>": <0..255>, ... }) — the exact input prim_dmx_universe.channels
## consumes. So "light-param -> channels" is a data transform, portable and rewireable (T/N/R ideals).
##
## Addressing: a fixture's `address` is 1-based (real desk convention); a channel's `offset` is 0-based
## from that address; the UNIVERSE is 0-indexed. So absolute channel = (address - 1) + offset. Channel
## values are scaled from the logical 0..1 into the channel's `range` [lo,hi] (default [0,255]).
##
## The `dimmer` (master intensity, 0..1, default 1.0) scales r/g/b for a fixture WITHOUT a dedicated
## dimmer channel (common on cheap RGB pars). If the fixture HAS a dimmer channel, the dimmer rides that
## channel and r/g/b pass through un-scaled — the physical dimmer does the scaling. This keeps one
## logical `dimmer` knob correct across both fixture shapes.
##
## IDEALS: T — output is a plain { index:value } dict. N — new primitive TYPE. C — an absent/garbage
## fixture or colour degrades to a no-op empty map, never a crash.
##
## params (fallbacks when the corresponding input is unwired):
##   color   { r,g,b } 0..1 (default black).   dimmer  0..1 (default 1.0).
##   fixture the fixture descriptor (usually WIRED from prim_fixture; param is a fallback).
##
## inputs: color ({r,g,b} dict or [r,g,b] array), dimmer (number), fixture (dict from PrimFixture).
## outputs: channels ({ "<abs>": <0..255> } dict, ready for DmxUniverse.channels), address (int base).

func _init() -> void:
	prim_type = "ChannelMap"


func input_ports() -> Array:
	return [
		{ "name": "color", "type": "any" },
		{ "name": "dimmer", "type": "number" },
		{ "name": "fixture", "type": "any" },
	]


func output_ports() -> Array:
	return [
		{ "name": "channels", "type": "any" },
		{ "name": "address", "type": "number" },
	]


func evaluate(inputs: Dictionary) -> Dictionary:
	var fixture = inputs.get("fixture", params.get("fixture", null))
	if typeof(fixture) != TYPE_DICTIONARY:
		return { "channels": {}, "address": 0 }

	var color = inputs.get("color", params.get("color", { "r": 0.0, "g": 0.0, "b": 0.0 }))
	var rgb := _as_rgb(color)
	var dimmer := _num(inputs.get("dimmer", params.get("dimmer", 1.0)))
	dimmer = clampf(dimmer, 0.0, 1.0)

	var address := int(_num(fixture.get("address", 1)))
	var base := address - 1
	var channels: Array = fixture.get("channels", [])
	var has_dimmer_channel := false
	for c in channels:
		if typeof(c) == TYPE_DICTIONARY and str(c.get("name", "")) == "dimmer":
			has_dimmer_channel = true
			break

	# When there is NO dimmer channel, fold the master dimmer into the RGB values.
	var rgb_scale := 1.0 if has_dimmer_channel else dimmer
	var white := _white_from_rgb(rgb)

	var out := {}
	for c in channels:
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var name := str(c.get("name", "generic"))
		var offset := int(_num(c.get("offset", 0)))
		var rng = c.get("range", [0, 255])
		var lo := int(_num(rng[0])) if rng is Array and rng.size() > 0 else 0
		var hi := int(_num(rng[1])) if rng is Array and rng.size() > 1 else 255
		var logical := 0.0
		match name:
			"red": logical = rgb[0] * rgb_scale
			"green": logical = rgb[1] * rgb_scale
			"blue": logical = rgb[2] * rgb_scale
			"white": logical = white * rgb_scale
			"dimmer": logical = dimmer
			_: logical = 0.0   # unknown channel functions stay at their floor (safe default)
		var abs_index := base + offset
		out[str(abs_index)] = _scale_to_range(logical, lo, hi)
	return { "channels": out, "address": address }


# --- helpers ---------------------------------------------------------------------------------------

## Scale a logical 0..1 value into a DMX [lo,hi] byte range (clamped).
static func _scale_to_range(logical: float, lo: int, hi: int) -> int:
	logical = clampf(logical, 0.0, 1.0)
	return clampi(int(round(lo + logical * float(hi - lo))), 0, 255)


## A wired colour may be a { r,g,b } dict or an [r,g,b] array (0..1). Coerce to a 3-float array.
static func _as_rgb(color) -> Array:
	if typeof(color) == TYPE_DICTIONARY:
		return [_num(color.get("r", 0.0)), _num(color.get("g", 0.0)), _num(color.get("b", 0.0))]
	if typeof(color) == TYPE_ARRAY and (color as Array).size() >= 3:
		return [_num(color[0]), _num(color[1]), _num(color[2])]
	return [0.0, 0.0, 0.0]


## A simple white extraction for an RGBW fixture: the min of the three channels (the achromatic part).
static func _white_from_rgb(rgb: Array) -> float:
	return min(rgb[0], min(rgb[1], rgb[2]))


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
