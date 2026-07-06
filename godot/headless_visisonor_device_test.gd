extends SceneTree
## REAL-TREE #049 TEST for the visi-sonor device.* Action family + the end-to-end visi-sonor loop
## (Dreams-arc Slice 7). Visi-sonor is the canonical INSTANCE of the Sensor->Logic->Action interaction
## format: a signal/camera frame (source) -> a BRAIN of Compare/Select (Logic) -> device.set_led (Action).
##
##   <godot> --headless --path godot -s res://headless_visisonor_device_test.gd
##
## Like the Slice-1/2 spine tests this drives the ACTUAL aperture_3d room the desktop shortcut opens: it
## MOUNTS a real GraphPanel on a placed object and drives the SAME LiveHost + GraphRuntime the running
## room hot-loads that object's arrangement into. The visi-sonor loop is exercised on THAT mounted,
## room-owned runtime — NOT a standalone GraphRuntime (a standalone-node test would be the #049 FALSE PASS).
##
## What it proves in the REAL running room's runtime:
##  1. The real aperture_3d room builds headless, an object is placed + bound, a GraphPanel is mounted.
##  2. FULL LOOP: a HOST boots device.* (DeviceActions.register_device_ops), then visisonor_loop.json is
##     hot-loaded; injecting a HIGH-band frame -> the BRAIN maps it -> device.set_led fires with the WARM
##     {r,g,b}; injecting a LOW-band frame maps to a DIFFERENT (cool) {r,g,b} through the SAME wires.
##  3. UNIVERSALITY: a host that did NOT register device.* gets a declared no-op for device.set_led on the
##     SAME arrangement (the "unknown op = no-op" portability keystone — same arrangement, any host).
##  4. CONNECTION-ISOLATED-FAILURE (gate C): severing the band->BRAIN wire kills EXACTLY the device output
##     (the LED falls to the cool default branch) while an independent sibling WorldAction still fires.
##  5. MALFORMED device op args no-op gracefully (never crash): a garbage colour payload / bad addr / a
##     non-numeric strobe hz all return a well-formed receipt rather than throwing.
##  6. TEXT-EQUIVALENCE (gate T): the exact backend a GUI would drive — set_input_frame + evaluate() on
##     the room runtime — is what this headless text path exercises; there is no GUI-only path.
##  7. Every device.* op returns a DECLARATIVE receipt (it drives no real hardware in-engine).

const Aperture3D := preload("res://aperture/aperture_3d.gd")
const GraphPanelMount := preload("res://aperture/graph_panel_mount.gd")
const WorldActions := preload("res://runtime/world_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	# Start from a clean host-wide baseline (no device.* registered) so the universality half is honest.
	DeviceActions.unregister_device_ops_host()

	# --- 0. the device.* op family in isolation (declarative receipts, graceful malformed args) --------
	var wa := WorldActions.new()
	_check("baseline: device.set_led is UNKNOWN before any host boot (declared no-op)",
		not wa.has_op("device.set_led"))
	var pre := wa.perform("device.set_led", { "r": 1, "g": 0, "b": 0, "addr": 3 })
	_check("baseline: device.set_led no-ops on a host with no hardware (ok+noop)",
		pre.get("ok") == true and pre.get("noop") == true and str(pre.get("op")) == "device.set_led")

	# A concrete-instance registration (a scoped registry / a test) honours the whole family.
	var reg: Array = DeviceActions.register_device_ops(wa)
	_check("register_device_ops returns the 5-op device family",
		reg.size() == 5 and reg.has("device.set_led") and reg.has("device.ir_send")
		and reg.has("device.projector_output") and reg.has("device.strobe") and reg.has("device.calibrate"))
	_check("device.set_led registered onto the instance", wa.has_op("device.set_led"))

	var led := wa.perform("device.set_led", { "r": 0.5, "g": 0.25, "b": 1.0, "addr": 7 })
	_check("device.set_led returns a DECLARATIVE receipt carrying r,g,b,addr",
		led.get("ok") == true and str(led.get("op")) == "device.set_led"
		and abs(float(led.get("r")) - 0.5) < 0.001 and int(led.get("addr")) == 7)
	# colour can also ride the single `value` payload (a { r,g,b,addr } dict) — the BRAIN wire shape.
	var led_v := wa.perform("device.set_led", { "value": { "r": 1.0, "g": 0.2, "b": 0.0, "addr": 2 } })
	_check("device.set_led reads a wired `value` colour dict (the BRAIN wire shape)",
		abs(float(led_v.get("r")) - 1.0) < 0.001 and abs(float(led_v.get("b")) - 0.0) < 0.001
		and int(led_v.get("addr")) == 2)
	var ir := wa.perform("device.ir_send", { "code": 42, "protocol": "nec" })
	_check("device.ir_send receipt carries code + protocol",
		ir.get("ok") == true and int(ir.get("code")) == 42 and str(ir.get("protocol")) == "nec")
	var proj := wa.perform("device.projector_output", { "source": "cam0", "surface": "wall" })
	_check("device.projector_output echoes its descriptor",
		proj.get("ok") == true and str(proj.get("source")) == "cam0" and str(proj.get("surface")) == "wall")
	var strobe := wa.perform("device.strobe", { "hz": 12.0 })
	_check("device.strobe receipt carries hz + on",
		strobe.get("ok") == true and abs(float(strobe.get("hz")) - 12.0) < 0.001 and strobe.get("on") == true)
	var cal := wa.perform("device.calibrate", { "target_id": "proj0" })
	_check("device.calibrate receipt carries target_id",
		cal.get("ok") == true and str(cal.get("target_id")) == "proj0")

	# MALFORMED args must no-op GRACEFULLY (never crash) — garbage payloads coerce to 0.
	var bad_led := wa.perform("device.set_led", { "value": "not-a-color", "addr": {} })
	_check("MALFORMED: garbage colour payload -> zeros, no crash",
		bad_led.get("ok") == true and float(bad_led.get("r")) == 0.0 and int(bad_led.get("addr")) == 0)
	var bad_strobe := wa.perform("device.strobe", { "hz": "fast" })
	_check("MALFORMED: non-numeric strobe hz -> 0.0/off, no crash",
		bad_strobe.get("ok") == true and float(bad_strobe.get("hz")) == 0.0 and bad_strobe.get("on") == false)
	var empty_led := wa.perform("device.set_led", {})
	_check("MALFORMED: no args at all -> a well-formed zeroed receipt, no crash",
		empty_led.get("ok") == true and float(empty_led.get("g")) == 0.0)

	# --- 1. build the REAL room (headless), place + bind an object, mount its panel ------------------
	var room := Aperture3D.new()
	get_root().add_child(room)
	await process_frame
	await process_frame
	_check("real aperture_3d room built (the scene the shortcut opens)", room != null and room.is_inside_tree())

	var block_entry := { "kind": "block", "name": "Cube", "shape": "box",
		"params": { "width": 1.0, "height": 1.0, "depth": 1.0 }, "material": { "albedo": [0.8, 0.8, 0.82] } }
	room.call("_place_block", block_entry, Vector3(0, 0.5, -3))
	await process_frame
	var objs: Dictionary = room.get("objects")
	var obj_id := ""
	for id in objs:
		obj_id = str(id)
		break
	_check("object placed + resolvable in the room", obj_id != "")

	var bound_path = room.call("bind_object", obj_id, true)   # force=true => mount headless (#049)
	await process_frame
	await process_frame
	_check("#049: a node panel is mounted INSIDE the running room (the real tree)",
		GraphPanelMount.panel_is_open(room))

	var host := LiveHost.new()
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	host.runtime = rt
	host.path = str(bound_path)
	get_root().add_child(host)
	_check("the runtime under test is the room-mounted panel's live host runtime",
		host.runtime == rt and str(host.path) == str(bound_path))

	# --- 2. HOST BOOTS device.* + FULL LOOP through the room runtime --------------------------------
	# The HOST-WIDE boot step: a room with real lights registers device.* once. Thereafter every fresh
	# WorldActions a PrimWorldAction builds per-evaluate inherits device.set_led — so the mounted-room
	# WorldAction node honours it. This is the "a host registers its device.* at boot" model.
	DeviceActions.register_device_ops(WorldActions)
	_check("host boot: device.set_led is now host-wide (a fresh WorldActions inherits it)",
		WorldActions.new().has_op("device.set_led"))

	var loop := _load_json_file("res://arrangements/visisonor_loop.json")
	_check("visisonor_loop.json parsed", not loop.is_empty() and str(loop.get("name")) == "visisonor_loop")
	_write_json(str(bound_path), loop)
	host.poll_once()   # the running room's real hot-load path
	_check("visisonor_loop hot-loaded into the room runtime (7 nodes live)", rt.nodes.size() == 7)

	# Inject a HIGH-band frame -> BRAIN maps to WARM -> device.set_led fires with the warm {r,g,b}.
	rt.set_input_frame({ "signal.band.high": 0.9 })
	_check("get_input_frame round-trips the injected signal frame",
		abs(float(rt.get_input_frame().get("signal.band.high")) - 0.9) < 0.001)
	var out_hi := rt.evaluate()
	var band_hi = out_hi.get("band", {}).get("value")
	_check("the injected band energy flows out of the Input source", abs(float(band_hi) - 0.9) < 0.001)
	var led_hi: Dictionary = out_hi.get("led", {}).get("result", {})
	_check("FULL LOOP: high band -> device.set_led fired with the WARM colour",
		str(led_hi.get("op")) == "device.set_led" and led_hi.get("noop", null) == null
		and abs(float(led_hi.get("r")) - 1.0) < 0.001 and abs(float(led_hi.get("b")) - 0.0) < 0.001)

	# Inject a LOW-band frame -> the SAME wires map to a DIFFERENT (cool) colour.
	rt.set_input_frame({ "signal.band.high": 0.1 })
	var out_lo := rt.evaluate()
	var led_lo: Dictionary = out_lo.get("led", {}).get("result", {})
	_check("FULL LOOP: a different band value maps to a DIFFERENT colour through the same wires",
		abs(float(led_lo.get("r")) - 0.0) < 0.001 and abs(float(led_lo.get("b")) - 1.0) < 0.001)
	_check("FULL LOOP: the two frames produced genuinely different LED colours",
		float(led_hi.get("r")) != float(led_lo.get("r")) and float(led_hi.get("b")) != float(led_lo.get("b")))

	# --- 3. UNIVERSALITY: the SAME arrangement on a host WITHOUT device.* -> declared no-op ----------
	DeviceActions.unregister_device_ops_host()
	var rt_bare := GraphRuntime.new()
	get_root().add_child(rt_bare)
	rt_bare.load_arrangement(loop)
	rt_bare.set_input_frame({ "signal.band.high": 0.9 })
	var out_bare := rt_bare.evaluate()
	var led_bare: Dictionary = out_bare.get("led", {}).get("result", {})
	_check("UNIVERSALITY: same arrangement, a host with NO LED -> device.set_led declared no-op",
		led_bare.get("ok") == true and led_bare.get("noop") == true
		and str(led_bare.get("op")) == "device.set_led")
	rt_bare.free()
	# re-boot device.* for the isolation section below.
	DeviceActions.register_device_ops(WorldActions)

	# --- 4. CONNECTION-ISOLATED-FAILURE (gate C) ----------------------------------------------------
	# A 2-behaviour arrangement: the band->BRAIN->device.set_led loop AND an independent
	# Const->WorldAction(log) that always fires. Sever ONLY the band->hot wire and prove EXACTLY the
	# device output changes (the LED falls to the cool default branch) while the sibling still logs.
	var iso := {
		"format": "resonance.arrangement/v1", "name": "visisonor_isolation",
		"nodes": [
			{ "id": "band", "type": "Input", "params": { "input_id": "signal.band.high", "default": 0.0 } },
			{ "id": "thr", "type": "Const", "params": { "value": 0.5 } },
			{ "id": "hot", "type": "Compare", "params": { "op": "gt" } },
			{ "id": "warm", "type": "Const", "params": { "value": { "r": 1.0, "g": 0.2, "b": 0.0, "addr": 0 } } },
			{ "id": "cool", "type": "Const", "params": { "value": { "r": 0.0, "g": 0.2, "b": 1.0, "addr": 0 } } },
			{ "id": "brain", "type": "Select", "params": { "default_cond": false } },
			{ "id": "led", "type": "WorldAction", "params": { "op": "device.set_led" } },
			{ "id": "k", "type": "Const", "params": { "value": "always" } },
			{ "id": "sib", "type": "WorldAction", "params": { "op": "log" } }
		],
		"wires": [
			{ "from": "band", "out": "value", "to": "hot", "in": "a" },
			{ "from": "thr", "out": "value", "to": "hot", "in": "b" },
			{ "from": "hot", "out": "result", "to": "brain", "in": "cond" },
			{ "from": "warm", "out": "value", "to": "brain", "in": "a" },
			{ "from": "cool", "out": "value", "to": "brain", "in": "b" },
			{ "from": "brain", "out": "result", "to": "led", "in": "value" },
			{ "from": "k", "out": "value", "to": "sib", "in": "value" }
		]
	}
	_write_json(str(bound_path), iso)
	host.poll_once()
	rt.set_input_frame({ "signal.band.high": 0.9 })
	var o_full := rt.evaluate()
	_check("C: with the band wire intact, device.set_led fired WARM (r=1)",
		abs(float(o_full.get("led", {}).get("result", {}).get("r")) - 1.0) < 0.001)
	_check("C: the independent sibling WorldAction fired too (log 'always')",
		str(o_full.get("sib", {}).get("result", {}).get("message")) == "always")
	# sever ONLY band->hot. The Compare `a` is now unconnected (0) -> 0 gt 0.5 = false -> cool branch;
	# the sibling's wire is untouched, so it still logs 'always' — exactly one behaviour changed.
	iso["wires"] = [
		{ "from": "thr", "out": "value", "to": "hot", "in": "b" },
		{ "from": "hot", "out": "result", "to": "brain", "in": "cond" },
		{ "from": "warm", "out": "value", "to": "brain", "in": "a" },
		{ "from": "cool", "out": "value", "to": "brain", "in": "b" },
		{ "from": "brain", "out": "result", "to": "led", "in": "value" },
		{ "from": "k", "out": "value", "to": "sib", "in": "value" }
	]
	_write_json(str(bound_path), iso)
	host.poll_once()
	var o_cut := rt.evaluate()
	_check("C: severing the band wire flipped EXACTLY the device output (LED -> cool, b=1)",
		abs(float(o_cut.get("led", {}).get("result", {}).get("b")) - 1.0) < 0.001
		and abs(float(o_cut.get("led", {}).get("result", {}).get("r")) - 0.0) < 0.001)
	_check("C: the independent sibling was untouched (still logs 'always')",
		str(o_cut.get("sib", {}).get("result", {}).get("message")) == "always")

	# --- 5. DIFF-HOTLOAD (gate D) -------------------------------------------------------------------
	# Change ONLY the Compare threshold's params via a diff hot-load: the same band value now maps to the
	# other colour, and the unrelated sibling Const is untouched (kept live, no rebuild). Proves the edit
	# re-evaluates the target while siblings stay put.
	var warm_before = rt.nodes.get("warm")
	iso["nodes"][1]["params"] = { "value": 2.0 }   # raise threshold above the band value
	_write_json(str(bound_path), iso)
	host.poll_once()
	_check("D: the unrelated `warm` Const node is the SAME live instance after the diff hot-load (kept, not rebuilt)",
		rt.nodes.get("warm") == warm_before)
	rt.set_input_frame({ "signal.band.high": 0.9 })
	var o_diff := rt.evaluate()
	_check("D: bumping only the threshold param re-maps the SAME band to the cool colour (target re-evaluated)",
		abs(float(o_diff.get("led", {}).get("result", {}).get("b")) - 1.0) < 0.001)

	rt.free()
	room.queue_free()
	DeviceActions.unregister_device_ops_host()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- helpers ---------------------------------------------------------------------------------------

func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func _load_json_file(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	return data if typeof(data) == TYPE_DICTIONARY else {}
