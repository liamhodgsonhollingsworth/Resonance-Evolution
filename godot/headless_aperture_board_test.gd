extends SceneTree
## Headless verification of the Godot Aperture's DATA layer (the ApertureGraph adapter) — no
## window needed; pure-data normalization is proven here, the RENDER is proven separately by the
## windowed `--shot` PNG.
##
##   godot --headless --path godot -s res://headless_aperture_board_test.gd
##
## Proves the adapter normalizes BOTH artifact shapes to ONE canonical internal arrangement:
##   (a) RE-native {nodes,wires} normalizes to the expected internal shape,
##   (b) generic {nodes,edges} with from/to normalizes IDENTICALLY (same wires),
##   (c) source/target edge field names also map,
##   (d) a malformed/empty graph degrades gracefully (no crash, empty board),
## plus: field-map override retargets a foreign schema; the bundled sample loads; ports_for_node
## unions generic + explicit ports; edges referencing unknown nodes are dropped.

var _pass := 0
var _fail := 0

func _initialize() -> void:
	_test_re_native()
	_test_generic_from_to()
	_test_source_target()
	_test_generic_matches_native()
	_test_malformed_and_empty()
	_test_field_map_override()
	_test_explicit_ports()
	_test_unknown_node_edges_dropped()
	_test_bundled_sample_loads()

	var total := _pass + _fail
	print("RESULT: ", ("ALL PASS" if _fail == 0 else ("%d FAIL" % _fail)), "  (", _pass, "/", total, " checks)")
	quit(0 if _fail == 0 else 1)

# (a) RE-native {nodes:[{id,type,params}], wires:[{from,out,to,in}]} -> canonical.
func _test_re_native() -> void:
	var g := {
		"name": "native",
		"nodes": [
			{ "id": "a", "type": "Const", "params": { "value": 3 } },
			{ "id": "b", "type": "Log" },
		],
		"wires": [ { "from": "a", "out": "value", "to": "b", "in": "in" } ],
	}
	var arr := ApertureGraph.normalize(g)
	_check("native: format set", String(arr.get("format")) == "resonance.arrangement/v1")
	_check("native: 2 nodes", arr["nodes"].size() == 2)
	_check("native: node id+type preserved", String(arr["nodes"][0]["id"]) == "a" and String(arr["nodes"][0]["type"]) == "Const")
	_check("native: 1 wire", arr["wires"].size() == 1)
	var w: Dictionary = arr["wires"][0]
	_check("native: wire from/out/to/in preserved",
		String(w["from"]) == "a" and String(w["out"]) == "value" and String(w["to"]) == "b" and String(w["in"]) == "in")
	_check("native: label defaults to id", String(arr["nodes"][1]["label"]) == "b")

# (b) generic {nodes,edges} with from/to (no port names) -> generic out/in ports.
func _test_generic_from_to() -> void:
	var g := {
		"nodes": [ { "id": "x", "type": "system", "label": "X" }, { "id": "y", "type": "leaf" } ],
		"edges": [ { "from": "x", "to": "y" } ],
	}
	var arr := ApertureGraph.normalize(g)
	_check("generic: 2 nodes", arr["nodes"].size() == 2)
	_check("generic: label honored", String(arr["nodes"][0]["label"]) == "X")
	_check("generic: type honored", String(arr["nodes"][0]["type"]) == "system")
	_check("generic: 1 wire", arr["wires"].size() == 1)
	var w: Dictionary = arr["wires"][0]
	_check("generic: default ports out->in",
		String(w["from"]) == "x" and String(w["out"]) == "out" and String(w["to"]) == "y" and String(w["in"]) == "in")

# (c) source/target edge field names map to from/to.
func _test_source_target() -> void:
	var g := {
		"nodes": [ { "id": "p" }, { "id": "q" } ],
		"edges": [ { "source": "p", "target": "q" } ],
	}
	var arr := ApertureGraph.normalize(g)
	_check("source/target: 1 wire", arr["wires"].size() == 1)
	var w: Dictionary = arr["wires"][0]
	_check("source/target: mapped to from/to", String(w["from"]) == "p" and String(w["to"]) == "q")

# (b)==(c)/(a) shape: generic from/to and RE-native produce IDENTICAL wires for the same topology.
func _test_generic_matches_native() -> void:
	var native := {
		"nodes": [ { "id": "a", "type": "t" }, { "id": "b", "type": "t" } ],
		"wires": [ { "from": "a", "out": "out", "to": "b", "in": "in" } ],
	}
	var generic := {
		"nodes": [ { "id": "a", "type": "t" }, { "id": "b", "type": "t" } ],
		"edges": [ { "source": "a", "target": "b" } ],
	}
	var an := ApertureGraph.normalize(native)
	var ge := ApertureGraph.normalize(generic)
	_check("identical wires across shapes", JSON.stringify(an["wires"]) == JSON.stringify(ge["wires"]))

# (d) malformed / empty inputs degrade gracefully: valid empty arrangement, no crash.
func _test_malformed_and_empty() -> void:
	var empty := ApertureGraph.normalize({})
	_check("empty dict: valid arrangement", String(empty.get("format")) == "resonance.arrangement/v1")
	_check("empty dict: no nodes", empty["nodes"].size() == 0)
	_check("empty dict: no wires", empty["wires"].size() == 0)

	var nul := ApertureGraph.normalize(null)
	_check("null: empty board", nul["nodes"].size() == 0 and nul["wires"].size() == 0)

	var wrong := ApertureGraph.normalize([1, 2, 3])  # not a dict
	_check("array input: empty board", wrong["nodes"].size() == 0)

	var junk := ApertureGraph.normalize({
		"nodes": [ "not-a-dict", 42, { "id": "ok" } ],
		"edges": [ "bad", { "from": "ok" }, { "from": "ok", "to": "missing" } ],
	})
	_check("junk nodes: only the valid one survives", junk["nodes"].size() == 1 and String(junk["nodes"][0]["id"]) == "ok")
	_check("junk edges: all dropped (no valid targets)", junk["wires"].size() == 0)

# field-map override retargets a foreign schema (e.g. big_projects_graph.json) with no code change.
func _test_field_map_override() -> void:
	var foreign := {
		"nodes": [ { "uid": "n1", "category": "proj", "name": "Alpha" }, { "uid": "n2", "category": "proj" } ],
		"links": [ { "src": "n1", "dst": "n2" } ],
	}
	var fm := {
		"edges_keys": ["links"],
		"from_keys": ["src"],
		"to_keys": ["dst"],
		"id_keys": ["uid"],
		"type_keys": ["category"],
		"label_keys": ["name"],
	}
	var arr := ApertureGraph.normalize(foreign, fm)
	_check("override: nodes mapped", arr["nodes"].size() == 2 and String(arr["nodes"][0]["id"]) == "n1")
	_check("override: type+label mapped", String(arr["nodes"][0]["type"]) == "proj" and String(arr["nodes"][0]["label"]) == "Alpha")
	_check("override: edge mapped", arr["wires"].size() == 1 and String(arr["wires"][0]["from"]) == "n1" and String(arr["wires"][0]["to"]) == "n2")

# ports_for_node unions the generic in/out with any explicitly-named ports the wires use.
func _test_explicit_ports() -> void:
	var g := {
		"nodes": [ { "id": "a" }, { "id": "b" } ],
		"edges": [ { "from": "a", "out": "result", "to": "b", "in": "x" } ],
	}
	var arr := ApertureGraph.normalize(g)
	var pa := ApertureGraph.ports_for_node("a", arr)
	var pb := ApertureGraph.ports_for_node("b", arr)
	_check("explicit ports: a has named output 'result'", (pa["outputs"] as Array).has("result"))
	_check("explicit ports: b has named input 'x'", (pb["inputs"] as Array).has("x"))
	_check("explicit ports: generic 'in' still present on a", (pa["inputs"] as Array).has("in"))

# edges whose endpoints reference an unknown node are dropped (never fabricate nodes).
func _test_unknown_node_edges_dropped() -> void:
	var g := {
		"nodes": [ { "id": "a" } ],
		"edges": [ { "from": "a", "to": "ghost" }, { "from": "ghost", "to": "a" } ],
	}
	var arr := ApertureGraph.normalize(g)
	_check("unknown-node edges dropped", arr["wires"].size() == 0)

# the bundled sample (the out-of-the-box board content) is a valid graph.
func _test_bundled_sample_loads() -> void:
	var text := FileAccess.get_file_as_string("res://aperture/sample_graph.json")
	_check("sample: file present", text != "")
	var data = JSON.parse_string(text)
	var arr := ApertureGraph.normalize(data)
	_check("sample: 6 nodes", arr["nodes"].size() == 6)
	_check("sample: 6 edges", arr["wires"].size() == 6)
	# every wire endpoint resolves to a real node id (board would render every edge).
	var ids := {}
	for n in arr["nodes"]:
		ids[String(n["id"])] = true
	var all_resolve := true
	for w in arr["wires"]:
		if not ids.has(String(w["from"])) or not ids.has(String(w["to"])):
			all_resolve = false
	_check("sample: all wires resolve to nodes", all_resolve)

func _check(label: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("PASS ", label)
	else:
		_fail += 1
		print("FAIL ", label)
