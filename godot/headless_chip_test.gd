extends SceneTree
## Headless verification of the Chip primitive + ChipOps (engine-neutral grouping):
##
##   godot --headless --path godot -s res://headless_chip_test.gd
##
## Proves: grouping a selection into a Chip preserves behaviour; the inner graph hotloads
## through the Chip; chips serialize round-trip via JSON; chips accept external inputs;
## chips nest (Chip-in-Chip); and ungroup is a behaviour-preserving inverse. Mirrors the
## style of headless_demo.gd (PASS/FAIL lines, RESULT, non-zero exit on failure).

func _initialize() -> void:
	var ok := true
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://schema/arrangement.example.json"))
	var resolver_rt := GraphRuntime.new()
	var resolver := Callable(resolver_rt, "port_type")

	# Baseline: Const 3 + Const 4 -> Math add -> Log == 7.
	ok = _check("baseline add => 7", _eval_log(base) == 7.0) and ok

	# Group [a, b, m] into a chip; behaviour preserved (Log still 7), 2 top-level nodes.
	var g1 := ChipOps.group(base, ["a", "b", "m"], resolver)
	ok = _check("group [a,b,m] keeps => 7", _eval_log(g1) == 7.0) and ok
	ok = _check("group => one Chip + Log", _count_type(g1, "Chip") == 1 and (g1["nodes"] as Array).size() == 2) and ok

	# Inner hotload: flip the inner Math.op to mul inside the chip => 12.
	var g1b: Dictionary = g1.duplicate(true)
	_set_inner_math_op(g1b, "mul")
	ok = _check("inner Math.op mul => 12", _eval_log(g1b) == 12.0) and ok

	# Serialize round-trip through JSON.
	var rt_json: Dictionary = JSON.parse_string(JSON.stringify(g1))
	ok = _check("chip round-trips via JSON => 7", _eval_log(rt_json) == 7.0) and ok

	# Chip with INPUTS: group just [m] so the chip takes a, b as inputs and emits result.
	var g2 := ChipOps.group(base, ["m"], resolver)
	ok = _check("group [m] (chip with inputs) => 7", _eval_log(g2) == 7.0) and ok
	var chip2 = _first_node_of_type(g2, "Chip")
	ok = _check("chip [m] has 2 inputs, 1 output", _port_count(chip2, "inputs") == 2 and _port_count(chip2, "outputs") == 1) and ok

	# Nesting: wrap the [a,b,m] chip again -> Chip-in-Chip, still 7.
	var chip_id := _first_type_id(g1, "Chip")
	var g3 := ChipOps.group(g1, [chip_id], resolver)
	ok = _check("nested Chip-in-Chip => 7", _eval_log(g3) == 7.0) and ok

	# Ungroup is a behaviour-preserving inverse, back to 4 plain nodes.
	var u := ChipOps.ungroup(g1, chip_id)
	ok = _check("ungroup => 7", _eval_log(u) == 7.0) and ok
	ok = _check("ungroup restores 4 nodes, 0 chips", (u["nodes"] as Array).size() == 4 and _count_type(u, "Chip") == 0) and ok

	resolver_rt.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ---------------------------------------------------------------

func _eval_log(arr: Dictionary, log_id := "out"):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	rt.evaluate()
	var log_node = rt.nodes.get(log_id)
	var v = log_node.last_value if log_node != null else null
	get_root().remove_child(rt)
	rt.free()
	return Primitive.as_num(v) if v != null else null

func _count_type(arr: Dictionary, type_name: String) -> int:
	var c := 0
	for n in arr.get("nodes", []):
		if String(n.get("type")) == type_name:
			c += 1
	return c

func _first_type_id(arr: Dictionary, type_name: String) -> String:
	for n in arr.get("nodes", []):
		if String(n.get("type")) == type_name:
			return String(n.get("id"))
	return ""

func _first_node_of_type(arr: Dictionary, type_name: String):
	for n in arr.get("nodes", []):
		if String(n.get("type")) == type_name:
			return n
	return null

func _port_count(chip, which: String) -> int:
	if chip == null:
		return -1
	return (((chip.get("params", {}) as Dictionary).get("ports", {}) as Dictionary).get(which, []) as Array).size()

func _set_inner_math_op(arr: Dictionary, op: String) -> void:
	for n in arr.get("nodes", []):
		if String(n.get("type")) == "Chip":
			var inner: Dictionary = n["params"]["arrangement"]
			for inner_n in inner["nodes"]:
				if String(inner_n.get("type")) == "Math":
					inner_n["params"]["op"] = op

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
