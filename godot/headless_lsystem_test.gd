extends SceneTree
## HEADLESS TEST — the L-system module + primitive. Pure CPU. Pins the DATA contract the spec names:
## expected SYMBOL EXPANSION (exact strings + growth counts), turtle interpretation (segment counts,
## branch push/pop continuity, angles, radius decay), determinism + seed sensitivity for stochastic
## rules, and the primitive end-to-end through the real GraphRuntime with expected NODE COUNTS.
##
##   godot --headless --path godot -s res://headless_lsystem_test.gd

var _passed := 0
var _failed := 0

func _initialize() -> void:
	_test_expansion()
	_test_stochastic_seeded()
	_test_turtle()
	_test_scene_node()
	_test_primitive_end_to_end()
	var verdict := "ALL PASS" if _failed == 0 else "FAILURES"
	print("\n[lsystem_test] RESULT: %s  (%d passed, %d failed)" % [verdict, _passed, _failed])
	quit(0 if _failed == 0 else 1)

func _check(cond: bool, label: String) -> void:
	if cond:
		_passed += 1
		print("  ok   %s" % label)
	else:
		_failed += 1
		print("  FAIL %s" % label)

# ── symbol expansion ────────────────────────────────────────────────────────────────────────────────

func _test_expansion() -> void:
	_check(LSystem.expand("F", { "F": "F[+F]F" }, 0) == "F", "expand: depth 0 is the axiom")
	_check(LSystem.expand("F", { "F": "F[+F]F" }, 1) == "F[+F]F", "expand: depth 1 exact string")
	_check(LSystem.expand("F", { "F": "F[+F]F" }, 2) == "F[+F]F[+F[+F]F]F[+F]F",
		"expand: depth 2 exact string")
	# growth law: this rule triples the F count per iteration → 3^d.
	var d3 := LSystem.expand("F", { "F": "F[+F]F" }, 3)
	_check(d3.count("F") == 27, "expand: F count follows 3^d (27 at depth 3, got %d)" % d3.count("F"))
	# non-terminals pass through untouched when no rule names them.
	_check(LSystem.expand("XFX", { "F": "FF" }, 1) == "XFFX", "expand: symbols without rules pass through")
	# two-rule system (the classic bush pair): F doubles, X branches.
	var bush := LSystem.expand("X", { "X": "F[+X][-X]FX", "F": "FF" }, 2)
	_check(bush == "FF[+F[+X][-X]FX][-F[+X][-X]FX]FFF[+X][-X]FX",
		"expand: two-rule system rewrites both symbols in one pass")

# ── stochastic rules: deterministic under a seed, sensitive to it ───────────────────────────────────

func _test_stochastic_seeded() -> void:
	var rules := { "F": [[0.5, "F[+F]"], [0.5, "F[-F]"]] }
	var a := LSystem.expand("FFFFFF", rules, 3, 42)
	var b := LSystem.expand("FFFFFF", rules, 3, 42)
	_check(a == b, "stochastic: the same seed reproduces the same expansion")
	var c := LSystem.expand("FFFFFF", rules, 3, 43)
	_check(a != c, "stochastic: a different seed gives a different expansion")
	var only_plus := LSystem.expand("F", { "F": [[1.0, "F+F"], [0.0, "F-F"]] }, 1, 7)
	_check(only_plus == "F+F", "stochastic: zero-weight options are never chosen")

# ── turtle interpretation ───────────────────────────────────────────────────────────────────────────

func _test_turtle() -> void:
	var segs := LSystem.interpret("F[+F]F", { "step": 1.0, "angle_deg": 30.0 })
	_check(segs.size() == 3, "turtle: one segment per F (3)")
	# pop restores the pre-branch state: segment 3 starts exactly where segment 1 ended.
	var s1: Dictionary = segs[0]
	var s3: Dictionary = segs[2]
	_check(s3["a"] == s1["b"], "turtle: ] restores position (trunk continues from the branch point)")
	# bracket depth is recorded per segment.
	_check(int((segs[1] as Dictionary)["level"]) == 1 and int(s1["level"]) == 0,
		"turtle: bracket depth recorded as segment level")
	# +90° yaw makes the second segment perpendicular to the first.
	var perp := LSystem.interpret("F+F", { "step": 1.0, "angle_deg": 90.0 })
	var d1 := _dir(perp[0])
	var d2 := _dir(perp[1])
	_check(absf(d1.dot(d2)) < 0.0001, "turtle: +90 yaw → perpendicular segments (dot=%.5f)" % d1.dot(d2))
	# heading starts +Y (plants grow up).
	_check(d1.distance_to(Vector3.UP) < 0.0001, "turtle: initial heading is +Y")
	# ! tapers the radius; the taper is undone by ] (state restore).
	var taper := LSystem.interpret("F[!F]F", { "radius": 0.1, "radius_decay": 0.5 })
	_check(absf(float((taper[1] as Dictionary)["radius"]) - 0.05) < 0.0001,
		"turtle: ! multiplies radius by radius_decay inside the branch")
	_check(absf(float((taper[2] as Dictionary)["radius"]) - 0.1) < 0.0001,
		"turtle: ] restores the radius after the branch")
	# f moves without drawing.
	_check(LSystem.interpret("fFf", {}).size() == 1, "turtle: f moves without drawing")

# ── scene_node emission ─────────────────────────────────────────────────────────────────────────────

func _test_scene_node() -> void:
	var segs := LSystem.interpret("F[+F]F", { "step": 1.0, "angle_deg": 30.0, "radius": 0.05 })
	var node := LSystem.to_scene_node(segs, "test_plant")
	var kids: Array = node.get("children", [])
	_check(kids.size() == 3, "scene_node: one cylinder child per segment")
	var k0: Dictionary = kids[0]
	_check(String(k0["mesh"]["shape"]) == "cylinder", "scene_node: children are primitive cylinders")
	_check(absf(float(k0["mesh"]["params"]["height"]) - 1.0) < 0.0001, "scene_node: cylinder height = segment length")
	# the first (vertical) segment's midpoint is at y=0.5.
	_check(absf(float((k0["translation"] as Array)[1]) - 0.5) < 0.0001, "scene_node: cylinder sits at the segment midpoint")
	_check(typeof(JSON.parse_string(JSON.stringify(node))) == TYPE_DICTIONARY, "scene_node: pure JSON data")

# ── the primitive, end to end through the real runtime, with expected node counts ───────────────────

func _test_primitive_end_to_end() -> void:
	var arrangement := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "plant", "type": "LSystem", "params": {
				"axiom": "F", "rules": { "F": "F[+F]F" }, "depth": 3, "seed": 0,
				"turtle": { "step": 0.4, "angle_deg": 28.0, "radius": 0.04 } } },
		],
		"wires": [],
	}
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arrangement)
	var outputs := rt.evaluate()
	var node = outputs.get("plant", {}).get("node")
	_check(typeof(node) == TYPE_DICTIONARY, "primitive: LSystem evaluates to a scene_node")
	if typeof(node) == TYPE_DICTIONARY:
		var kids: Array = node.get("children", [])
		_check(kids.size() == 27, "primitive: node count matches the 3^d expansion (27, got %d)" % kids.size())
	# and the delegate actually builds it (the branching geometry is real, not just data).
	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, arrangement)
	var meshes := _count_meshes(renderer)
	_check(meshes == 27, "primitive: the delegate builds 27 mesh instances (got %d)" % meshes)
	rt.queue_free()
	renderer.queue_free()

func _count_meshes(n: Node) -> int:
	var c := 1 if n is MeshInstance3D else 0
	for ch in n.get_children():
		c += _count_meshes(ch)
	return c

func _dir(seg: Dictionary) -> Vector3:
	var a: Array = seg["a"]
	var b: Array = seg["b"]
	return (Vector3(b[0], b[1], b[2]) - Vector3(a[0], a[1], a[2])).normalized()
