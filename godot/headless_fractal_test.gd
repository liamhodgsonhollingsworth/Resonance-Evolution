class_name FractalTest
extends SceneTree
## Headless verification of FRACTAL PRIMITIVES — the core law "there are no fundamental
## primitives" (frame-relative primitiveness, retroactive decomposition, no privileged
## universal bottom). Run:
##
##   godot --headless --path godot -s res://headless_fractal_test.gd
##
## Fixture (a faithful arithmetic tower over EXISTING primitives):
##   Quad(x)   leaf = x * 4     decomposition = Double -> Double
##   Double(x) leaf = x * 2     decomposition = Math(add) with a -> both inputs  (x + x)
## So Quad decomposes into two Doubles, each of which decomposes into a Math.add — three
## frames deep, every level computing the SAME value. The top arrangement is a single Quad
## fed a Const 5 (= 20). We then OBSERVE that same loaded graph at different frames.
##
## Instrumented leaves bump `_evals` so we can see WHICH primitives actually fire at each
## frame — the structural fingerprint that proves primitiveness is frame-relative, while the
## value stays invariant. Mirrors headless_chip_test.gd style (PASS/FAIL, RESULT, exit code).

# type name -> times its leaf.evaluate() ran. Reached by the inner leaf classes below from
# wherever in the descent tree they are instantiated (a global static, so descent leaves count
# too — top-level-only instrumentation would miss them).
static var _evals: Dictionary = {}

# --- instrumented leaf primitives (test-only; registered into a Definitions store, NOT into
#     the global registry, so they never pollute the real primitive set) -------------------

class DoubleLeaf extends Primitive:
	func _init() -> void:
		prim_type = "Double"
	func input_ports() -> Array:
		return [{ "name": "a", "type": "number" }]
	func output_ports() -> Array:
		return [{ "name": "result", "type": "number" }]
	func evaluate(inputs: Dictionary) -> Dictionary:
		FractalTest._bump("Double")
		return { "result": as_num(inputs.get("a")) * 2.0 }

class QuadLeaf extends Primitive:
	func _init() -> void:
		prim_type = "Quad"
	func input_ports() -> Array:
		return [{ "name": "a", "type": "number" }]
	func output_ports() -> Array:
		return [{ "name": "result", "type": "number" }]
	func evaluate(inputs: Dictionary) -> Dictionary:
		FractalTest._bump("Quad")
		return { "result": as_num(inputs.get("a")) * 4.0 }

static func _bump(t: String) -> void:
	_evals[t] = int(_evals.get(t, 0)) + 1

# --- decomposition definitions (data) --------------------------------------------------

# Double(x) = x + x : one Math(add) node, the single outer port "a" fanned into BOTH inputs.
static func _double_decomp() -> Dictionary:
	return {
		"arrangement": {
			"format": "resonance.arrangement/v1",
			"nodes": [ { "id": "sum", "type": "Math", "params": { "op": "add" } } ],
			"wires": [],
		},
		"ports": {
			"inputs": [
				{ "name": "a", "node": "sum", "port": "a" },
				{ "name": "a", "node": "sum", "port": "b" },
			],
			"outputs": [ { "name": "result", "node": "sum", "port": "result" } ],
		},
	}

# Quad(x) = Double(Double(x)) : two Double nodes chained.
static func _quad_decomp() -> Dictionary:
	return {
		"arrangement": {
			"format": "resonance.arrangement/v1",
			"nodes": [
				{ "id": "d1", "type": "Double", "params": {} },
				{ "id": "d2", "type": "Double", "params": {} },
			],
			"wires": [ { "from": "d1", "out": "result", "to": "d2", "in": "a" } ],
		},
		"ports": {
			"inputs": [ { "name": "a", "node": "d1", "port": "a" } ],
			"outputs": [ { "name": "result", "node": "d2", "port": "result" } ],
		},
	}

# The graph under observation: Const 5 -> Quad. Loaded ONCE; never edited below.
static func _top() -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "k", "type": "Const", "params": { "value": 5 } },
			{ "id": "q", "type": "Quad", "params": {} },
		],
		"wires": [ { "from": "k", "out": "value", "to": "q", "in": "a" } ],
	}

func _initialize() -> void:
	var ok := true

	# A store with the two instrumented leaves; decompositions attached separately so we can
	# show retroactivity (register them AFTER an undecomposed run, same loaded runtime).
	var store := Definitions.new()
	store.register_leaf("Double", DoubleLeaf)
	store.register_leaf("Quad", QuadLeaf)

	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.definitions = store
	rt.load_arrangement(_top())

	# --- (1) No decompositions yet: a Quad is just a leaf at every frame -------------------
	# Even with a deep frame, with nothing to descend into Quad stays operational (no
	# privileged bottom is *forced*; leaf-ness holds where no decomposition exists).
	_evals = {}
	rt.descend_budget = 9
	var pre = _qval(rt)
	ok = _check("undecomposed Quad => 20 even at deep frame", _is(pre, 20.0)) and ok
	ok = _check("undecomposed: only the Quad leaf fires", _evals.get("Quad", 0) == 1 and _evals.get("Double", 0) == 0) and ok

	# --- (2) RETROACTIVE decomposition: attach internals to types already in use -----------
	# No edit to the loaded arrangement; we only populate the store. Existing `q`/`d*`
	# instances become descendable purely by re-observing at a deeper frame.
	store.register_decomposition("Double", _double_decomp()["arrangement"], _double_decomp()["ports"])
	store.register_decomposition("Quad", _quad_decomp()["arrangement"], _quad_decomp()["ports"])

	# --- (3) FRAME-RELATIVE primitiveness: same graph, same value, different "primitives" ---
	# frame 0 — observe flat: Quad is the primitive.
	_evals = {}
	rt.descend_budget = 0
	var f0 = _qval(rt)
	ok = _check("frame 0 => 20", _is(f0, 20.0)) and ok
	ok = _check("frame 0: Quad leaf is the primitive", _evals.get("Quad", 0) == 1 and _evals.get("Double", 0) == 0) and ok

	# frame 1 — descend one level: Quad dissolves into two Doubles, which are now the primitives.
	_evals = {}
	rt.descend_budget = 1
	var f1 = _qval(rt)
	ok = _check("frame 1 => 20 (value invariant)", _is(f1, 20.0)) and ok
	ok = _check("frame 1: Quad gone, two Double leaves fire", _evals.get("Quad", 0) == 0 and _evals.get("Double", 0) == 2) and ok

	# frame 2 — descend two levels: Doubles dissolve into Math.add; neither Quad nor Double
	# fires — the computation is now carried entirely by deeper primitives (Math), proving the
	# bottom moved with the frame.
	_evals = {}
	rt.descend_budget = 2
	var f2 = _qval(rt)
	ok = _check("frame 2 => 20 (value invariant)", _is(f2, 20.0)) and ok
	ok = _check("frame 2: neither Quad nor Double fires (work fell through to Math)",
		_evals.get("Quad", 0) == 0 and _evals.get("Double", 0) == 0) and ok

	# --- (4) NO PRIVILEGED UNIVERSAL BOTTOM: descend past the deepest decomposition ---------
	# Math has no decomposition, so frames 2, 3, 5 all bottom out at the Math leaves and agree.
	# There is no special universal bottom — descent simply terminates at whatever operational
	# leaves remain at the chosen depth.
	rt.descend_budget = 3
	var f3 = _qval(rt)
	rt.descend_budget = 5
	var f5 = _qval(rt)
	ok = _check("frames 2/3/5 all => 20 (graceful bottoming, no forced universal floor)",
		_is(f2, 20.0) and _is(f3, 20.0) and _is(f5, 20.0)) and ok

	# --- (5) FAITHFULNESS: a decomposition must honor its type's leaf I/O contract ---------
	ok = _check("Double decomposition preserves leaf port names",
		_ports_match(DoubleLeaf.new(), _double_decomp()["ports"])) and ok
	ok = _check("Quad decomposition preserves leaf port names",
		_ports_match(QuadLeaf.new(), _quad_decomp()["ports"])) and ok

	# --- (6) Default is untouched: a runtime with NO store behaves exactly as before --------
	var plain := GraphRuntime.new()
	get_root().add_child(plain)
	plain.descend_budget = 9   # ignored: no store attached
	plain.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "a", "type": "Const", "params": { "value": 3 } },
			{ "id": "b", "type": "Const", "params": { "value": 4 } },
			{ "id": "m", "type": "Math", "params": { "op": "add" } },
		],
		"wires": [
			{ "from": "a", "out": "value", "to": "m", "in": "a" },
			{ "from": "b", "out": "value", "to": "m", "in": "b" },
		],
	})
	var classic = plain.evaluate().get("m", {}).get("result")
	ok = _check("no-store runtime is classic flat behavior (3+4 => 7)", _is(classic, 7.0)) and ok
	get_root().remove_child(plain)
	plain.free()

	get_root().remove_child(rt)
	rt.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ---------------------------------------------------------------

func _qval(rt: GraphRuntime):
	return rt.evaluate().get("q", {}).get("result")

func _is(v, expected: float) -> bool:
	return v != null and abs(Primitive.as_num(v) - expected) < 1e-9

# A decomposition is faithful to its leaf only if it exposes the same outer port names.
func _ports_match(leaf: Primitive, ports: Dictionary) -> bool:
	return _names(leaf.input_ports()) == _names_from_ports(ports.get("inputs", [])) \
		and _names(leaf.output_ports()) == _names_from_ports(ports.get("outputs", []))

func _names(port_list: Array) -> Array:
	var s := {}
	for p in port_list:
		s[String(p.get("name"))] = true
	var keys := s.keys()
	keys.sort()
	return keys

func _names_from_ports(port_list: Array) -> Array:
	var s := {}
	for p in port_list:
		s[String(p.get("name"))] = true
	var keys := s.keys()
	keys.sort()
	return keys

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
