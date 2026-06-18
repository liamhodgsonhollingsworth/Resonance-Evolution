extends SceneTree
## Headless verification of the runtime spine (no GUI / no display needed):
##
##   godot --headless --path godot -s res://headless_demo.gd
##
## It loads an arrangement (Const 3, Const 4 -> Math add -> Log), evaluates it
## (expects 7), then HOTLOADS by changing only Math.op to "mul" in the DATA and
## re-evaluates (expects 12) — proving that changing the arrangement re-wires the
## already-loaded primitives WITHOUT rebuilding the Const / Log / Math instances.
##
## Prints "PASS ..." / "FAIL ..." lines and exits non-zero if any check fails.

func _initialize() -> void:
	var ok := true
	var rt := GraphRuntime.new()
	get_root().add_child(rt)

	rt.load_json("res://schema/arrangement.example.json")
	rt.evaluate()
	var log_node: PrimLog = rt.nodes.get("out")
	ok = _check("add => 7", log_node != null and Primitive.as_num(log_node.last_value) == 7.0) and ok

	# Hotload: same graph, Math.op flipped to "mul". Mutate the data and reload (diff).
	var math_before = rt.nodes.get("m")
	var data: Dictionary = rt.arrangement.duplicate(true)
	for n in data["nodes"]:
		if n["id"] == "m":
			n["params"]["op"] = "mul"
	rt.load_arrangement(data)
	ok = _check("hotload kept the Math instance", math_before == rt.nodes.get("m")) and ok
	rt.evaluate()
	ok = _check("mul => 12", Primitive.as_num(log_node.last_value) == 12.0) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
