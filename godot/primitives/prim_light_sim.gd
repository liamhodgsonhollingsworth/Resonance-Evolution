class_name PrimLightSim
extends Primitive
## PrimLightSim — a ZERO-HARDWARE virtual LED-strip SINK. (Visi-sonor arc, Wave 3A.)
##
## This is the self-test fixture that lets the whole transport lane be verified with NO real device: it
## receives light writes (device.set_led receipts, a DMX universe buffer, or a DDP pixel list) and
## records them into an in-memory RGB buffer a headless test asserts against. It is the software analog
## of a real WLED strip — same input shapes, no socket.
##
## THREE ingest shapes (all convert to the same [[r,g,b 0..255],...] buffer):
##   • apply_set_led(receipt) — a device.set_led receipt { r,g,b (0..1 or 0..255), addr } -> writes
##     pixel[addr]. (Convention: set_led's r/g/b are the substrate's 0..1 linear colour.)
##   • apply_universe(bytes)  — a DMX channel Array (from prim_dmx_universe) -> every 3 channels = a pixel.
##   • apply_pixels(pixels)   — a DDP/WLED pixel list [[r,g,b],...] (0..1 or 0..255) -> written from 0.
##
## As a PRIMITIVE it can also sit in a graph: evaluate() ingests a wired `universe`/`pixels`/`set_led`
## and emits the recorded buffer on `pixels` — so a headless arrangement can read the virtual strip's
## state as DATA (T-ideal). It also registers a `device.light_sim` host op so a device.* arrangement can
## target the virtual strip directly (ADDITIVE — set_led untouched, N-ideal).
##
## IDEALS: T — buffer is a plain int Array on the wire. N — new primitive TYPE + a NEW additive op. C —
## an out-of-range addr / garbage value is clamped/ignored, never a crash (the whole point: a sink you
## can hammer with malformed frames in a test and it stays alive).
##
## params:
##   pixel_count  number of RGB pixels the virtual strip holds (default 16).

var _pixels: Array = []      # [[r,g,b 0..255], ...]
var _count: int = 16
var _writes: int = 0         # how many ingest calls landed (a test asserts the sink was actually hit)


func _init() -> void:
	prim_type = "LightSim"
	_resize(16)


func input_ports() -> Array:
	return [
		{ "name": "universe", "type": "any" },
		{ "name": "pixels", "type": "any" },
		{ "name": "set_led", "type": "any" },
	]


func output_ports() -> Array:
	return [
		{ "name": "pixels", "type": "any" },
		{ "name": "writes", "type": "number" },
	]


func evaluate(inputs: Dictionary) -> Dictionary:
	_resize(int(params.get("pixel_count", 16)))
	if inputs.has("universe") and inputs.get("universe") != null:
		apply_universe(inputs.get("universe"))
	if inputs.has("pixels") and inputs.get("pixels") != null:
		apply_pixels(inputs.get("pixels"))
	if inputs.has("set_led") and inputs.get("set_led") != null:
		apply_set_led(inputs.get("set_led"))
	return { "pixels": get_buffer(), "writes": _writes }


# --- ingest API (used directly by the headless test + the device.light_sim op) ---------------------

## Ingest a device.set_led receipt { r,g,b,addr }. r/g/b are the substrate 0..1 linear colour.
func apply_set_led(receipt) -> void:
	if typeof(receipt) != TYPE_DICTIONARY:
		return
	var addr := int(_num(receipt.get("addr", 0)))
	if addr < 0 or addr >= _count:
		return   # out-of-range addr ignored (C-ideal)
	_pixels[addr] = [
		_component_to_byte(receipt.get("r", 0)),
		_component_to_byte(receipt.get("g", 0)),
		_component_to_byte(receipt.get("b", 0)),
	]
	_writes += 1


## Ingest a DMX channel buffer (from prim_dmx_universe): channels 3k..3k+2 == pixel k.
func apply_universe(bytes) -> void:
	if typeof(bytes) != TYPE_ARRAY:
		return
	var n := int((bytes as Array).size() / 3)
	for k in min(n, _count):
		_pixels[k] = [
			clampi(int(_num(bytes[k * 3])), 0, 255),
			clampi(int(_num(bytes[k * 3 + 1])), 0, 255),
			clampi(int(_num(bytes[k * 3 + 2])), 0, 255),
		]
	_writes += 1


## Ingest a DDP/WLED pixel list [[r,g,b],...] (0..1 or 0..255) from pixel 0.
func apply_pixels(pixels) -> void:
	if typeof(pixels) != TYPE_ARRAY:
		return
	for k in min((pixels as Array).size(), _count):
		var p = pixels[k]
		if typeof(p) == TYPE_ARRAY and (p as Array).size() >= 3:
			_pixels[k] = [_component_to_byte(p[0]), _component_to_byte(p[1]), _component_to_byte(p[2])]
	_writes += 1


## The recorded buffer as [[r,g,b 0..255], ...] (a copy — a test reads it as DATA).
func get_buffer() -> Array:
	return _pixels.duplicate(true)


## Read one pixel's [r,g,b]. Out-of-range returns [0,0,0].
func get_pixel(k: int) -> Array:
	if k < 0 or k >= _count:
		return [0, 0, 0]
	return _pixels[k].duplicate()


## How many ingest calls landed (a test asserts the sink was actually driven).
func write_count() -> int:
	return _writes


func clear() -> void:
	_resize(_count)
	_writes = 0


# --- additive host op: device.light_sim ------------------------------------------------------------

## Register a `device.light_sim` host op that routes a { r,g,b,addr } (or wired `value`) into a SHARED
## virtual strip instance — ADDITIVE, set_led untouched (N-ideal). Returns [op_name, sink] so a test can
## register AND then read the very sink the op writes to. Pass a WorldActions CLASS or instance.
static func register_ops(world_actions) -> Array:
	if world_actions == null:
		return []
	var sink: PrimLightSim = PrimLightSim.new()
	sink._resize(64)
	var fn := func(args: Dictionary) -> Dictionary:
		# Accept both a top-level {r,g,b,addr} and a wired `value` payload (the BRAIN wire shape).
		var payload = args.get("value", null)
		var r = args.get("r", null); var g = args.get("g", null)
		var b = args.get("b", null); var addr = args.get("addr", null)
		if typeof(payload) == TYPE_DICTIONARY:
			if r == null: r = payload.get("r", 0)
			if g == null: g = payload.get("g", 0)
			if b == null: b = payload.get("b", 0)
			if addr == null: addr = payload.get("addr", 0)
		sink.apply_set_led({ "r": r if r != null else 0, "g": g if g != null else 0,
							 "b": b if b != null else 0, "addr": addr if addr != null else 0 })
		return { "ok": true, "op": "device.light_sim", "addr": int(sink._num(addr if addr != null else 0)),
				 "writes": sink._writes }
	if world_actions == WorldActions:
		WorldActions.register_host("device.light_sim", fn)
	else:
		world_actions.register("device.light_sim", fn)
	return ["device.light_sim", sink]


# --- helpers ---------------------------------------------------------------------------------------

func _resize(n: int) -> void:
	n = maxi(1, n)
	_count = n
	_pixels = []
	for i in n:
		_pixels.append([0, 0, 0])


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

const WorldActions := preload("res://runtime/world_actions.gd")
