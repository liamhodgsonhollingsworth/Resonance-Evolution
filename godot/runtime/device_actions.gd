extends RefCounted
## DeviceActions — the device.* OP FAMILY for the visi-sonor loop (Dreams-arc Slice 7).
##
## Visi-sonor is the canonical INSTANCE of the Sensor -> Logic -> Action interaction format: a camera
## (source) feeds a BRAIN (a Compare/Select/Logic arrangement) that drives IR / LED / projector output
## (the Action). This module is the ACTION half — the device.* op family a real host (a room of lights,
## an IR blaster, a projector) registers at boot so a wired arrangement can reach those effects.
##
## THE CONTRACT (inherited verbatim from WorldActions, runtime/world_actions.gd):
##   • Every op returns a DECLARATIVE receipt dict ({ ok:true, op:"device.set_led", r, g, b, addr, ... }),
##     exactly like WorldActions' own set_param. It does NOT drive real hardware IN-ENGINE — a real host
##     with the device honours the receipt (writes the LED, blasts the IR code); a host without it still
##     no-ops via WorldActions' existing "unknown op = declared no-op" path. The engine only ever produces
##     serialisable DATA; the physical effect lives at the host boundary. That is what lets the SAME
##     visi-sonor arrangement run on a game host (no lights -> silent no-op), a website, and a real room.
##   • OPT-IN by design. These ops are NOT baked into WorldActions._register_builtins — a host with no
##     hardware stays SILENT. A host that HAS the device calls register_device_ops(world_actions) at boot;
##     everything else keeps flowing through the unknown-op no-op. "add a world effect == register one op."
##
## THE OP SET (Slice 7 — the minimal device catalog; no auto-generalisation beyond the plan):
##   • device.set_led{r,g,b,addr}       — set one addressable LED / light to an RGB colour.
##   • device.ir_send{code,protocol}    — blast one IR remote code (protocol e.g. "nec"/"rc5").
##   • device.projector_output{...}     — hand a projector-output descriptor to a projector at the host.
##   • device.strobe{hz}                — set a strobe rate in Hz (0 = off).
##   • device.calibrate{target_id}      — request a calibration pass against a target device/surface.
##
## Portability: no Godot Node/scene types in the public surface — only Dictionaries + Strings + a plain
## Callable. A GDScript ≡ Python ≡ JS re-implementation only has to match each op's receipt dict shape.

const WorldActions := preload("res://runtime/world_actions.gd")


## Register the device.* op family onto a WorldActions op registry (the whole extension surface — a new
## world effect is one register() call, never an engine edit). `world_actions` is a WorldActions instance
## (or anything exposing register(op, fn)). Returns the sorted list of op names it registered, so a host /
## test can confirm the boot step ran. Idempotent: registering again just replaces with the same handlers.
##
## HOST-WIDE variant: register_device_ops(WorldActions) — passing the CLASS instead of an instance — routes
## through WorldActions' static host-op seam (register_host), so every fresh WorldActions a PrimWorldAction
## builds per-evaluate inherits the ops. That is the "a host registers its device.* at boot" model: the
## room boots once, and thereafter every WorldAction node in every arrangement honours device.set_led.
static func register_device_ops(world_actions) -> Array:
	if world_actions == null:
		return []
	# The CLASS itself (host-wide static seam) — the boot path a room takes so PrimWorldAction picks it up.
	if world_actions == WorldActions:
		WorldActions.register_host("device.set_led", _op_set_led)
		WorldActions.register_host("device.ir_send", _op_ir_send)
		WorldActions.register_host("device.projector_output", _op_projector_output)
		WorldActions.register_host("device.strobe", _op_strobe)
		WorldActions.register_host("device.calibrate", _op_calibrate)
	else:
		# A concrete instance (a test / a scoped registry): register directly onto it.
		world_actions.register("device.set_led", _op_set_led)
		world_actions.register("device.ir_send", _op_ir_send)
		world_actions.register("device.projector_output", _op_projector_output)
		world_actions.register("device.strobe", _op_strobe)
		world_actions.register("device.calibrate", _op_calibrate)
	return ["device.calibrate", "device.ir_send", "device.projector_output", "device.set_led", "device.strobe"]


## Un-register the device.* family from the host-wide static seam. Lets a host / test return to the
## "no hardware -> unknown op -> declared no-op" baseline (the universality half of the loop test). No-op
## on a host that never registered. Symmetric with register_device_ops so the boot step is reversible.
static func unregister_device_ops_host() -> void:
	for op in ["device.set_led", "device.ir_send", "device.projector_output", "device.strobe", "device.calibrate"]:
		WorldActions.unregister_host(op)


# --- the device.* ops ------------------------------------------------------------------------------
# Each returns a DECLARATIVE receipt. Args arrive merged (node params + wired inputs); we read the
# named keys, coerce to the right shape, and echo them back so a real host honours the receipt. str()
# (never String()) stringifies a Variant id/target — String() as a constructor throws on a bare number.

## device.set_led: set one addressable LED / light to an RGB colour. args: { r, g, b, addr }.
## Channels coerce to numbers (0..1 or 0..255 is the host's convention); addr is an integer LED index.
##
## PORTABILITY of the wire shape: a BRAIN commonly computes a COLOUR as one value and wires it into
## WorldAction's single `value` port (PrimWorldAction wires op/value/target/key, not r/g/b). So set_led
## ALSO reads r/g/b/addr from a wired `value` payload — either a { r, g, b, addr } dict or an [r,g,b(,addr)]
## array — with any explicit top-level r/g/b/addr arg overriding it. This keeps WorldAction node-not-edit:
## the mapped colour rides the existing `value` seam, no new WorldAction port.
static func _op_set_led(args: Dictionary) -> Dictionary:
	var payload = args.get("value", null)
	var pr = 0; var pg = 0; var pb = 0; var paddr = 0
	if typeof(payload) == TYPE_DICTIONARY:
		pr = payload.get("r", 0); pg = payload.get("g", 0)
		pb = payload.get("b", 0); paddr = payload.get("addr", 0)
	elif typeof(payload) == TYPE_ARRAY and payload.size() >= 3:
		pr = payload[0]; pg = payload[1]; pb = payload[2]
		paddr = payload[3] if payload.size() >= 4 else 0
	return {
		"ok": true, "op": "device.set_led",
		"r": _num(args.get("r", pr)), "g": _num(args.get("g", pg)), "b": _num(args.get("b", pb)),
		"addr": int(_num(args.get("addr", paddr))),
	}


## device.ir_send: blast one IR remote code. args: { code, protocol }. code is the raw remote code
## (kept as a number when numeric, else its string form); protocol names the encoding ("nec"/"rc5"/...).
static func _op_ir_send(args: Dictionary) -> Dictionary:
	var code = args.get("code", null)
	return {
		"ok": true, "op": "device.ir_send",
		"code": code if typeof(code) == TYPE_INT or typeof(code) == TYPE_FLOAT else str(code),
		"protocol": str(args.get("protocol", "nec")),
	}


## device.projector_output: hand a projector-output descriptor to a projector at the host. args are
## pass-through (a source id / a texture handle / a transform) — echoed verbatim so the host projector
## honours whatever shape the arrangement authored. Keeps the op open to the projection-map family.
static func _op_projector_output(args: Dictionary) -> Dictionary:
	var receipt := { "ok": true, "op": "device.projector_output" }
	for k in args.keys():
		receipt[str(k)] = args[k]
	return receipt


## device.strobe: set a strobe rate in Hz. args: { hz }. hz <= 0 means "off". A host honours the rate;
## the engine only emits the requested Hz as data.
static func _op_strobe(args: Dictionary) -> Dictionary:
	var hz := _num(args.get("hz", 0))
	return { "ok": true, "op": "device.strobe", "hz": hz, "on": hz > 0.0 }


## device.calibrate: request a calibration pass against a target device / surface. args: { target_id }.
## Declarative: a real host runs its calibration; the engine emits the request receipt.
static func _op_calibrate(args: Dictionary) -> Dictionary:
	return { "ok": true, "op": "device.calibrate", "target_id": str(args.get("target_id", "")) }


# --- helpers ---------------------------------------------------------------------------------------

## Coerce a wired Variant (int/float/bool/string/null) to a float, defensively — malformed op args must
## no-op GRACEFULLY (never crash). A non-numeric string / null / dict falls to 0.0 rather than throwing.
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
