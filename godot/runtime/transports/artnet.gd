extends RefCounted
class_name ArtnetTransport
## ArtnetTransport — a DECLARED-NO-OP stub sink for the Art-Net DMX-over-Ethernet protocol.
## (Visi-sonor arc, Wave 3A.)
##
## Per the no-auto-generalization rule, exactly ONE real transport is wired in Wave 3A (WLED/DDP over
## UDP). Art-Net is registered as a DECLARED NO-OP: the op exists (so an arrangement authored for an
## Art-Net host still runs), but it produces a data receipt with noop:true rather than driving any
## socket. Wiring the real Art-Net packet (UDP 6454, "Art-Net\0" header + OpDmx + a 512-ch universe)
## is a FUTURE slice against this SAME seam — a new arrangement / a filled-in send(), never an edit
## to any existing op (N-ideal). This mirrors WorldActions' "unknown op = declared no-op" keystone.

## Register `device.artnet_send` as a DECLARED-NO-OP host op. Returns the op name.
static func register_ops(world_actions) -> String:
	if world_actions == null:
		return ""
	if world_actions == WorldActions:
		WorldActions.register_host("device.artnet_send", _op_artnet_send)
	else:
		world_actions.register("device.artnet_send", _op_artnet_send)
	return "device.artnet_send"


## The declared-no-op body: echo a receipt marked noop:true. A real host swaps this for a UDP send in a
## later slice; until then the op harmlessly no-ops so the same arrangement runs everywhere (C-ideal).
static func _op_artnet_send(args: Dictionary) -> Dictionary:
	return {
		"ok": true, "op": "device.artnet_send", "transport": "artnet",
		"noop": true, "reason": "artnet transport is a declared no-op stub (WLED/DDP is the wired one)",
		"universe": int(args.get("universe", 0)),
	}

const WorldActions := preload("res://runtime/world_actions.gd")
