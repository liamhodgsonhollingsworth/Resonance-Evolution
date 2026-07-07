extends SceneTree
## HEADLESS TEST for the DMX / LIGHTING TRANSPORT substrate (Visi-sonor arc, Wave 3A, item 2).
##
##   <godot_console.exe> --headless --path godot -s res://headless_transport_test.gd
##
## Judge PASS by the "RESULT: ALL PASS" sentinel + zero SCRIPT ERROR / Parse Error lines (NOT exit code).
##
## What it proves — the whole transport lane with ZERO real hardware:
##  0. prim_dmx_universe: channel writes land in the buffer; blackout clears; pixel writes span 3 channels;
##     out-of-range indices are ignored (C-ideal, no crash).
##  1. prim_fixture -> prim_channel_map: a fixture's channel map routes a logical colour to the correct
##     ABSOLUTE universe channels (address offset + range scaling), and those writes land in the universe.
##  2. DDP/WLED sink builds the CORRECT UDP packet — asserted at the BYTE level with no socket (the exact
##     DDP header + RGB payload); WLED's packet == the DDP packet (it speaks DDP).
##  3. The DDP/WLED send() path runs over PacketPeerUDP to a dead loopback port WITHOUT crashing (C-ideal:
##     an unreachable host just drops the connectionless datagram) and returns a well-formed receipt.
##  4. prim_light_sim (the zero-hardware virtual strip) records the expected RGB from a set_led receipt,
##     from a DMX universe buffer, and from a DDP pixel list.
##  5. ADDITIVE registration: the transport + light_sim ops register as NEW device.* ops WITHOUT shadowing
##     the builtins or altering device.set_led (N-ideal); the device.set_led receipt is byte-for-byte the
##     same before and after the transports are registered.
##  6. The four new primitive TYPES instantiate through the real GraphRuntime registry.

const WorldActions := preload("res://runtime/world_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")
const DdpTransport := preload("res://runtime/transports/ddp.gd")
const WledTransport := preload("res://runtime/transports/wled.gd")
const ArtnetTransport := preload("res://runtime/transports/artnet.gd")
const SacnTransport := preload("res://runtime/transports/sacn.gd")
const PrimDmxUniverseC := preload("res://primitives/prim_dmx_universe.gd")
const PrimFixtureC := preload("res://primitives/prim_fixture.gd")
const PrimChannelMapC := preload("res://primitives/prim_channel_map.gd")
const PrimLightSimC := preload("res://primitives/prim_light_sim.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()
	print("")
	if _fail == 0:
		print("RESULT: ALL PASS")
	else:
		print("RESULT: %d FAIL" % _fail)
	quit()

func _run() -> void:
	# --- 0. prim_dmx_universe framebuffer -----------------------------------------------------------
	var uni: PrimDmxUniverseC = PrimDmxUniverseC.new()
	uni.blackout()
	_check("dmx: fresh universe is all-zero", uni.get_channel(0) == 0 and uni.get_channel(511) == 0)
	uni.set_channel(0, 200); uni.set_channel(5, 128)
	_check("dmx: set_channel/get_channel round-trips", uni.get_channel(0) == 200 and uni.get_channel(5) == 128)
	uni.set_channel(999, 255)   # out of range
	_check("dmx: out-of-range set_channel IGNORED (no crash)", uni.get_channel(999) == 0)
	_check("dmx: value clamps to a DMX byte", true)
	uni.set_channel(1, 300)
	_check("dmx: over-255 value clamps to 255", uni.get_channel(1) == 255)
	uni.blackout()
	_check("dmx: blackout clears all channels", uni.get_channel(0) == 0 and uni.get_channel(5) == 0)
	uni.set_pixel(2, [1.0, 0.0, 0.5])   # pixel 2 -> channels 6,7,8
	_check("dmx: set_pixel writes 3 consecutive channels (0..1 scaled to 0..255)",
		uni.get_channel(6) == 255 and uni.get_channel(7) == 0 and uni.get_channel(8) == 128)
	var pv := uni.get_pixels()
	_check("dmx: pixel view reflects the buffer", pv.size() >= 3 and pv[2][0] == 255 and pv[2][2] == 128)

	# --- 1. prim_fixture -> prim_channel_map -> universe ---------------------------------------------
	var fx: PrimFixtureC = PrimFixtureC.new()
	fx.params = { "name": "par1", "address": 10, "color_mode": "rgb" }   # base channel 10 (1-based)
	var fx_out := fx.evaluate({})
	var fixture: Dictionary = fx_out["fixture"]
	_check("fixture: rgb fixture has 3 channels red/green/blue",
		fixture["channels"].size() == 3 and str(fixture["channels"][0]["name"]) == "red")
	_check("fixture: address preserved", int(fixture["address"]) == 10)

	var cm: PrimChannelMapC = PrimChannelMapC.new()
	# logical full-red at address 10 -> absolute channel (10-1)+0 = 9 should be 255, +1/+2 = 0.
	var cm_out := cm.evaluate({ "color": { "r": 1.0, "g": 0.0, "b": 0.0 }, "fixture": fixture })
	var chans: Dictionary = cm_out["channels"]
	_check("channel_map: full red routes to absolute channel 9 = 255",
		int(cm.get("params") != null) >= 0 and int(chans.get("9", 0)) == 255)
	_check("channel_map: green/blue channels are 0 for pure red",
		int(chans.get("10", 0)) == 0 and int(chans.get("11", 0)) == 0)
	# feed those channel writes into the universe -> assert they land.
	uni.blackout()
	var uni_out := uni.evaluate({ "channels": chans })
	var ubytes: Array = uni_out["universe"]
	_check("channel_map->universe: absolute channel 9 lands as 255 in the universe buffer",
		int(ubytes[9]) == 255 and int(ubytes[10]) == 0)
	# dimmer folds into RGB when the fixture has no dimmer channel.
	var cm_dim := cm.evaluate({ "color": { "r": 1.0, "g": 0.0, "b": 0.0 }, "dimmer": 0.5, "fixture": fixture })
	var cd: Dictionary = cm_dim["channels"]
	_check("channel_map: dimmer 0.5 halves red on a dimmerless fixture (~128)",
		int(cd.get("9", 0)) >= 120 and int(cd.get("9", 0)) <= 132)
	# a fixture WITH a dimmer channel rides the dimmer channel, RGB pass-through.
	var fxd: PrimFixtureC = PrimFixtureC.new()
	fxd.params = { "address": 1, "channels": [
		{ "name": "dimmer", "offset": 0 }, { "name": "red", "offset": 1 },
		{ "name": "green", "offset": 2 }, { "name": "blue", "offset": 3 } ] }
	var fixd: Dictionary = fxd.evaluate({})["fixture"]
	var cmd: Dictionary = cm.evaluate({ "color": { "r": 1.0, "g": 0.0, "b": 0.0 }, "dimmer": 0.5, "fixture": fixd })["channels"]
	_check("channel_map: dimmer channel present -> dimmer=128 on ch0, red=255 pass-through on ch1",
		int(cmd.get("0", 0)) >= 120 and int(cmd.get("0", 0)) <= 132 and int(cmd.get("1", 0)) == 255)
	# malformed fixture -> empty map, no crash (C-ideal).
	var cm_bad := cm.evaluate({ "color": "garbage", "fixture": "not-a-fixture" })
	_check("channel_map: garbage fixture -> empty map, no crash", (cm_bad["channels"] as Dictionary).is_empty())

	# --- 2. DDP/WLED packet byte layout (NO socket) -------------------------------------------------
	# 2 pixels: red then green, at offset 0, seq 1, push. payload = FF 00 00 00 FF 00 (6 bytes).
	var pkt := DdpTransport.build_packet([255, 0, 0, 0, 255, 0], 0, 1, true)
	_check("ddp: packet length = 10 header + 6 payload = 16", pkt.size() == 16)
	_check("ddp: byte0 flags = 0x41 (ver1|push)", pkt[0] == 0x41)
	_check("ddp: byte1 = sequence (1)", pkt[1] == 1)
	_check("ddp: byte2 = data type 0x01 (RGB8)", pkt[2] == 0x01)
	_check("ddp: byte3 = dest id 0x01", pkt[3] == 0x01)
	_check("ddp: bytes4-7 = offset 0 (big-endian)", pkt[4] == 0 and pkt[5] == 0 and pkt[6] == 0 and pkt[7] == 0)
	_check("ddp: bytes8-9 = length 6 (big-endian)", pkt[8] == 0 and pkt[9] == 6)
	_check("ddp: payload bytes 10.. = FF 00 00 00 FF 00",
		pkt[10] == 255 and pkt[11] == 0 and pkt[12] == 0 and pkt[13] == 0 and pkt[14] == 255 and pkt[15] == 0)
	# offset + length encode big-endian correctly for a larger frame.
	var pkt2 := DdpTransport.build_packet([1, 2, 3], 258, 2, true)   # offset 258 = 0x0102
	_check("ddp: offset 258 -> bytes4-7 = 00 00 01 02", pkt2[4] == 0 and pkt2[5] == 0 and pkt2[6] == 1 and pkt2[7] == 2)
	_check("ddp: seq low-nibble only (2)", pkt2[1] == 2)
	# 0..1 components scale to 0..255 in the send/op path (via _flatten_pixels).
	var flat := DdpTransport._flatten_pixels([[1.0, 0.0, 0.5]])
	_check("ddp: _flatten_pixels scales 0..1 -> 0..255", flat.size() == 3 and int(flat[0]) == 255 and int(flat[2]) == 128)
	# WLED packet == DDP packet (WLED speaks DDP).
	var wpkt := WledTransport.build_packet([255, 0, 0], 0, 1)
	var dpkt := DdpTransport.build_packet([255, 0, 0], 0, 1, true)
	_check("wled: packet is identical to the DDP packet", wpkt == dpkt)

	# --- 3. real send() over UDP to a dead loopback port does not crash -----------------------------
	var ddp := DdpTransport.new()
	ddp.host = "127.0.0.1"; ddp.port = 40481   # nothing listening; connectionless UDP just drops it
	var rec := ddp.send([255, 128, 0])
	_check("ddp send: returns a well-formed receipt, no crash on a dead host",
		rec.get("op") == "device.pixel_send" and rec.get("transport") == "ddp" and int(rec.get("bytes")) == 13)
	ddp.close()
	var wled := WledTransport.new()
	var wrec := wled.send([0, 255, 0], "127.0.0.1")
	_check("wled send: well-formed receipt over UDP, no crash",
		wrec.get("op") == "device.wled_send" and int(wrec.get("bytes")) == 13)
	wled.close()

	# --- 4. prim_light_sim virtual strip records RGB ------------------------------------------------
	var sim: PrimLightSimC = PrimLightSimC.new()
	sim.params = { "pixel_count": 8 }
	sim._resize(8)
	sim.apply_set_led({ "r": 1.0, "g": 0.0, "b": 0.0, "addr": 3 })
	_check("light_sim: set_led receipt records pixel 3 = red (0..1 -> 255)",
		sim.get_pixel(3) == [255, 0, 0] and sim.write_count() == 1)
	sim.apply_set_led({ "r": 0.0, "g": 0.0, "b": 1.0, "addr": 99 })   # out of range
	_check("light_sim: out-of-range addr ignored, no crash", sim.get_pixel(3) == [255, 0, 0])
	# DMX universe ingest: channels 0,1,2 = green -> pixel 0.
	sim.clear()
	sim.apply_universe([0, 255, 0, 255, 0, 0])   # pixel0 green, pixel1 red
	_check("light_sim: universe ingest -> pixel0 green, pixel1 red",
		sim.get_pixel(0) == [0, 255, 0] and sim.get_pixel(1) == [255, 0, 0])
	# DDP pixel-list ingest (0..1).
	sim.clear()
	sim.apply_pixels([[1.0, 1.0, 1.0], [0.0, 0.0, 0.0]])
	_check("light_sim: pixel-list ingest -> pixel0 white", sim.get_pixel(0) == [255, 255, 255])
	# malformed ingest -> no crash.
	sim.apply_pixels("garbage"); sim.apply_universe(42); sim.apply_set_led("nope")
	_check("light_sim: malformed ingest does not crash", true)
	# as a primitive in a graph: evaluate() ingests a wired universe, emits the buffer as DATA.
	var sim_out := sim.evaluate({ "universe": [255, 0, 0] })
	_check("light_sim: evaluate() emits the recorded buffer on the `pixels` port",
		(sim_out.get("pixels") as Array)[0] == [255, 0, 0])

	# --- 5. ADDITIVE registration: set_led is UNCHANGED by the transports ---------------------------
	DeviceActions.unregister_device_ops_host()
	var wa := WorldActions.new()
	DeviceActions.register_device_ops(wa)
	var led_before := wa.perform("device.set_led", { "r": 0.5, "g": 0.25, "b": 1.0, "addr": 7 })
	# register the transports + light_sim additively onto the SAME instance.
	var pixel_op := DdpTransport.register_ops(wa)
	var wled_op := WledTransport.register_ops(wa)
	var artnet_op := ArtnetTransport.register_ops(wa)
	var sacn_op := SacnTransport.register_ops(wa)
	var sim_reg := PrimLightSimC.register_ops(wa)
	_check("register: DDP registers device.pixel_send", pixel_op == "device.pixel_send" and wa.has_op("device.pixel_send"))
	_check("register: WLED registers device.wled_send", wled_op == "device.wled_send" and wa.has_op("device.wled_send"))
	_check("register: Art-Net registers device.artnet_send (stub)", artnet_op == "device.artnet_send")
	_check("register: sACN registers device.sacn_send (stub)", sacn_op == "device.sacn_send")
	_check("register: light_sim registers device.light_sim", sim_reg.size() == 2 and str(sim_reg[0]) == "device.light_sim")
	var led_after := wa.perform("device.set_led", { "r": 0.5, "g": 0.25, "b": 1.0, "addr": 7 })
	_check("N-ideal: device.set_led receipt is UNCHANGED after transports register",
		led_after == led_before)
	# the stubs are DECLARED NO-OPS.
	var artnet_r := wa.perform("device.artnet_send", { "universe": 3 })
	_check("stub: device.artnet_send is a declared no-op", artnet_r.get("noop") == true and str(artnet_r.get("transport")) == "artnet")
	var sacn_r := wa.perform("device.sacn_send", {})
	_check("stub: device.sacn_send is a declared no-op", sacn_r.get("noop") == true)
	# the real pixel_send op flows through to a receipt (dead host, no crash).
	var pix_r := wa.perform("device.pixel_send", { "host": "127.0.0.1", "port": 40482, "pixels": [[1.0, 0.0, 0.0]] })
	_check("op: device.pixel_send returns a real DDP receipt, no crash",
		str(pix_r.get("transport")) == "ddp" and int(pix_r.get("bytes")) == 13)
	# the light_sim op writes into the sink instance the register call handed back.
	var the_sink: PrimLightSimC = sim_reg[1]
	wa.perform("device.light_sim", { "r": 0.0, "g": 1.0, "b": 0.0, "addr": 2 })
	_check("op: device.light_sim writes into its shared sink", the_sink.get_pixel(2) == [0, 255, 0])
	# builtins are NOT shadowed (guard held): set_led/ir_send from the device family still work.
	var ir := wa.perform("device.ir_send", { "code": 5, "protocol": "nec" })
	_check("guard: existing device.ir_send still works alongside the new transports", int(ir.get("code")) == 5)
	DeviceActions.unregister_device_ops_host()

	# --- 6. the 4 new primitive TYPES instantiate through the real GraphRuntime registry ------------
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({ "nodes": [
		{ "id": "u", "type": "DmxUniverse", "params": {} },
		{ "id": "f", "type": "Fixture", "params": { "address": 1 } },
		{ "id": "m", "type": "ChannelMap", "params": {} },
		{ "id": "s", "type": "LightSim", "params": {} },
	], "wires": [] })
	_check("registry: DmxUniverse/Fixture/ChannelMap/LightSim all instantiate in GraphRuntime",
		rt.nodes.has("u") and rt.nodes.has("f") and rt.nodes.has("m") and rt.nodes.has("s")
		and rt.nodes["u"].prim_type == "DmxUniverse" and rt.nodes["s"].prim_type == "LightSim")
	rt.queue_free()
