extends SceneTree
## UNIT TESTS for the WorldActions side-effect sink + the PrimWorldAction wire (Dreams-arc Slice 1).
##
##   <godot> --headless --path godot -s res://headless_world_actions_test.gd
##
## Proves the Action seam's load-bearing contract: named ops route to their handler; an UNKNOWN op is a
## DECLARED NO-OP (the portability keystone), not an error; the log sink is injectable (zero real side
## effect under test); set_param emits a declarative DATA receipt (node-not-edit); and the node runs as a
## normal dataflow node inside a GraphRuntime arrangement (its output `result` is a serialisable receipt).

const WorldActions := preload("res://runtime/world_actions.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	# --- WorldActions module directly ---------------------------------------------------------------
	var logged: Array = []
	var wa := WorldActions.new({}, func(m): logged.append(m))

	_check("log op registered by default", wa.has_op("log"))
	_check("set_param op registered by default", wa.has_op("set_param"))
	_check("ops() lists them sorted", wa.ops().has("log") and wa.ops().has("set_param"))

	var r1 := wa.perform("log", { "message": "hello" })
	_check("log op ok", bool(r1.get("ok", false)) and String(r1.get("op")) == "log")
	_check("log op reached the injected sink (no real side effect)", logged.size() == 1 and String(logged[0]) == "hello")

	# UNKNOWN OP = DECLARED NO-OP (not an error) — the portability keystone.
	var r2 := wa.perform("device.ir_send", { "code": 42 })
	_check("unknown op returns ok:true (not an error)", bool(r2.get("ok", false)))
	_check("unknown op is flagged noop with a reason", bool(r2.get("noop", false)) and String(r2.get("reason", "")) == "unknown op")
	_check("unknown op did NOT reach the log sink", logged.size() == 1)

	# set_param emits a DECLARATIVE receipt (target/key/value as DATA), mutating nothing itself.
	var r3 := wa.perform("set_param", { "target": "box", "key": "rotation", "value": [0, 45, 0] })
	_check("set_param receipt ok", bool(r3.get("ok", false)))
	_check("set_param receipt carries target/key/value as data",
		String(r3.get("target")) == "box" and String(r3.get("key")) == "rotation" and typeof(r3.get("value")) == TYPE_ARRAY)
	var r3b := wa.perform("set_param", { "key": "rotation" })
	_check("set_param without a target is an honest error (not a silent noop)",
		not bool(r3b.get("ok", true)))

	# a HOST can register a new op additively (the whole extension surface).
	var fired: Array = []
	wa.register("device.set_led", func(a): fired.append(a); return { "ok": true, "op": "device.set_led", "addr": a.get("addr") })
	_check("a host-registered op is now honoured (additive)", wa.has_op("device.set_led"))
	var r4 := wa.perform("device.set_led", { "addr": 7, "r": 1 })
	_check("host op fires + returns its receipt", bool(r4.get("ok", false)) and int(r4.get("addr")) == 7 and fired.size() == 1)

	# --- PrimWorldAction inside a GraphRuntime (a normal dataflow node) ------------------------------
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	# A Const value wired into a WorldAction:log — the seed graph shape. The receipt is the node's output.
	rt.load_arrangement({
		"format": "resonance.arrangement/v1", "name": "wa_test",
		"nodes": [
			{ "id": "src", "type": "Const", "params": { "value": 5 } },
			{ "id": "act", "type": "WorldAction", "params": { "op": "log" } },
		],
		"wires": [ { "from": "src", "out": "value", "to": "act", "in": "value" } ],
	})
	var out := rt.evaluate()
	var res: Dictionary = out.get("act", {}).get("result", {})
	_check("WorldAction node evaluates to a serialisable receipt", res.get("ok", null) != null)
	_check("wired Const value reached the log op (value -> message)", String(res.get("op")) == "log" and String(res.get("message")) == "5")

	# op from params when the `op` input is unwired; unknown params.op still no-ops safely.
	rt.load_arrangement({
		"format": "resonance.arrangement/v1", "name": "wa_test2",
		"nodes": [ { "id": "act", "type": "WorldAction", "params": { "op": "device.projector_output" } } ],
		"wires": [],
	})
	var out2 := rt.evaluate()
	var res2: Dictionary = out2.get("act", {}).get("result", {})
	_check("unwired unknown params.op => the node still runs, as a declared no-op",
		bool(res2.get("ok", false)) and bool(res2.get("noop", false)))

	rt.free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)
