extends SceneTree
## REAL-TREE #049 TEST for the Sensor source (Dreams-arc Slice 4). Like the Slice-2 input-seam test,
## this drives the ACTUAL aperture_3d room the desktop shortcut opens — it MOUNTS a real GraphPanel on a
## placed object and then drives the SAME LiveHost + GraphRuntime the running room hot-loads that
## object's arrangement into. The Sensor source + its reuse of PrimContext proximity math + the
## set_input_frame seam are exercised on THAT mounted, room-owned runtime — NOT a standalone isolated
## GraphRuntime. A standalone-node test would be a FALSE PASS (the #049 trap: the behaviour must be
## proven in the tree the user actually drives).
##
##   <godot> --headless --path godot -s res://headless_sensor_test.gd
##
## What it proves in the REAL running room's runtime:
##  1. The real aperture_3d room builds headless, an object is placed + bound, and a GraphPanel is
##     mounted INSIDE the room — the runtime under test is the one that room hot-loads (the #049 tree).
##  2. PROXIMITY MODE: a "proximity" Sensor bound to a target emits a value that TRACKS the target's
##     distance (reusing Context's proximity math) — moving the target's position changes the sensed
##     scalar exactly as the Euclidean distance changes.
##  3. FRAME MODE: a "frame" Sensor reads an injected frame value via set_input_frame (the camera/audio-
##     band path), and an ABSENT sensor_id falls to params.default.
##  4. SENSED-VALUE FLOW: the sensed scalar flows Sensor -> Compare/Select -> WorldAction and the
##     WorldAction's perform() receipt fires with the gated branch.
##  5. TEXT-EQUIVALENCE (gate T): the exact backend the (future) GUI drives — set_input_frame +
##     evaluate() on the room runtime — is what this headless text path exercises; no GUI-only seam.
##  6. CONNECTION-ISOLATED-FAILURE (gate C): severing the Sensor->logic wire kills EXACTLY that one
##     gated behaviour; a sibling WorldAction still runs.

const Aperture3D := preload("res://aperture/aperture_3d.gd")
const GraphPanelMount := preload("res://aperture/graph_panel_mount.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
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
		obj_id = String(id)
		break
	_check("object placed + resolvable in the room", obj_id != "")

	var bound_path = room.call("bind_object", obj_id, true)   # force=true => mount headless (#049)
	await process_frame
	await process_frame
	_check("#049: a node panel is mounted INSIDE the running room (the real tree)",
		GraphPanelMount.panel_is_open(room))

	# The runtime UNDER TEST is the one the running room hot-loads the object's arrangement into:
	# a LiveHost + GraphRuntime pointed at the SAME file the mounted panel commits to.
	var host := LiveHost.new()
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	host.runtime = rt
	host.path = String(bound_path)
	get_root().add_child(host)
	_check("the runtime under test is the room-mounted panel's live host runtime",
		host.runtime == rt and String(host.path) == String(bound_path))

	# --- 2. PROXIMITY MODE: a Sensor bound to a target emits the target's DISTANCE ------------------
	# A "proximity" Sensor reads two positions (the observer/origin at pos_a via a Const, the target at
	# pos_b via a Const). The emitted value must equal the Euclidean distance — reusing Context's math.
	# We drive it through two arrangements with the target at different positions and assert the sensed
	# scalar tracks the distance exactly.
	var prox := {
		"format": "resonance.arrangement/v1", "name": "sensor_proximity",
		"nodes": [
			{ "id": "origin", "type": "Const", "params": { "value": [0, 0, 0] } },
			{ "id": "target", "type": "Const", "params": { "value": [3, 4, 0] } },
			{ "id": "sen", "type": "Sensor", "params": { "mode": "proximity", "target_id": "cube" } },
		],
		"wires": [
			{ "from": "origin", "out": "value", "to": "sen", "in": "pos_a" },
			{ "from": "target", "out": "value", "to": "sen", "in": "pos_b" },
		],
	}
	_write_json(String(bound_path), prox)
	host.poll_once()
	_check("the proximity Sensor arrangement hot-loaded into the room runtime (3 nodes live)", rt.nodes.size() == 3)
	var out_p := rt.evaluate()
	var d1 = out_p.get("sen", {}).get("value")
	# (3,4,0) is exactly 5.0 from the origin (3-4-5 triangle) — reused Context proximity math, sqrt'd.
	_check("PROXIMITY: the Sensor emits the target's Euclidean DISTANCE (5.0 for (3,4,0))",
		abs(Primitive.as_num(d1) - 5.0) < 0.0001)

	# Move the target CLOSER; the sensed distance must track it (reused math, continuous read).
	prox["nodes"][1]["params"] = { "value": [0, 0, 1] }   # distance 1.0 from origin
	_write_json(String(bound_path), prox)
	host.poll_once()
	var out_p2 := rt.evaluate()
	var d2 = out_p2.get("sen", {}).get("value")
	_check("PROXIMITY: moving the target changes the sensed distance (1.0 for (0,0,1))",
		abs(Primitive.as_num(d2) - 1.0) < 0.0001)
	# A missing/unconnected position -> 0.0 (the fail-safe "no reading", Context's proximity direction).
	var prox_unwired := {
		"format": "resonance.arrangement/v1", "name": "sensor_proximity_unwired",
		"nodes": [ { "id": "sen", "type": "Sensor", "params": { "mode": "proximity" } } ],
		"wires": [],
	}
	_write_json(String(bound_path), prox_unwired)
	host.poll_once()
	var out_pu := rt.evaluate()
	_check("PROXIMITY: an unconnected position falls to the 0.0 no-reading fail-safe",
		abs(Primitive.as_num(out_pu.get("sen", {}).get("value")) - 0.0) < 0.0001)

	# --- 3. FRAME MODE: read an injected external band; absent sensor_id falls to default -----------
	# A "frame" Sensor reads params.sensor_id out of the runtime's per-frame input frame (the camera /
	# audio-band injection path), exactly like Input. Inject { "audio.band0": 0.75 } and read it.
	var frame_arr := {
		"format": "resonance.arrangement/v1", "name": "sensor_frame",
		"nodes": [
			{ "id": "sen", "type": "Sensor", "params": { "mode": "frame", "sensor_id": "audio.band0", "default": -1 } },
		],
		"wires": [],
	}
	_write_json(String(bound_path), frame_arr)
	host.poll_once()
	rt.set_input_frame({ "audio.band0": 0.75 })
	_check("get_input_frame round-trips the injected sensed frame", rt.get_input_frame().get("audio.band0") == 0.75)
	var out_f := rt.evaluate()
	_check("FRAME: the Sensor reads the injected external band value via set_input_frame",
		abs(Primitive.as_num(out_f.get("sen", {}).get("value")) - 0.75) < 0.0001)
	# ABSENT sensor_id: a frame lacking audio.band0 falls to params.default (-1).
	rt.set_input_frame({ "other.band": 9 })
	var out_fd := rt.evaluate()
	_check("FRAME: an ABSENT sensor_id falls to params.default (-1)",
		abs(Primitive.as_num(out_fd.get("sen", {}).get("value")) - (-1.0)) < 0.0001)

	# --- 4. SENSED-VALUE FLOW: Sensor -> Compare -> Select -> WorldAction ----------------------------
	# A frame-mode Sensor (band above a Const threshold) drives Compare(gt) -> Select -> WorldAction(log).
	# The sensed value is what makes the gate fire; the receipt carries the gated branch's message.
	var flow := {
		"format": "resonance.arrangement/v1", "name": "sensor_flow",
		"nodes": [
			{ "id": "sen", "type": "Sensor", "params": { "mode": "frame", "sensor_id": "audio.band0", "default": 0 } },
			{ "id": "thr", "type": "Const", "params": { "value": 0.5 } },
			{ "id": "cmp", "type": "Compare", "params": { "op": "gt" } },
			{ "id": "hi", "type": "Const", "params": { "value": "loud" } },
			{ "id": "lo", "type": "Const", "params": { "value": "quiet" } },
			{ "id": "sel", "type": "Select", "params": {} },
			{ "id": "act", "type": "WorldAction", "params": { "op": "log" } },
		],
		"wires": [
			{ "from": "sen", "out": "value", "to": "cmp", "in": "a" },
			{ "from": "thr", "out": "value", "to": "cmp", "in": "b" },
			{ "from": "cmp", "out": "result", "to": "sel", "in": "cond" },
			{ "from": "hi", "out": "value", "to": "sel", "in": "a" },
			{ "from": "lo", "out": "value", "to": "sel", "in": "b" },
			{ "from": "sel", "out": "result", "to": "act", "in": "value" },
		],
	}
	_write_json(String(bound_path), flow)
	host.poll_once()
	rt.set_input_frame({ "audio.band0": 0.75 })   # above threshold -> "loud"
	var out_hi := rt.evaluate()
	var receipt_hi: Dictionary = out_hi.get("act", {}).get("result", {})
	_check("FLOW: the sensed value drove the gate and WorldAction's perform() fired ('loud')",
		String(receipt_hi.get("op")) == "log" and String(receipt_hi.get("message")) == "loud")
	rt.set_input_frame({ "audio.band0": 0.1 })    # below threshold -> "quiet"
	var out_lo := rt.evaluate()
	_check("FLOW: a different sensed value flips the gate through the same wires ('quiet')",
		String(out_lo.get("act", {}).get("result", {}).get("message")) == "quiet")

	# --- 5. CONNECTION-ISOLATED-FAILURE (gate C) ----------------------------------------------------
	# A 2-behaviour arrangement: the Sensor->Compare->Select->WorldAction(a) gate AND an independent
	# Const->WorldAction(b) that always logs "always". Sever ONLY the Sensor->cmp wire and prove exactly
	# a's gated behaviour changes (Sensor falls to the logic's unconnected default -> gate false ->
	# "quiet") while b still logs "always".
	var iso := {
		"format": "resonance.arrangement/v1", "name": "sensor_isolation",
		"nodes": [
			{ "id": "sen", "type": "Sensor", "params": { "mode": "frame", "sensor_id": "audio.band0", "default": 0 } },
			{ "id": "thr", "type": "Const", "params": { "value": 0.5 } },
			{ "id": "cmp", "type": "Compare", "params": { "op": "gt" } },
			{ "id": "hi", "type": "Const", "params": { "value": "loud" } },
			{ "id": "lo", "type": "Const", "params": { "value": "quiet" } },
			{ "id": "sel", "type": "Select", "params": {} },
			{ "id": "a", "type": "WorldAction", "params": { "op": "log" } },
			{ "id": "k", "type": "Const", "params": { "value": "always" } },
			{ "id": "b", "type": "WorldAction", "params": { "op": "log" } },
		],
		"wires": [
			{ "from": "sen", "out": "value", "to": "cmp", "in": "a" },
			{ "from": "thr", "out": "value", "to": "cmp", "in": "b" },
			{ "from": "cmp", "out": "result", "to": "sel", "in": "cond" },
			{ "from": "hi", "out": "value", "to": "sel", "in": "a" },
			{ "from": "lo", "out": "value", "to": "sel", "in": "b" },
			{ "from": "sel", "out": "result", "to": "a", "in": "value" },
			{ "from": "k", "out": "value", "to": "b", "in": "value" },
		],
	}
	_write_json(String(bound_path), iso)
	host.poll_once()
	rt.set_input_frame({ "audio.band0": 0.75 })
	var o_full := rt.evaluate()
	_check("C: with the Sensor wire intact, the gated WorldAction fired (a = 'loud')",
		String(o_full.get("a", {}).get("result", {}).get("message")) == "loud")
	_check("C: the independent sibling WorldAction fired too (b = 'always')",
		String(o_full.get("b", {}).get("result", {}).get("message")) == "always")
	# sever ONLY sen -> cmp. The gate now sees an unconnected Compare `a` (0) -> false -> "quiet";
	# b's wire is untouched, so b still logs "always" — exactly one behaviour changed.
	iso["wires"] = [
		{ "from": "thr", "out": "value", "to": "cmp", "in": "b" },
		{ "from": "cmp", "out": "result", "to": "sel", "in": "cond" },
		{ "from": "hi", "out": "value", "to": "sel", "in": "a" },
		{ "from": "lo", "out": "value", "to": "sel", "in": "b" },
		{ "from": "sel", "out": "result", "to": "a", "in": "value" },
		{ "from": "k", "out": "value", "to": "b", "in": "value" },
	]
	_write_json(String(bound_path), iso)
	host.poll_once()
	var o_cut := rt.evaluate()
	_check("C: severing the Sensor wire flipped EXACTLY the gated behaviour (a = 'quiet')",
		String(o_cut.get("a", {}).get("result", {}).get("message")) == "quiet")
	_check("C: the independent sibling was untouched (b still = 'always')",
		String(o_cut.get("b", {}).get("result", {}).get("message")) == "always")

	rt.free()
	room.queue_free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- helpers ---------------------------------------------------------------------------------------

func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
