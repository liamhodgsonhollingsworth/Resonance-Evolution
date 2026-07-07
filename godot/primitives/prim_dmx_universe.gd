class_name PrimDmxUniverse
extends Primitive
## PrimDmxUniverse — a 512-channel DMX / pixel FRAMEBUFFER as plain DATA. (Visi-sonor arc, Wave 3A.)
##
## A DMX universe is 512 channels (bytes 0..255), the atomic addressing unit of stage lighting. This
## primitive is the in-engine framebuffer: a fixture (via prim_channel_map) writes its logical params
## into channels here, and a transport (DDP/WLED) reads the buffer out to real hardware. It ALSO exposes
## a PIXEL view (RGB triples) for addressable LED strips, where channel 3k+{0,1,2} == pixel k's r,g,b.
##
## IDEALS:
##   • T (data on wires): evaluate() emits the whole universe as a plain byte Array on the `universe`
##     port (+ a `pixels` [[r,g,b],...] view). No Godot object on the wire — a JS/Py re-impl only matches
##     the byte array. The buffer is authored from params.channels (index->value) and/or params.pixels.
##   • N (additive): a brand-new primitive TYPE; nothing existing is edited.
##   • C (graceful): out-of-range channel indices are ignored (never crash); malformed values coerce.
##   • D (hot-reload): the buffer rebuilds from params each evaluate(), so a diff-hotload of params
##     re-renders the frame — the imperative set/get helpers below are for the transport/test path.
##
## params:
##   size      channel count (default 512, the DMX universe size). Kept as a knob for pixel strips that
##             want a tight buffer (e.g. 30 LEDs -> 90 channels).
##   channels  { "<index>": <0..255> } sparse channel writes applied onto the zeroed buffer.
##   pixels    [[r,g,b], ...] (0..1 or 0..255) written from channel 0 (each pixel = 3 channels).
##
## inputs (optional, override params): channels (dict), pixels (array).
## outputs: universe (byte Array, length size), pixels ([[r,g,b],...]), size (int).

var _buf: PackedByteArray = PackedByteArray()
var _size: int = 512


func _init() -> void:
	prim_type = "DmxUniverse"
	_resize(512)


func input_ports() -> Array:
	return [
		{ "name": "channels", "type": "any" },
		{ "name": "pixels", "type": "any" },
	]


func output_ports() -> Array:
	return [
		{ "name": "universe", "type": "any" },
		{ "name": "pixels", "type": "any" },
		{ "name": "size", "type": "number" },
	]


func evaluate(inputs: Dictionary) -> Dictionary:
	_resize(int(params.get("size", 512)))
	blackout()
	# Pixel array first (spans channels 0..3n), then explicit channel writes (can override).
	var px = inputs.get("pixels", params.get("pixels", null))
	if px != null:
		set_pixels(px)
	var ch = inputs.get("channels", params.get("channels", null))
	if typeof(ch) == TYPE_DICTIONARY:
		for k in ch.keys():
			set_channel(int(_num(k)), int(_num(ch[k])))
	return {
		"universe": _buf_as_array(),
		"pixels": get_pixels(),
		"size": _size,
	}


# --- imperative framebuffer API (used by the transport path + headless test) -----------------------

## Set one channel (0..size-1) to 0..255. Out-of-range index is IGNORED (C-ideal, no crash). Value is
## clamped to a DMX byte.
func set_channel(index: int, value: int) -> void:
	if index < 0 or index >= _size:
		return
	_buf[index] = clampi(int(value), 0, 255)


## Get one channel (0..255). Out-of-range returns 0 (never crash).
func get_channel(index: int) -> int:
	if index < 0 or index >= _size:
		return 0
	return _buf[index]


## Zero every channel (all lights off) — the DMX "blackout".
func blackout() -> void:
	for i in _size:
		_buf[i] = 0


## Write pixel k (an [r,g,b], 0..1 or 0..255) into channels 3k,3k+1,3k+2. Out-of-range pixels clip.
func set_pixel(k: int, rgb: Array) -> void:
	if k < 0 or rgb.size() < 3:
		return
	set_channel(k * 3 + 0, _component_to_byte(rgb[0]))
	set_channel(k * 3 + 1, _component_to_byte(rgb[1]))
	set_channel(k * 3 + 2, _component_to_byte(rgb[2]))


## Write a whole pixel array [[r,g,b],...] from channel 0.
func set_pixels(pixels) -> void:
	if typeof(pixels) != TYPE_ARRAY:
		return
	for k in pixels.size():
		if typeof(pixels[k]) == TYPE_ARRAY:
			set_pixel(k, pixels[k])


## Read the buffer back as an [[r,g,b],...] pixel view (floor(size/3) pixels, 0..255).
func get_pixels() -> Array:
	var out: Array = []
	var n := int(_size / 3)
	for k in n:
		out.append([_buf[k * 3], _buf[k * 3 + 1], _buf[k * 3 + 2]])
	return out


## The raw channel buffer as a plain int Array (JSON-serializable wire value).
func get_channels() -> Array:
	return _buf_as_array()


func size() -> int:
	return _size


# --- helpers ---------------------------------------------------------------------------------------

func _resize(n: int) -> void:
	n = clampi(n, 1, 512)
	if n == _size and _buf.size() == n:
		return
	_size = n
	_buf = PackedByteArray()
	_buf.resize(n)   # zero-filled


func _buf_as_array() -> Array:
	var out: Array = []
	for i in _size:
		out.append(_buf[i])
	return out


static func _component_to_byte(c) -> int:
	var f := _num(c)
	if f <= 1.0 and f >= 0.0:
		f = f * 255.0
	return clampi(int(round(f)), 0, 255)


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
