extends SceneTree
## REAL-TREE #049 TEST for the diegetic node panel (Dreams-arc Slice 1). This is the load-bearing
## deliverable: it drives the ACTUAL aperture_3d room the desktop shortcut opens — NOT a standalone
## GraphPanel scene, NOT an isolated headless component. A standalone-GraphPanel test is a FALSE PASS
## (the exact trap that shipped the ✕ button broken 3×: the bug lives in the MOUNTED tree, never in the
## component alone).
##
##   <godot> --headless --path godot -s res://headless_wiring_panel_test.gd
##
## What it proves in the REAL running room:
##  1. The real aperture_3d room builds headless, the wiring interactor is present, and a placed object
##     is REGISTERED as bindable (the reused PickupInteractor proximity seam).
##  2. #049 GATE: bind_object(id, force=true) — the SAME backend fn the in-world right-click calls —
##     actually MOUNTS a GraphPanel overlay INSIDE the running room (CanvasLayer child of the room, a
##     real GraphPanel with the object's arrangement loaded). The panel is the thing the user reaches;
##     we assert it is really there, in the running scene, reachable from what the shortcut opens.
##  3. TEXT-EQUIVALENCE (gate T): the headless text verb bind_object_text(id) opens the same panel via
##     the same backend, pointed at the same arrangement file — GUI and text drive identical behaviour.
##  4. DIFF-HOTLOAD (gate D): editing the mounted panel (a real connection change) RE-SERIALISES the
##     object's arrangement file, and a LiveHost pointed at that file HOT-LOADS the edit as a diff (the
##     runtime re-wires in place; unchanged nodes keep their identity — no scene rebuild, no _ready()).
##  5. CONNECTION-ISOLATED-FAILURE (gate C): severing one wire kills exactly one behaviour — the target
##     re-evaluates without it; every other node keeps running.
##  6. CLOSE: ESC-path (close_panel) unmounts the overlay; the room survives.

const Aperture3D := preload("res://aperture/aperture_3d.gd")
const GraphPanelMount := preload("res://aperture/graph_panel_mount.gd")
const WiringTool := preload("res://runtime/wiring_tool.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	# a clean per-object arrangement dir so the test is hermetic
	var arr_dir := ProjectSettings.globalize_path(WiringTool.ARRANGEMENT_DIR)
	_rm_rf(arr_dir)

	# --- 1. build the REAL room (headless), place an object, confirm it is bindable -----------------
	var room := Aperture3D.new()
	get_root().add_child(room)
	await process_frame
	await process_frame
	_check("real aperture_3d room built (the scene the shortcut opens)", room != null and room.is_inside_tree())
	_check("wiring interactor present in the room", room.get("_wiring_interactor") != null)

	# Place a block through the room's OWN placement path so the object + its pick area + registration are
	# the real ones (not a synthetic stand-in). Equip the wiring tool is not needed to place; we call the
	# room's _place_block directly with a palette block entry, exactly as _place_active would.
	var block_entry := { "kind": "block", "name": "Cube", "shape": "box",
		"params": { "width": 1.0, "height": 1.0, "depth": 1.0 }, "material": { "albedo": [0.8, 0.8, 0.82] } }
	room.call("_place_block", block_entry, Vector3(0, 0.5, -3))
	await process_frame
	var objs: Dictionary = room.get("objects")
	_check("object placed into the room", objs.size() >= 1)
	var obj_id := ""
	for id in objs:
		obj_id = String(id)
		break
	var interactor = room.get("_wiring_interactor")
	_check("placed object registered with the proximity interactor (bindable)",
		interactor != null and interactor.pickable_count() >= 1)

	# resolve_target: aim seam wins. Simulate the crosshair being on the object.
	var resolved := WiringTool.resolve_target({ "obj_id": obj_id }, interactor, room.get("_pos"))
	_check("resolve_target returns the aimed object id", resolved == obj_id)

	# --- 2. #049 GATE: bind via the REAL backend, assert the panel mounts IN THE RUNNING ROOM --------
	var bound_path = room.call("bind_object", obj_id, true)   # force=true => mount headless (the #049 hook)
	await process_frame
	await process_frame
	_check("bind_object returned the object's arrangement path", String(bound_path) != "")
	_check("#049: a node panel overlay is mounted INSIDE the running room (not a standalone scene)",
		GraphPanelMount.panel_is_open(room))
	var overlay := room.get_node_or_null("__graph_panel_overlay")
	_check("#049: the overlay is a CanvasLayer child of the REAL room", overlay is CanvasLayer and overlay.get_parent() == room)
	var panel := GraphPanelMount.panel_of(room)
	_check("#049: the mounted widget is a real GraphPanel", panel != null and panel is GraphPanel)
	# the panel actually rendered the object's seed graph (2 nodes) — it is live, not a stub.
	var gn_count := _graphnode_count(panel)
	_check("#049: the mounted panel rendered the object's arrangement (2 seed nodes)", gn_count == 2)
	_check("the panel commits to the bound object's arrangement file",
		panel != null and String(panel.commit_path) == String(bound_path))

	# --- 3. TEXT-EQUIVALENCE (gate T): the text verb opens the same panel via the same backend --------
	GraphPanelMount.close_panel(room)
	await process_frame
	_check("panel closed before the text-verb check", not GraphPanelMount.panel_is_open(room))
	var text_path = room.call("bind_object_text", obj_id)   # headless text verb, no GUI
	await process_frame
	await process_frame
	_check("T: text verb bind_object_text mounted the SAME panel path", String(text_path) == String(bound_path))
	_check("T: text verb mounted the real panel in the room (same backend as the right-click)",
		GraphPanelMount.panel_is_open(room))
	var panel2 := GraphPanelMount.panel_of(room)
	_check("T: text-opened panel commits to the same arrangement file", panel2 != null and String(panel2.commit_path) == String(bound_path))

	# --- 4. DIFF-HOTLOAD (gate D): edit the mounted panel -> file re-serialises -> LiveHost diff-loads
	# A LiveHost pointed at the SAME file the panel commits to (what the running room's graph would watch).
	var host := LiveHost.new()
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	host.runtime = rt
	host.path = String(bound_path)
	get_root().add_child(host)
	host.poll_once()   # load the current (seed) arrangement
	_check("D: LiveHost loaded the seed arrangement (2 nodes live)", rt.nodes.size() == 2)
	var src_before = rt.nodes.get("src")   # identity we expect to be PRESERVED across a diff-hotload
	_check("D: the 'src' Const node is live before the edit", src_before != null)

	# EDIT via the real panel: drop the wire (disconnection), which _sync_from_graph + _commit re-serialise.
	# This is the exact code path a drag-disconnect in-world triggers.
	panel2.load_arrangement(JSON.parse_string(FileAccess.get_file_as_string(String(bound_path))))
	await process_frame
	var wires_before := (panel2.serialize().get("wires", []) as Array).size()
	# disconnect the single seed wire src.value -> act.value through the panel's own handler
	panel2.call("_on_disconnection_request", StringName("src"), 0, StringName("act"), _in_index(panel2, "act", "value"))
	await process_frame
	var committed = JSON.parse_string(FileAccess.get_file_as_string(String(bound_path)))
	var wires_after := (committed.get("wires", []) as Array).size()
	_check("D: editing the panel RE-SERIALISED the arrangement file (wire removed)",
		wires_before == 1 and wires_after == 0)
	# the running graph HOT-LOADS the edit as a diff: same node identities kept, only the wiring changed.
	var reloaded := host.poll_once()
	_check("D: LiveHost hot-loaded the edit (a reload fired on content change)", reloaded)
	var src_after = rt.nodes.get("src")
	_check("D: it was a DIFF, not a rebuild — the 'src' node kept its identity (same instance)",
		src_after != null and src_after == src_before)
	_check("D: both nodes are still live after the diff-hotload", rt.nodes.size() == 2)

	# --- 5. CONNECTION-ISOLATED-FAILURE (gate C): severing one wire kills exactly one behaviour -------
	# Re-seed a 2-wire arrangement: Const->WorldAction(log) AND Const->a second independent Log, so we can
	# sever ONE and prove the OTHER still runs. Written straight to the file + hot-loaded (the real path).
	# Const value is a STRING ("go") so it round-trips through the JSON file unambiguously (a JSON number
	# reloads as a float — 3 -> 3.0 — which would make the message assertion brittle; a string does not).
	var two := {
		"format": "resonance.arrangement/v1", "name": "isolation",
		"nodes": [
			{ "id": "k", "type": "Const", "params": { "value": "go" } },
			{ "id": "a", "type": "WorldAction", "params": { "op": "log" } },
			{ "id": "b", "type": "Log", "params": {} },
		],
		"wires": [
			{ "from": "k", "out": "value", "to": "a", "in": "value" },
			{ "from": "k", "out": "value", "to": "b", "in": "in" },
		],
	}
	_write_json(String(bound_path), two)
	host.poll_once()
	var o_full := rt.evaluate()
	var a_full: Dictionary = o_full.get("a", {}).get("result", {})
	_check("C: with both wires, the WorldAction behaviour fires (log got the value)",
		String(a_full.get("op")) == "log" and String(a_full.get("message")) == "go")
	# sever ONLY the wire into 'a'; 'b' keeps its wire.
	two["wires"] = [ { "from": "k", "out": "value", "to": "b", "in": "in" } ]
	_write_json(String(bound_path), two)
	host.poll_once()
	var o_cut := rt.evaluate()
	var a_cut: Dictionary = o_cut.get("a", {}).get("result", {})
	var b_node = rt.nodes.get("b")
	_check("C: severing a's wire killed EXACTLY a's behaviour (its input is now empty)",
		String(a_cut.get("message", "")) == "")
	_check("C: the OTHER node (b) still ran on its intact wire (isolated failure)",
		b_node != null and str(b_node.last_value) == "go")

	# --- 6. CLOSE -----------------------------------------------------------------------------------
	var closed := GraphPanelMount.close_panel(room)
	await process_frame
	_check("close_panel (ESC path) unmounted the overlay", closed and not GraphPanelMount.panel_is_open(room))
	_check("the room survived closing the panel", room.is_inside_tree())

	rt.free()
	room.queue_free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- helpers ---------------------------------------------------------------------------------------

func _graphnode_count(panel) -> int:
	var c := 0
	if panel == null:
		return 0
	for ch in panel.get_children():
		if ch is GraphNode:
			c += 1
	return c

func _in_index(panel, node_id: String, port_name: String) -> int:
	# mirror GraphPanel._in_index via its public port map (the seed 'act' node's 'value' input).
	var np: Dictionary = panel.get("_node_ports")
	var ins: Array = (np.get(node_id, {}) as Dictionary).get("inputs", [])
	for i in ins.size():
		if String(ins[i]["name"]) == port_name:
			return i
	return 0

func _write_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

func _rm_rf(abs_path: String) -> void:
	if not DirAccess.dir_exists_absolute(abs_path):
		return
	var d := DirAccess.open(abs_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir():
			_rm_rf(abs_path + "/" + f)
		else:
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs_path)
