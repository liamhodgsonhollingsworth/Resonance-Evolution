extends SceneTree
## Headless verification of the editor panel's DATA layer (GraphPanel) — no display needed;
## GraphEdit's connection bookkeeping works under the dummy display server:
##
##   godot --headless --path godot -s res://headless_editor_test.gd
##
## Proves: an arrangement renders to the right GraphNodes + typed connections; the panel
## round-trips the graph back to identical-behaviour data (evaluates to 7); and "group
## selection into a Chip" (via ChipOps) collapses the selection and preserves behaviour.
## The GraphEdit widget itself (3D mounting, dragging) is verified windowed separately.

func _initialize() -> void:
	var ok := true
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://schema/arrangement.example.json"))

	var panel := GraphPanel.new()
	panel.commit_path = "user://test_editor_out.json"  # don't touch res://live in a test
	get_root().add_child(panel)
	panel.load_arrangement(base)

	ok = _check("renders 4 graph nodes", _graphnode_count(panel) == 4) and ok
	ok = _check("renders 3 connections", panel.get_connection_list().size() == 3) and ok
	ok = _check("panel round-trips => 7", _eval_log(panel.serialize()) == 7.0) and ok

	# Group [a, b, m] via the panel (selection -> ChipOps.group -> reload + commit).
	for c in panel.get_children():
		if c is GraphNode and (String(c.name) == "a" or String(c.name) == "b" or String(c.name) == "m"):
			c.selected = true
	panel.group_selected()
	ok = _check("after group: 2 nodes (Chip + Log)", _graphnode_count(panel) == 2) and ok
	ok = _check("after group still => 7", _eval_log(panel.serialize()) == 7.0) and ok
	ok = _check("commit wrote the arrangement file", FileAccess.file_exists("user://test_editor_out.json")) and ok

	panel.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _graphnode_count(panel) -> int:
	var c := 0
	for ch in panel.get_children():
		if ch is GraphNode:
			c += 1
	return c

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

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
