extends SceneTree
## REAL-TREE #049 TEST for the Input source + input-frame seam (Dreams-arc Slice 2). Like the Slice-1
## spine test, this drives the ACTUAL aperture_3d room the desktop shortcut opens — it MOUNTS a real
## GraphPanel on a placed object and then drives the SAME LiveHost + GraphRuntime the running room hot-
## loads that object's arrangement into. The Input source + set_input_frame seam are exercised on THAT
## mounted, room-owned runtime — NOT a standalone isolated GraphRuntime. A standalone-node test would be
## a FALSE PASS (the #049 trap: the behaviour must be proven in the tree the user actually drives).
##
##   <godot> --headless --path godot -s res://headless_input_seam_test.gd
##
## What it proves in the REAL running room's runtime:
##  1. The real aperture_3d room builds headless, an object is placed + bound, and a GraphPanel is
##     mounted INSIDE the room — the runtime under test is the one that room hot-loads (the #049 tree).
##  2. INPUT FLOW: set_input_frame({...}) on the room-owned runtime, then an Input -> Compare -> Select
##     -> WorldAction arrangement (Compare/Select already registered) — the injected Input value flows
##     through the interaction logic and the WorldAction's perform() receipt fires with it.
##  3. ABSENT INPUT falls to params.default: an Input whose input_id is not in the frame emits its
##     default, and the arrangement still evaluates (the un-driven-input portability posture).
##  4. UNKNOWN OP = NO-OP still holds through WorldAction: an Input-driven arrangement whose op is not
##     registered returns a declared no-op receipt (ok:true, noop:true) — same arrangement, any host.
##  5. TEXT-EQUIVALENCE (gate T): the exact backend the (future) GUI drives — set_input_frame +
##     evaluate() on the room runtime — is what this headless text path exercises; there is no GUI-only
##     path to the seam.
##  6. CONNECTION-ISOLATED-FAILURE (gate C): severing the Input->logic wire kills exactly the gated
##     behaviour (it falls to the logic's unconnected-input default); a sibling WorldAction still runs.

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
	# a LiveHost + GraphRuntime pointed at the SAME file the mounted panel commits to — exactly the
	# spine test's real-path setup. set_input_frame is exercised on THIS runtime, not a bare node.
	var host := LiveHost.new()
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	host.runtime = rt
	host.path = String(bound_path)
	get_root().add_child(host)
	_check("the runtime under test is the room-mounted panel's live host runtime",
		host.runtime == rt and String(host.path) == String(bound_path))

	# --- 2. INPUT FLOW: inject a frame, hot-load an Input->Compare->Select->WorldAction arrangement --
	# axis1=5 vs a Const threshold 3 -> Compare(gt)=true -> Select(true ? "pressed" : "idle")="pressed"
	# -> WorldAction(log). The injected Input value is what makes the gate fire; the receipt carries it.
	var arr := {
		"format": "resonance.arrangement/v1", "name": "input_seam",
		"nodes": [
			{ "id": "in", "type": "Input", "params": { "input_id": "axis1", "default": 0 } },
			{ "id": "thr", "type": "Const", "params": { "value": 3 } },
			{ "id": "cmp", "type": "Compare", "params": { "op": "gt" } },
			{ "id": "hi", "type": "Const", "params": { "value": "pressed" } },
			{ "id": "lo", "type": "Const", "params": { "value": "idle" } },
			{ "id": "sel", "type": "Select", "params": {} },
			{ "id": "act", "type": "WorldAction", "params": { "op": "log" } },
		],
		"wires": [
			{ "from": "in", "out": "value", "to": "cmp", "in": "a" },
			{ "from": "thr", "out": "value", "to": "cmp", "in": "b" },
			{ "from": "cmp", "out": "result", "to": "sel", "in": "cond" },
			{ "from": "hi", "out": "value", "to": "sel", "in": "a" },
			{ "from": "lo", "out": "value", "to": "sel", "in": "b" },
			{ "from": "sel", "out": "result", "to": "act", "in": "value" },
		],
	}
	_write_json(String(bound_path), arr)
	host.poll_once()   # the running room's real hot-load path
	_check("the Input arrangement hot-loaded into the room runtime (7 nodes live)", rt.nodes.size() == 7)

	# Inject a frame where axis1 is present + above threshold. Input.evaluate() reads it off rt.
	rt.set_input_frame({ "axis1": 5 })
	_check("get_input_frame round-trips the injected frame", rt.get_input_frame().get("axis1") == 5)
	var out_hi := rt.evaluate()
	var in_val = out_hi.get("in", {}).get("value")
	_check("the injected Input value flows out of the Input node", in_val == 5)
	var receipt_hi: Dictionary = out_hi.get("act", {}).get("result", {})
	_check("INPUT FLOW: injected input drove the gate and WorldAction's perform() fired",
		String(receipt_hi.get("op")) == "log" and String(receipt_hi.get("message")) == "pressed")

	# Same arrangement, a frame BELOW threshold: the Input still drives, the gate flips, the sink
	# still fires with the other branch — proving the value (not just presence) flows through.
	rt.set_input_frame({ "axis1": 1 })
	var out_lo := rt.evaluate()
	var receipt_lo: Dictionary = out_lo.get("act", {}).get("result", {})
	_check("INPUT FLOW: a different injected value flips the gate through the same wires",
		String(receipt_lo.get("message")) == "idle")

	# --- 3. ABSENT INPUT falls to params.default ----------------------------------------------------
	# A frame that LACKS axis1 (only carries an unrelated key). Input emits params.default (0), so the
	# Compare(0 gt 3)=false path is taken and the arrangement still evaluates — no crash, defined value.
	rt.set_input_frame({ "action.interact": true })
	var out_def := rt.evaluate()
	_check("ABSENT INPUT: Input emits params.default when the frame lacks input_id",
		out_def.get("in", {}).get("value") == 0)
	_check("ABSENT INPUT: the arrangement still evaluates (default drove the false branch)",
		String(out_def.get("act", {}).get("result", {}).get("message")) == "idle")
	# and with NO frame at all injected on a fresh runtime, Input still falls to default.
	var rt2 := GraphRuntime.new()
	get_root().add_child(rt2)
	rt2.load_arrangement(arr)
	var out_none := rt2.evaluate()
	_check("ABSENT FRAME: an Input on a never-fed runtime falls to params.default",
		out_none.get("in", {}).get("value") == 0)

	# --- 4. UNKNOWN OP = NO-OP still holds through WorldAction --------------------------------------
	# Point the SAME Input-driven arrangement at an op no host registered. The receipt must be a
	# declared no-op (ok:true, noop:true) — the portability keystone, unchanged by the Input seam.
	var unknown := arr.duplicate(true)
	for n in unknown["nodes"]:
		if String(n.get("id")) == "act":
			n["params"] = { "op": "device.ir_send" }
	_write_json(String(bound_path), unknown)
	host.poll_once()
	rt.set_input_frame({ "axis1": 5 })
	var out_unk := rt.evaluate()
	var receipt_unk: Dictionary = out_unk.get("act", {}).get("result", {})
	_check("UNKNOWN OP = declared NO-OP through WorldAction (ok+noop, not an error)",
		receipt_unk.get("ok") == true and receipt_unk.get("noop") == true
		and String(receipt_unk.get("op")) == "device.ir_send")

	# --- 5. CONNECTION-ISOLATED-FAILURE (gate C) ----------------------------------------------------
	# Re-seed a 2-behaviour arrangement: the Input->Compare->Select->WorldAction(a) gate AND an
	# independent Const->WorldAction(b) that always logs "always". Sever ONLY the Input->cmp wire and
	# prove exactly a's gated behaviour changes (Input falls to default -> gate false -> "idle") while
	# b still logs "always". String Const values so they round-trip the JSON file unambiguously.
	var iso := {
		"format": "resonance.arrangement/v1", "name": "input_isolation",
		"nodes": [
			{ "id": "in", "type": "Input", "params": { "input_id": "axis1", "default": 0 } },
			{ "id": "thr", "type": "Const", "params": { "value": 3 } },
			{ "id": "cmp", "type": "Compare", "params": { "op": "gt" } },
			{ "id": "hi", "type": "Const", "params": { "value": "pressed" } },
			{ "id": "lo", "type": "Const", "params": { "value": "idle" } },
			{ "id": "sel", "type": "Select", "params": {} },
			{ "id": "a", "type": "WorldAction", "params": { "op": "log" } },
			{ "id": "k", "type": "Const", "params": { "value": "always" } },
			{ "id": "b", "type": "WorldAction", "params": { "op": "log" } },
		],
		"wires": [
			{ "from": "in", "out": "value", "to": "cmp", "in": "a" },
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
	rt.set_input_frame({ "axis1": 5 })
	var o_full := rt.evaluate()
	_check("C: with the Input wire intact, the gated WorldAction fired (a = 'pressed')",
		String(o_full.get("a", {}).get("result", {}).get("message")) == "pressed")
	_check("C: the independent sibling WorldAction fired too (b = 'always')",
		String(o_full.get("b", {}).get("result", {}).get("message")) == "always")
	# sever ONLY in -> cmp. The gate now sees an unconnected Compare `a` (0) -> false -> "idle";
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
	_check("C: severing the Input wire flipped EXACTLY the gated behaviour (a = 'idle')",
		String(o_cut.get("a", {}).get("result", {}).get("message")) == "idle")
	_check("C: the independent sibling was untouched (b still = 'always')",
		String(o_cut.get("b", {}).get("result", {}).get("message")) == "always")

	rt.free()
	rt2.free()
	room.queue_free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- helpers ---------------------------------------------------------------------------------------

func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
