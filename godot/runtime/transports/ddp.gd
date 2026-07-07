extends RefCounted
class_name DdpTransport
## DdpTransport — a REAL lighting transport SINK over the Distributed Display Protocol (DDP) UDP.
## (Visi-sonor light-show arc, Wave 3A — the real hardware seam.)
##
## DDP is the simple UDP pixel-streaming protocol WLED speaks natively (default UDP port 4048). A DDP
## packet is a 10-byte header + an RGB payload. This module is the ONE transport wired for REAL: it
## builds the exact wire bytes and sends them via Godot's PacketPeerUDP (which opens a UDP socket — it
## spawns NO console window, unlike a subprocess). artnet/sacn (sibling files) are declared no-ops.
##
## PORTABILITY + IDEALS:
##   • T (data on wires): build_packet() is a PURE function ([r,g,b,...] bytes -> a PackedByteArray). The
##     packet is plain DATA; a headless test asserts the exact byte layout WITHOUT any real hardware.
##   • C (absent hardware/host = no-op, never a crash): send() opens a socket and pushes bytes; if the
##     target host is unreachable the UDP send simply goes nowhere (connectionless) — no exception, no
##     crash. A malformed pixel list coerces defensively.
##   • N (additive): this is a NEW sink module. It does NOT edit set_led — it is registered as a NEW
##     host op (device.pixel_send) via register_ops(), leaving every existing op untouched.
##
## THE DDP HEADER (10 bytes, per the DDP spec — http://www.3waylabs.com/ddp/):
##   byte 0  : flags  — 0x40 version-1 (bits 6-7 = 01) | 0x01 PUSH (display immediately) = 0x41.
##   byte 1  : sequence number (0 = "not used"; 1..15 cycle for reliability). We cycle 1..15.
##   byte 2  : data type — 0x01 = "custom / RGB, 8 bits per channel" (WLED accepts 0 or 1 as RGB8).
##   byte 3  : destination ID — 1 = default output device (the strip).
##   bytes 4-7 : data offset in bytes (big-endian uint32) — where in the frame these pixels start.
##   bytes 8-9 : data length in bytes (big-endian uint16) — number of payload bytes that follow.
##   bytes 10+ : the RGB payload (r,g,b, r,g,b, ...), one byte per channel, 0..255.

const PORT_DEFAULT := 4048
const FLAG_VER1_PUSH := 0x41   # version 1 (0x40) | PUSH (0x01)
const DATATYPE_RGB8 := 0x01    # custom RGB, 8 bits/channel
const DEST_DEFAULT := 0x01     # default output device

var host: String = "127.0.0.1"
var port: int = PORT_DEFAULT
var _seq: int = 0
var _udp: PacketPeerUDP = null


## Build a DDP packet from a flat RGB byte list (values 0..255, coerced) at a byte `offset`, with an
## explicit `seq` (0..15) and `push` flag. PURE — returns the exact wire bytes as a PackedByteArray, so
## a headless test asserts the layout with no socket. The offset lets a strip be updated in segments.
static func build_packet(rgb_bytes: Array, offset: int = 0, seq: int = 1, push: bool = true) -> PackedByteArray:
	var payload := PackedByteArray()
	for v in rgb_bytes:
		payload.append(_byte(v))
	var length := payload.size()
	var flags := FLAG_VER1_PUSH if push else (FLAG_VER1_PUSH & ~0x01)
	var pkt := PackedByteArray()
	pkt.append(flags)                     # 0: flags
	pkt.append(int(seq) & 0x0F)           # 1: sequence (low nibble)
	pkt.append(DATATYPE_RGB8)             # 2: data type
	pkt.append(DEST_DEFAULT)              # 3: destination id
	var off := int(offset)
	pkt.append((off >> 24) & 0xFF)        # 4: offset MSB (big-endian)
	pkt.append((off >> 16) & 0xFF)        # 5
	pkt.append((off >> 8) & 0xFF)         # 6
	pkt.append(off & 0xFF)                # 7: offset LSB
	pkt.append((length >> 8) & 0xFF)      # 8: length MSB (big-endian)
	pkt.append(length & 0xFF)             # 9: length LSB
	pkt.append_array(payload)             # 10+: RGB payload
	return pkt


## Send an RGB pixel list to the DDP host over UDP (the REAL wire). Lazily opens the socket. Returns a
## DECLARATIVE receipt (bytes-sent / packet — DATA, like every device.* op). Never throws: an
## unreachable host just drops the connectionless datagram (C-ideal).
func send(rgb_bytes: Array, offset: int = 0) -> Dictionary:
	_seq = (_seq % 15) + 1
	var pkt := build_packet(rgb_bytes, offset, _seq, true)
	var err := OK
	if _udp == null:
		_udp = PacketPeerUDP.new()
	# set_dest_address is idempotent-ish; re-set each send so host/port changes take effect.
	err = _udp.set_dest_address(host, port)
	if err == OK:
		err = _udp.put_packet(pkt)
	return {
		"ok": err == OK, "op": "device.pixel_send", "transport": "ddp",
		"host": host, "port": port, "offset": int(offset),
		"bytes": pkt.size(), "packet": pkt, "err": err,
	}


func close() -> void:
	if _udp != null:
		_udp.close()
		_udp = null


## Register this transport as an ADDITIVE host op: device.pixel_send{ host, port, pixels|value }. This
## does NOT touch device.set_led — it is a NEW op, so the existing set_led behaviour is preserved (N).
## A single shared instance backs the op so the socket + sequence counter persist across sends. Returns
## the op name registered. Pass a WorldActions CLASS (host-wide) or instance, mirroring device_actions.
static func register_ops(world_actions) -> String:
	if world_actions == null:
		return ""
	var sink := DdpTransport.new()
	var fn := func(args: Dictionary) -> Dictionary:
		return sink._op_pixel_send(args)
	# The CLASS itself => host-wide static seam; an instance => scoped register.
	if world_actions == WorldActions:
		WorldActions.register_host("device.pixel_send", fn)
	else:
		world_actions.register("device.pixel_send", fn)
	return "device.pixel_send"


## The device.pixel_send op body: read host/port + a pixel list (from `pixels`, or the wired `value`
## payload as [[r,g,b],...] or a flat byte array), send over DDP, return the receipt. Defensive: a
## missing/garbage pixel list sends an empty frame (no crash, C-ideal).
func _op_pixel_send(args: Dictionary) -> Dictionary:
	if args.has("host"):
		host = str(args.get("host"))
	if args.has("port"):
		port = int(_num(args.get("port")))
	var pixels = args.get("pixels", args.get("value", []))
	var flat := _flatten_pixels(pixels)
	var offset := int(_num(args.get("offset", 0)))
	return send(flat, offset)


## Coerce a pixel payload to a flat 0..255 RGB byte array. Accepts [[r,g,b],...] (0..1 or 0..255),
## a flat [r,g,b,r,g,b,...], or a { pixels:[...] } dict. Non-numeric entries fall to 0 (never crash).
static func _flatten_pixels(pixels) -> Array:
	var out: Array = []
	if typeof(pixels) == TYPE_DICTIONARY:
		pixels = pixels.get("pixels", [])
	if typeof(pixels) != TYPE_ARRAY:
		return out
	for p in pixels:
		if typeof(p) == TYPE_ARRAY:
			for c in p:
				out.append(_component_to_byte(c))
		else:
			out.append(_component_to_byte(p))
	return out


## A color component may be authored 0..1 (the substrate's linear convention) OR 0..255. Heuristic:
## a value in [0,1] scales to 0..255; a value > 1 is treated as already-8-bit. Clamped, floored.
static func _component_to_byte(c) -> int:
	var f := _num(c)
	if f <= 1.0 and f >= 0.0:
		f = f * 255.0
	return _byte(f)


static func _byte(v) -> int:
	var f := _num(v)
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
