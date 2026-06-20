class_name SceneFractalTest
extends SceneTree
## FRACTAL PRIMITIVES on the SCENE / glTF substrate — the second half of the law "there are no
## fundamental primitives", proven on the engine's OTHER graph (3D scene_node data, not just
## arithmetic). Run:
##
##   godot --headless --path godot -s res://headless_scene_fractal_test.gd
##
## Same mechanism as headless_fractal_test.gd (Definitions + frame-relative descent), now over
## scene_node DATA — descend() is value-agnostic (Dictionary pass-through), so it needs NO core
## change. A "Body" is observed as ONE primitive mesh at a shallow frame; descend a frame and it
## dissolves into its part-meshes — the same loaded graph, re-observed.
##
## The decomposition is a real arrangement of ALREADY-LOADED primitives (Model -> Transform ->
## Group); only the decomposed TYPE ("Body") is a store-only fixture leaf (never the global
## registry). The invariant is RENDERED GEOMETRY, not a structural echo of the arithmetic test:
## both frames are rendered through GodotSceneRenderer and the mesh WORLD positions are checked
## (frame 0 = one mesh at origin; frame 1 = two meshes at A and B). Faithfulness for scene data is
## measured honestly — two offset part-boxes do NOT equal one box, so we assert the parts are
## present at their declared positions, the same loaded graph, not pixel-identical geometry.
## Mirrors the suite style (PASS/FAIL, RESULT, exit code) and reuses headless_compose_test.gd's
## render-harness helpers.

const A := [-1.5, 0.0, 0.0]
const B := [1.5, 0.0, 0.0]

# type name -> times its leaf.evaluate() ran (global static so descent leaves count too).
static var _evals: Dictionary = {}
static var _glb_path: String = ""

static func _bump(t: String) -> void:
	_evals[t] = int(_evals.get(t, 0)) + 1

# --- the decomposed TYPE: a store-only fixture leaf (NOT the global registry). Its leaf is ONE
#     box mesh at the origin — the "treat-as-primitive at a shallow frame" view. ---------------
class BodyLeaf extends Primitive:
	func _init() -> void:
		prim_type = "Body"
	func output_ports() -> Array:
		return [{ "name": "node", "type": "scene_node" }]
	func evaluate(_inputs: Dictionary) -> Dictionary:
		SceneFractalTest._bump("Body")
		return { "node": {
			"name": "body",
			"translation": [0.0, 0.0, 0.0],
			"rotation": [0.0, 0.0, 0.0, 1.0],
			"scale": [1.0, 1.0, 1.0],
			"mesh": { "source": "glb", "path": SceneFractalTest._glb_path },
			"children": [],
		} }

# Body(x) decomposed = two box parts (Model) placed at A and B (Transform) under one Group —
# a genuine arrangement of already-registered primitives. Body has no inputs, so it sidesteps
# v0's type-keyed-decomposition limit exactly as the arithmetic fixture did.
func _body_decomp() -> Dictionary:
	return {
		"arrangement": {
			"format": "resonance.arrangement/v1",
			"nodes": [
				{ "id": "m1", "type": "Model", "params": { "path": _glb_path, "name": "part_a" } },
				{ "id": "m2", "type": "Model", "params": { "path": _glb_path, "name": "part_b" } },
				{ "id": "t1", "type": "Transform", "params": { "position": A } },
				{ "id": "t2", "type": "Transform", "params": { "position": B } },
				{ "id": "g", "type": "Group", "params": { "count": 2, "name": "body_parts" } },
			],
			"wires": [
				{ "from": "m1", "out": "node", "to": "t1", "in": "node" },
				{ "from": "m2", "out": "node", "to": "t2", "in": "node" },
				{ "from": "t1", "out": "node", "to": "g", "in": "in_0" },
				{ "from": "t2", "out": "node", "to": "g", "in": "in_1" },
			],
		},
		"ports": {
			"inputs": [],
			"outputs": [ { "name": "node", "node": "g", "port": "node" } ],
		},
	}

# The graph under observation: a single Body. Loaded ONCE; never edited below.
func _top() -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [ { "id": "body", "type": "Body", "params": {} } ],
		"wires": [],
	}

func _initialize() -> void:
	var ok := true
	_glb_path = "user://scene_fractal_box.glb"
	ok = _check("box GLB fixture exported", _make_box_glb(_glb_path) == OK) and ok

	var store := Definitions.new()
	store.register_leaf("Body", BodyLeaf)

	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.definitions = store
	var top := _top()
	rt.load_arrangement(top)

	# --- (1) No decomposition yet: a Body is atomic at EVERY frame --------------------------
	_evals = {}
	var deep := _eval(rt, 5)
	var gd := _render_globals(deep, top)
	ok = _check("undecomposed Body renders 1 mesh at origin even at deep frame",
		gd.size() == 1 and _has_origin(gd, Vector3.ZERO)) and ok

	# --- (2) RETROACTIVE decomposition: attach internal part-structure to a type in use ------
	# No edit to the loaded arrangement; only the store is populated. The same `body` instance
	# becomes descendable purely by re-observing at a deeper frame.
	var d := _body_decomp()
	store.register_decomposition("Body", d["arrangement"], d["ports"])

	# --- (3) FRAME 0 (atomic): even WITH a decomposition attached, budget 0 stays primitive ---
	_evals = {}
	var out0 := _eval(rt, 0)
	var body0 = out0.get("body", {}).get("node")
	ok = _check("frame 0 data: Body is one mesh, no children (atomic)",
		typeof(body0) == TYPE_DICTIONARY and body0.get("mesh") != null
		and (body0.get("children", []) as Array).is_empty()) and ok
	var g0 := _render_globals(out0, top)
	ok = _check("frame 0 renders 1 mesh at origin", g0.size() == 1 and _has_origin(g0, Vector3.ZERO)) and ok
	ok = _check("frame 0: the Body leaf is the primitive (fired once)", _evals.get("Body", 0) == 1) and ok

	# --- (4) FRAME 1 (descended): the SAME graph dissolves Body into its parts ---------------
	_evals = {}
	var out1 := _eval(rt, 1)
	var body1 = out1.get("body", {}).get("node")
	ok = _check("frame 1 data: Body is a transform-only parent with 2 children (decomposed)",
		typeof(body1) == TYPE_DICTIONARY and body1.get("mesh") == null
		and (body1.get("children", []) as Array).size() == 2) and ok
	ok = _check("frame 1: the Body leaf did NOT fire (it decomposed)", _evals.get("Body", 0) == 0) and ok
	var g1 := _render_globals(out1, top)
	ok = _check("frame 1 renders 2 meshes, at A and B (parts are now the primitives)",
		g1.size() == 2 and _has_origin(g1, Vector3(A[0], A[1], A[2])) and _has_origin(g1, Vector3(B[0], B[1], B[2]))) and ok

	# --- (5) NO PRIVILEGED UNIVERSAL BOTTOM: a part (Model) has no decomposition -------------
	# Frames 1/2/5 all bottom out at the part meshes and agree — descent terminates at whatever
	# operational leaves remain at the chosen depth, no forced floor.
	var g2 := _render_globals(_eval(rt, 2), top)
	var g5 := _render_globals(_eval(rt, 5), top)
	ok = _check("frames 1/2/5 all render the same 2 parts at A and B (graceful bottoming)",
		_two_at_ab(g1) and _two_at_ab(g2) and _two_at_ab(g5)) and ok

	# --- (6) PORTABILITY: the descended scene is portable glTF (lands on the spine) ----------
	var bytes := GltfExporter.export_buffer([body1]) if typeof(body1) == TYPE_DICTIONARY else PackedByteArray()
	var imp = _reimport(bytes)
	var gimp := _collect_mesh_globals(imp, Transform3D.IDENTITY) if imp != null else []
	ok = _check("decomposed scene exports to GLB and re-imports with both parts at A and B",
		imp != null and _two_at_ab(gimp)) and ok
	if imp != null:
		imp.free()

	get_root().remove_child(rt)
	rt.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ---------------------------------------------------------------

func _eval(rt: GraphRuntime, budget: int) -> Dictionary:
	rt.descend_budget = budget
	return rt.evaluate()

# Render an evaluate() output through a FRESH delegate and return the world transforms of every
# built mesh. Fresh per call so each frame's render is independent (no hotload pruning to reason
# about); the returned Array holds plain Transform3D values, so freeing the delegate is safe.
func _render_globals(eval_output: Dictionary, arrangement: Dictionary) -> Array:
	var r := GodotSceneRenderer.new()
	get_root().add_child(r)
	r.render(eval_output, arrangement)
	var g := _collect_mesh_globals(r, Transform3D.IDENTITY)
	get_root().remove_child(r)
	r.free()
	return g

func _two_at_ab(globals: Array) -> bool:
	return globals.size() == 2 \
		and _has_origin(globals, Vector3(A[0], A[1], A[2])) \
		and _has_origin(globals, Vector3(B[0], B[1], B[2]))

func _reimport(bytes: PackedByteArray):
	if bytes.size() == 0:
		return null
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_buffer(bytes, "", st) != OK:
		return null
	return doc.generate_scene(st)

# --- reused verbatim from headless_compose_test.gd (the render harness) ---------------------

func _collect_mesh_globals(node: Node, parent_global: Transform3D) -> Array:
	var out := []
	var g := parent_global
	if node is Node3D:
		g = parent_global * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(g)
	for c in node.get_children():
		out.append_array(_collect_mesh_globals(c, g))
	return out

func _has_origin(globals: Array, v: Vector3) -> bool:
	for t in globals:
		if (t as Transform3D).origin.is_equal_approx(v):
			return true
	return false

func _make_box_glb(path: String) -> int:
	var root := Node3D.new()
	root.name = "BoxRoot"
	var mi := MeshInstance3D.new()
	mi.name = "Box"
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
