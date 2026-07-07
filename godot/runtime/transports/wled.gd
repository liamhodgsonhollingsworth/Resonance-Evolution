extends RefCounted
class_name WledTransport
## WledTransport — a REAL lighting transport SINK for WLED controllers. (Visi-sonor arc, Wave 3A.)
##
## WLED accepts DDP (Distributed Display Protocol) pixel streaming natively on UDP port 4048. So the
## WLED sink is a THIN ADAPTER over DdpTransport (wrap-don't-rebuild, R-ideal): it is a named front
## that a host wires as `device.wled_send{ host, pixels }`, delegating the actual bytes to DDP. This
## keeps ONE real wire protocol (DDP-over-UDP) and lets both `device.wled_send` and `device.pixel_send`
## drive the same strip.
##
## IDEALS: T — build_packet is the pure DDP packet (asserted headless, no hardware). C — an unreachable
## WLED controller drops the connectionless UDP datagram, no crash. N — a NEW host op, set_led untouched.

const DdpTransport := preload("res://runtime/transports/ddp.gd")
const WLED_DDP_PORT := 4048   # WLED's native DDP listener

var _ddp: DdpTransport = null


func _init() -> void:
	_ddp = DdpTransport.new()
	_ddp.port = WLED_DDP_PORT


## The pure WLED wire packet == a DDP packet (WLED speaks DDP). Exposed so a headless test asserts the
## exact byte layout the controller will receive, with zero hardware.
static func build_packet(rgb_bytes: Array, offset: int = 0, seq: int = 1) -> PackedByteArray:
	return DdpTransport.build_packet(rgb_bytes, offset, seq, true)


## Send a pixel list to a WLED controller over its native DDP listener. Returns a DECLARATIVE receipt
## (DATA). Never throws (C-ideal).
func send(rgb_bytes: Array, host: String = "", offset: int = 0) -> Dictionary:
	if host != "":
		_ddp.host = host
	_ddp.port = WLED_DDP_PORT
	var receipt := _ddp.send(rgb_bytes, offset)
	receipt["op"] = "device.wled_send"
	receipt["transport"] = "wled"
	return receipt


func close() -> void:
	_ddp.close()


## Register `device.wled_send{ host, pixels|value, offset? }` as an ADDITIVE host op — set_led untouched
## (N-ideal). A shared instance backs the op so the socket + sequence persist. Returns the op name.
static func register_ops(world_actions) -> String:
	if world_actions == null:
		return ""
	var sink := WledTransport.new()
	var fn := func(args: Dictionary) -> Dictionary:
		return sink._op_wled_send(args)
	if world_actions == WorldActions:
		WorldActions.register_host("device.wled_send", fn)
	else:
		world_actions.register("device.wled_send", fn)
	return "device.wled_send"


func _op_wled_send(args: Dictionary) -> Dictionary:
	var host := str(args.get("host", _ddp.host)) if args.has("host") else _ddp.host
	var pixels = args.get("pixels", args.get("value", []))
	var flat := DdpTransport._flatten_pixels(pixels)
	var offset := int(DdpTransport._num(args.get("offset", 0)))
	return send(flat, host, offset)

const WorldActions := preload("res://runtime/world_actions.gd")
