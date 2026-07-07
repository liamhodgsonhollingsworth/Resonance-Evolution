extends RefCounted
class_name SacnTransport
## SacnTransport — a DECLARED-NO-OP stub sink for the sACN / E1.31 (streaming-DMX-over-IP) protocol.
## (Visi-sonor arc, Wave 3A.)
##
## Exactly ONE real transport is wired in Wave 3A (WLED/DDP over UDP). sACN is registered as a DECLARED
## NO-OP: the op exists so an arrangement authored for an sACN host still runs, but it returns a data
## receipt with noop:true rather than opening a multicast socket. Wiring real sACN (E1.31 root/framing/
## DMP layers, universe multicast 239.255.x.x:5568) is a FUTURE slice against this SAME seam — never an
## edit to any existing op (N-ideal). Mirrors WorldActions' "unknown op = declared no-op" keystone.

## Register `device.sacn_send` as a DECLARED-NO-OP host op. Returns the op name.
static func register_ops(world_actions) -> String:
	if world_actions == null:
		return ""
	if world_actions == WorldActions:
		WorldActions.register_host("device.sacn_send", _op_sacn_send)
	else:
		world_actions.register("device.sacn_send", _op_sacn_send)
	return "device.sacn_send"


## The declared-no-op body: echo a receipt marked noop:true. A real host swaps this for an E1.31
## multicast send in a later slice; until then it harmlessly no-ops (C-ideal).
static func _op_sacn_send(args: Dictionary) -> Dictionary:
	return {
		"ok": true, "op": "device.sacn_send", "transport": "sacn",
		"noop": true, "reason": "sacn/E1.31 transport is a declared no-op stub (WLED/DDP is the wired one)",
		"universe": int(args.get("universe", 1)),
	}

const WorldActions := preload("res://runtime/world_actions.gd")
