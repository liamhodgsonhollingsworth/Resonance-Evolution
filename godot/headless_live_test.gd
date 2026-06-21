extends SceneTree
## Headless verification of the live hotload loop (no display needed):
##
##   godot --headless --path godot -s res://headless_live_test.gd
##
## Simulates an external editor (Claude Code) rewriting the arrangement on disk:
##   1. write an arrangement (3 + 4 -> 7), host detects + loads it,
##   2. polling again with no change does nothing (idempotent),
##   3. rewrite the file (3 * 4 -> 12), host detects the content change and reloads,
##      and the running graph re-evaluates to 12 — all without restart.

func _initialize() -> void:
	var ok := true
	var p := "user://live_arr.json"

	_write(p, _arr("add"))
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var host := LiveHost.new()
	host.runtime = rt
	host.path = p
	get_root().add_child(host)

	ok = _check("initial load happened", host.poll_once()) and ok
	var log_node: PrimLog = rt.nodes.get("out")
	ok = _check("initial value = 7", log_node != null and Primitive.as_num(log_node.last_value) == 7.0) and ok
	ok = _check("initial rev surfaced (0, no rev in file)", host.rev == 0) and ok
	ok = _check("no change -> no reload", not host.poll_once()) and ok

	_write(p, _arr("mul", 7))
	ok = _check("content change detected -> reload", host.poll_once()) and ok
	ok = _check("after edit value = 12", Primitive.as_num(log_node.last_value) == 12.0) and ok
	ok = _check("rev surfaced after reload (7)", host.rev == 7) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _arr(op: String, rev := 0) -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"rev": rev,
		"nodes": [
			{ "id": "a", "type": "Const", "params": { "value": 3 } },
			{ "id": "b", "type": "Const", "params": { "value": 4 } },
			{ "id": "m", "type": "Math", "params": { "op": op } },
			{ "id": "out", "type": "Log", "params": {} }
		],
		"wires": [
			{ "from": "a", "out": "value", "to": "m", "in": "a" },
			{ "from": "b", "out": "value", "to": "m", "in": "b" },
			{ "from": "m", "out": "result", "to": "out", "in": "in" }
		]
	}

func _write(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
