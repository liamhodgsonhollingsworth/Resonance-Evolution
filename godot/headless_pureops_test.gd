extends SceneTree
## Headless verification of the pure-op primitives Compare / Logic / Select in the REAL GraphRuntime:
##
##   godot --headless --path godot -s res://headless_pureops_test.gd
##
## These are pure DATA primitives (no GUI, no mount), so evaluating them inside a live GraphRuntime IS
## the real path - there is no #049 wrong-tree concern; the runtime the user graphs run on is the one
## under test. Proves: full TRUTH TABLES for every op (N-ideal: op lives in DATA, one primitive each);
## the D ideal (edit an op / add a node hot-loads as a diff - the SAME instance re-evaluates, no
## rebuild); the C ideal (sever one wire -> exactly one node result flips, siblings untouched). Mirrors
## headless_chip_test.gd style (PASS/FAIL lines, RESULT, non-zero exit on failure).

func _initialize() -> void:
	var ok := true
	ok = _compare_truth_table() and ok
	ok = _logic_truth_table() and ok
	ok = _select_mux() and ok
	ok = _diff_hotload_op() and ok
	ok = _diff_hotload_add_node() and ok
	ok = _connection_isolated_failure() and ok
	ok = _null_input_safety() and ok
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# -- Compare: every op over a grid of (a,b) pairs, against a GDScript oracle ------------------------
func _compare_truth_table() -> bool:
	var ok := true
	var pairs := [[1.0, 2.0], [2.0, 2.0], [3.0, 2.0], [-1.0, -1.0], [0.0, 0.0]]
	for op in ["lt", "le", "eq", "ne", "gt", "ge"]:
		for pr in pairs:
			var a: float = pr[0]
			var b: float = pr[1]
			var got = _eval_compare(a, b, op)
			var want := _compare_oracle(a, b, op)
			ok = _check("Compare %s(%s,%s) == %s" % [op, a, b, want], got == want) and ok
	# eps tolerance: 1.0 eq 1.0001 with eps 1e-3 is TRUE, with eps 0 is FALSE.
	ok = _check("Compare eq with eps tolerant", _eval_compare_eps(1.0, 1.0001, "eq", 1e-3) == true) and ok
	ok = _check("Compare eq exact intolerant", _eval_compare_eps(1.0, 1.0001, "eq", 0.0) == false) and ok
	return ok

func _compare_oracle(a: float, b: float, op: String) -> bool:
	match op:
		"lt": return a < b
		"le": return a <= b
		"eq": return a == b
		"ne": return a != b
		"gt": return a > b
		"ge": return a >= b
	return false

# -- Logic: full truth table for two-input ops + the unary NOT --------------------------------------
func _logic_truth_table() -> bool:
	var ok := true
	for a in [false, true]:
		for b in [false, true]:
			for op in ["and", "or", "xor", "nand", "nor", "xnor"]:
				var got = _eval_logic(a, b, op)
				var want := _logic_oracle(a, b, op)
				ok = _check("Logic %s(%s,%s) == %s" % [op, a, b, want], got == want) and ok
		ok = _check("Logic not(%s) == %s" % [a, not a], _eval_logic(a, false, "not") == (not a)) and ok
	return ok

func _logic_oracle(a: bool, b: bool, op: String) -> bool:
	match op:
		"and": return a and b
		"or": return a or b
		"xor": return a != b
		"nand": return not (a and b)
		"nor": return not (a or b)
		"xnor": return a == b
	return false

# -- Select: the MUX picks a on true, b on false; passes any value straight through -----------------
func _select_mux() -> bool:
	var ok := true
	ok = _check("Select true => a (=11)", _eval_select(true, 11, 22) == 11) and ok
	ok = _check("Select false => b (=22)", _eval_select(false, 11, 22) == 22) and ok
	# Passes non-number values through unchanged (any-typed ports).
	ok = _check("Select passes strings", _eval_select(true, "yes", "no") == "yes") and ok
	return ok

# -- D ideal: edit an op hot-loads as a DIFF - the SAME primitive instance re-evaluates -------------
func _diff_hotload_op() -> bool:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	# Const 3 -> Compare(a) , Const 5 -> Compare(b) ; op lt => 3<5 = true.
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "a", "type": "Const", "params": { "value": 3 } },
			{ "id": "b", "type": "Const", "params": { "value": 5 } },
			{ "id": "c", "type": "Compare", "params": { "op": "lt" } },
		],
		"wires": [
			{ "from": "a", "out": "value", "to": "c", "in": "a" },
			{ "from": "b", "out": "value", "to": "c", "in": "b" },
		],
	}
	rt.load_arrangement(arr)
	var out1 := rt.evaluate()
	var v_lt = out1.get("c", {}).get("result")
	var inst1: int = rt.nodes.get("c").get_instance_id()
	# Hot-load: flip op to gt => 3>5 = false, WITHOUT rebuilding (diff splice keeps the instance).
	var arr2: Dictionary = arr.duplicate(true)
	for n in arr2["nodes"]:
		if n["id"] == "c":
			n["params"]["op"] = "gt"
	rt.load_arrangement(arr2)
	var out2 := rt.evaluate()
	var v_gt = out2.get("c", {}).get("result")
	var inst2: int = rt.nodes.get("c").get_instance_id()
	get_root().remove_child(rt)
	rt.free()
	var ok := true
	ok = _check("D: hotload op lt=>true then gt=>false", v_lt == true and v_gt == false) and ok
	ok = _check("D: same Compare instance across hotload (diff, not rebuild)", inst1 != 0 and inst1 == inst2) and ok
	return ok

# -- D ideal (add-node): adding a Logic node that consumes an existing Compare re-evaluates only it -
func _diff_hotload_add_node() -> bool:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var base := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "a", "type": "Const", "params": { "value": 1 } },
			{ "id": "b", "type": "Const", "params": { "value": 2 } },
			{ "id": "c1", "type": "Compare", "params": { "op": "lt" } },
		],
		"wires": [
			{ "from": "a", "out": "value", "to": "c1", "in": "a" },
			{ "from": "b", "out": "value", "to": "c1", "in": "b" },
		],
	}
	rt.load_arrangement(base)
	rt.evaluate()
	var c1_inst: int = rt.nodes.get("c1").get_instance_id()
	# Add a second Compare + a Logic AND over both, as a diff. c1 must be KEPT (same instance).
	var grown: Dictionary = base.duplicate(true)
	grown["nodes"].append({ "id": "c2", "type": "Compare", "params": { "op": "gt" } })
	grown["nodes"].append({ "id": "g", "type": "Logic", "params": { "op": "and" } })
	grown["wires"].append({ "from": "a", "out": "value", "to": "c2", "in": "a" })  # 1 > 2 = false
	grown["wires"].append({ "from": "b", "out": "value", "to": "c2", "in": "b" })
	grown["wires"].append({ "from": "c1", "out": "result", "to": "g", "in": "a" })  # true
	grown["wires"].append({ "from": "c2", "out": "result", "to": "g", "in": "b" })  # false
	rt.load_arrangement(grown)
	var out := rt.evaluate()
	var c1_inst_after: int = rt.nodes.get("c1").get_instance_id()
	var g_val = out.get("g", {}).get("result")
	get_root().remove_child(rt)
	rt.free()
	var ok := true
	ok = _check("D(add): true AND false => false", g_val == false) and ok
	ok = _check("D(add): pre-existing Compare instance kept", c1_inst != 0 and c1_inst == c1_inst_after) and ok
	return ok

# -- C ideal: sever ONE wire => exactly one node result changes, everything else keeps running ------
func _connection_isolated_failure() -> bool:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	# Two INDEPENDENT compare chains sharing no wires.
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "a1", "type": "Const", "params": { "value": 1 } },
			{ "id": "b1", "type": "Const", "params": { "value": 9 } },
			{ "id": "c1", "type": "Compare", "params": { "op": "lt" } },
			{ "id": "a2", "type": "Const", "params": { "value": 4 } },
			{ "id": "b2", "type": "Const", "params": { "value": 2 } },
			{ "id": "c2", "type": "Compare", "params": { "op": "lt" } },
		],
		"wires": [
			{ "from": "a1", "out": "value", "to": "c1", "in": "a" },
			{ "from": "b1", "out": "value", "to": "c1", "in": "b" },
			{ "from": "a2", "out": "value", "to": "c2", "in": "a" },
			{ "from": "b2", "out": "value", "to": "c2", "in": "b" },
		],
	}
	rt.load_arrangement(arr)
	var before := rt.evaluate()
	var c1_before = before.get("c1", {}).get("result")  # 1<9 = true
	var c2_before = before.get("c2", {}).get("result")  # 4<2 = false
	# Sever ONE wire (b1 -> c1.b). Now c1.b is unconnected => 0, so 1<0 = false. c2 UNTOUCHED.
	var cut: Dictionary = arr.duplicate(true)
	var kept := []
	for w in cut["wires"]:
		if not (w["from"] == "b1" and w["to"] == "c1"):
			kept.append(w)
	cut["wires"] = kept
	rt.load_arrangement(cut)
	var after := rt.evaluate()
	var c1_after = after.get("c1", {}).get("result")  # 1 < 0 = false (its input died)
	var c2_after = after.get("c2", {}).get("result")  # unchanged: still false
	get_root().remove_child(rt)
	rt.free()
	var ok := true
	ok = _check("C: severed wire flips exactly c1 (true=>false)", c1_before == true and c1_after == false) and ok
	ok = _check("C: sibling c2 unaffected by the severed wire", c2_before == c2_after) and ok
	return ok

# -- Robustness: unconnected inputs are a defined value, never a crash -----------------------------
func _null_input_safety() -> bool:
	var ok := true
	# Compare with both inputs unconnected: 0 lt 0 = false; a Logic with unconnected inputs: false.
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "c", "type": "Compare", "params": { "op": "eq" } },
			{ "id": "g", "type": "Logic", "params": { "op": "or" } },
			{ "id": "s", "type": "Select", "params": { "default_cond": true } },
		],
		"wires": [],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	ok = _check("null-safe Compare eq(0,0) => true", out.get("c", {}).get("result") == true) and ok
	ok = _check("null-safe Logic or(false,false) => false", out.get("g", {}).get("result") == false) and ok
	ok = _check("null-safe Select default_cond=true picks a(null)", out.get("s", {}).get("result") == null) and ok
	get_root().remove_child(rt)
	rt.free()
	return ok

# -- Single-node eval helpers (each builds a tiny real arrangement) --------------------------------
func _eval_compare(a, b, op: String):
	return _eval_two_in("Compare", { "op": op }, a, b, "result")

func _eval_compare_eps(a, b, op: String, eps: float):
	return _eval_two_in("Compare", { "op": op, "eps": eps }, a, b, "result")

func _eval_logic(a, b, op: String):
	return _eval_two_in("Logic", { "op": op }, a, b, "result")

func _eval_select(cond, a, b):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "kc", "type": "Const", "params": { "value": cond } },
			{ "id": "ka", "type": "Const", "params": { "value": a } },
			{ "id": "kb", "type": "Const", "params": { "value": b } },
			{ "id": "s", "type": "Select", "params": {} },
		],
		"wires": [
			{ "from": "kc", "out": "value", "to": "s", "in": "cond" },
			{ "from": "ka", "out": "value", "to": "s", "in": "a" },
			{ "from": "kb", "out": "value", "to": "s", "in": "b" },
		],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var v = out.get("s", {}).get("result")
	get_root().remove_child(rt)
	rt.free()
	return v

func _eval_two_in(type_name: String, node_params: Dictionary, a, b, out_port: String):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ka", "type": "Const", "params": { "value": a } },
			{ "id": "kb", "type": "Const", "params": { "value": b } },
			{ "id": "op", "type": type_name, "params": node_params },
		],
		"wires": [
			{ "from": "ka", "out": "value", "to": "op", "in": "a" },
			{ "from": "kb", "out": "value", "to": "op", "in": "b" },
		],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var v = out.get("op", {}).get(out_port)
	get_root().remove_child(rt)
	rt.free()
	return v

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
