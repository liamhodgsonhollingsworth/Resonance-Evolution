extends SceneTree
## NODE-GENOME EVOLVER CORE — headless acceptance suite (Liam verbatim spec 2026-07-03 §2, the
## node-genome model paragraphs). Real assertions, PASS/FAIL tally, nonzero exit on fail.
##   godot --headless --path godot -s res://headless_node_genome_test.gd
##
## What it proves:
##  1. The NODE-GENOME model: an artifact is a collection of nodes where CONNECTIONS ARE ALSO
##     NODES (endpoint refs + their own evolvable params); FIXED nodes are never touched by 30
##     hammered mutations (params byte-stable, never dropped, never rewired); VARIABLE parts
##     reshuffle (structural add/drop/rewire/swap fire and stay schema-valid); JSON round-trip.
##  2. CONCENTRATING ADAPTIVE DISTRIBUTIONS: sigma shrinks per evolution and floors ABOVE zero
##     (zero variance forbidden); categorical floors keep every option alive; the fixed-weight
##     heavy tail still produces dramatic outward draws from a deeply-concentrated state.
##  3. GRANULARITY AS DATA: fixed-bin quantization bounds distinct draws; the adaptive grid
##     COARSENS wide distributions and REFINES as evolution concentrates; "off" is continuous.
##  4. DETERMINISM: same seed ⇒ identical mutate output and identical full convergence runs.
##  5. COMBINATIONAL RESHUFFLING: multi-parent (3-way) recombine mixes genes from ≥2 parents;
##     kinds never interbreed; the existing breed algebra drives kind "node" unchanged.
##  6. THE CONVERGENCE HARNESS (the acceptance metric): simulated selection toward a target
##     inside the possibility space converges, measured in generations + wall-time, and the
##     concentrating distributions converge FASTER than a uniform-mutation baseline.
##  7. ADVERSARIAL: premature-concentration trap — after deep concentration on target A the
##     heavy tails still escape to a moved target B.
##  8. THE HELPER-NODE SEAM: helper_momentum applies ONLY where its condition matches, its
##     velocity state serializes, and the helper-carrying genome still converges.

var _pass := 0
var _fail := 0

func _check(name: String, cond: bool) -> bool:
	if cond:
		_pass += 1
		print("  PASS  ", name)
	else:
		_fail += 1
		print("  FAIL  ", name)
	return cond

func _initialize() -> void:
	print("=== node-genome evolver core test ===")
	_test_model_and_fixed_nodes()
	_test_distributions()
	_test_granularity()
	_test_determinism()
	_test_recombination_and_breed()
	_test_convergence_harness()
	_test_helper_seam()
	print("=== %d passed, %d failed ===" % [_pass, _fail])
	# Standard battery sentinel (run_all_tests.py classifies on "RESULT: ALL PASS" / "… N FAIL").
	print("RESULT: %s" % ("ALL PASS" if _fail == 0 else "%d PASS, %d FAIL" % [_pass, _fail]))
	quit(0 if _fail == 0 else 1)

# ---------------------------------------------------------------------------------------------------
# 1. the node-genome model
# ---------------------------------------------------------------------------------------------------

func _test_model_and_fixed_nodes() -> void:
	print("-- 1. node-genome model: connections-as-nodes, fixed vs variable, closure --")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260703
	var g := NodeGenome.random(3, rng)
	_check("random node genome is valid", g.is_valid())
	_check("random(3) has 3 payload nodes", g._payload_ids(g.nodes).size() == 3)

	# Connections are NODES: they live in the node list, carry endpoint refs AND their own
	# params + distribution states (a wire has genes).
	var conn = null
	for nd in g.nodes:
		if g._is_connection(String(nd.get("type", ""))):
			conn = nd
			break
	_check("a connection-node exists in the node collection", conn != null)
	if conn != null:
		_check("connection-node has endpoint refs", String(conn.get("from", "")) != "" and String(conn.get("to", "")) != "")
		_check("connection-node carries its own params", (conn.get("params", {}) as Dictionary).has("weight"))
		_check("connection-node params have distribution state", (conn.get("dist", {}) as Dictionary).has("weight"))

	# JSON round-trip through the "node_graph" descriptor.
	var rt := NodeGenome.from_stack(JSON.parse_string(JSON.stringify(g.to_stack())))
	_check("NodeGenome round-trips through JSON unchanged",
		JSON.stringify(rt.to_stack()) == JSON.stringify(g.to_stack()))

	# Sanitize: unknown types dropped, dangling connections dropped, out-of-range params clamped.
	var dirty := NodeGenome.from_stack({ "node_graph": { "nodes": [
		{ "id": "a", "type": "not_a_type", "params": {} },
		{ "id": "b", "type": "transform", "params": { "gain": 99.0, "curve": "not_a_curve" } },
		{ "id": "c", "type": "link", "from": "b", "to": "ghost", "params": {} },
	] } })
	_check("sanitize drops unknown node types", dirty.find_node("a") == null)
	_check("sanitize clamps out-of-range numeric genes",
		absf(float((dirty.find_node("b") as Dictionary)["params"]["gain"]) - 2.0) < 0.0001)
	_check("sanitize snaps unknown enum genes to a declared option",
		(dirty.find_node("b") as Dictionary)["params"]["curve"] == "linear")
	_check("sanitize drops connection-nodes with dangling endpoints", dirty.find_node("c") == null)

	# FIXED nodes are untouchable + VARIABLE parts reshuffle: hammer 30 mutations at high
	# structural rate; the fixed payload node and the fixed connection-node stay byte-identical.
	var hammer := NodeGenome.new(g.to_stack()["node_graph"]["nodes"], g.schema, { "p_structural": 0.9 })
	hammer = hammer.with_fixed("p0", true)
	var fixed_conn_id := ""
	for nd in hammer.nodes:
		if hammer._is_connection(String(nd.get("type", ""))):
			fixed_conn_id = String(nd.get("id", ""))
			break
	if fixed_conn_id != "":
		hammer = hammer.with_fixed(fixed_conn_id, true)
	var hammer_before := JSON.stringify(hammer.to_stack())
	var p0_before := JSON.stringify((hammer.find_node("p0") as Dictionary).get("params", {}))
	var conn_before: Dictionary = hammer.find_node(fixed_conn_id)
	var conn_sig := JSON.stringify({ "f": conn_before.get("from"), "t": conn_before.get("to"), "p": conn_before.get("params") })
	var m := hammer
	var closure_ok := true
	var fixed_ok := true
	var sizes := {}
	for _i in 30:
		m = m.mutate(rng)
		sizes[m.size()] = true
		if not m.is_valid() or not _all_genes_in_schema(m):
			closure_ok = false
			break
		var p0 = m.find_node("p0")
		var fc = m.find_node(fixed_conn_id)
		if p0 == null or fc == null \
				or JSON.stringify((p0 as Dictionary).get("params", {})) != p0_before \
				or JSON.stringify({ "f": (fc as Dictionary).get("from"), "t": (fc as Dictionary).get("to"), "p": (fc as Dictionary).get("params") }) != conn_sig:
			fixed_ok = false
			break
	_check("30 hammered mutations stay CLOSED over the schema (valid + in-range genes)", closure_ok)
	_check("FIXED payload node + FIXED connection-node byte-stable through 30 mutations", fixed_ok)
	_check("structural reshuffling fired (node count varied across mutations)", sizes.size() > 1)
	_check("mutate returns NEW genomes (the 30x-mutated source is byte-untouched)",
		JSON.stringify(hammer.to_stack()) == hammer_before)
	_check("mutation never empties the payload", m._payload_ids(m.nodes).size() >= 1)

# ---------------------------------------------------------------------------------------------------
# 2. concentrating adaptive distributions
# ---------------------------------------------------------------------------------------------------

func _test_distributions() -> void:
	print("-- 2. concentrating distributions: shrink, floors, heavy tails --")
	var cfg := {}
	var s := ParamDist.init_scalar(0.0, 1.0, 0.5, "float", cfg)
	var sigma0 := ParamDist.effective_sigma(s)
	_check("initial sigma = sigma0_frac * range", absf(sigma0 - 0.25) < 0.0001)

	# Concentration shrinks sigma monotonically...
	var s1 := ParamDist.concentrate(s, 0.5, cfg)
	var s2 := ParamDist.concentrate(s1, 0.5, cfg)
	_check("each evolution shrinks the core (sigma decays)",
		ParamDist.effective_sigma(s1) < sigma0 and ParamDist.effective_sigma(s2) < ParamDist.effective_sigma(s1))
	_check("depth counts concentration steps", int(s2.get("depth", 0)) == 2)
	_check("concentration re-centers on the realized value",
		absf(float(ParamDist.concentrate(s, 0.83, cfg)["mu"]) - 0.83) < 0.0001)

	# ...but NEVER to zero (zero variance forbidden), even after 200 evolutions.
	var deep := s
	for _i in 200:
		deep = ParamDist.concentrate(deep, 0.5, cfg)
	_check("ADVERSARIAL zero-variance forbidden: sigma floors at sigma_min_frac * range > 0",
		absf(ParamDist.effective_sigma(deep) - 0.01) < 0.0001 and ParamDist.effective_sigma(deep) > 0.0)

	# Heavy tail: from that deeply-concentrated state, dramatic outward draws still happen with
	# the FIXED tail weight (change probability never reaches zero).
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var far := 0
	for _i in 2000:
		var v := float(ParamDist.draw(deep, cfg, rng))
		if absf(v - 0.5) > 0.3:
			far += 1
	_check("heavy tail: dramatic moves (>0.3 from mu) persist after 200 concentrations (got %d/2000)" % far,
		far >= 20)

	# Categorical: concentration ratchets the realized option's weight; the uniform floor keeps
	# every option alive forever.
	var c := ParamDist.init_categorical(["a", "b", "c"], "", cfg)
	var cdeep := c
	for _i in 200:
		cdeep = ParamDist.concentrate(cdeep, "a", cfg)
	var w: Array = cdeep["weights"]
	_check("categorical concentration ratchets the realized option", float(w[0]) > 0.99)
	_check("categorical floor: min sampling probability = tail_w/n > 0",
		ParamDist.min_option_prob(cdeep, cfg) > 0.03)
	var saw_other := false
	for _i in 2000:
		if String(ParamDist.draw(cdeep, cfg, rng)) != "a":
			saw_other = true
			break
	_check("non-modal options still get drawn from a fully-concentrated categorical", saw_other)

# ---------------------------------------------------------------------------------------------------
# 3. granularity / approximation layer (resolution as DATA)
# ---------------------------------------------------------------------------------------------------

func _test_granularity() -> void:
	print("-- 3. granularity: fixed bins, adaptive coarsen/refine, continuous --")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var s := ParamDist.init_scalar(0.0, 1.0, 0.5, "float", {})

	var fixed_cfg := { "grid": { "mode": "fixed", "bins": 8 } }
	var distinct := {}
	for _i in 500:
		distinct[ParamDist.draw(s, fixed_cfg, rng)] = true
	_check("fixed grid (8 bins) bounds draws to <= 9 distinct values (got %d)" % distinct.size(),
		distinct.size() <= 9)

	var adaptive_cfg := { "grid": { "mode": "adaptive", "step_frac": 0.25, "min_step_frac": 0.001 } }
	var step_wide := ParamDist.grid_step(s, adaptive_cfg)
	var deep := s
	for _i in 20:
		deep = ParamDist.concentrate(deep, 0.5, adaptive_cfg)
	var step_fine := ParamDist.grid_step(deep, adaptive_cfg)
	_check("adaptive grid: coarse while exploring (step %.4f), refined once concentrated (step %.4f)" % [step_wide, step_fine],
		step_wide > step_fine and step_fine > 0.0)

	var off_cfg := { "grid": { "mode": "off" } }
	var distinct2 := {}
	for _i in 500:
		distinct2[ParamDist.draw(s, off_cfg, rng)] = true
	_check("grid off = exact continuous math (%d distinct draws)" % distinct2.size(), distinct2.size() >= 400)

	# Resolution rides ON the genome as data and survives serialization.
	var g := NodeGenome.random(2, rng, NodeGenome.DEFAULT_SCHEMA, { "grid": { "mode": "fixed", "bins": 16 } })
	var rt := NodeGenome.from_stack(JSON.parse_string(JSON.stringify(g.to_stack())))
	_check("granularity config serializes with the genome",
		int(((rt.config.get("grid", {}) as Dictionary)).get("bins", 0)) == 16)

# ---------------------------------------------------------------------------------------------------
# 4. determinism
# ---------------------------------------------------------------------------------------------------

func _test_determinism() -> void:
	print("-- 4. determinism: seeded evolution is reproducible --")
	var r1 := RandomNumberGenerator.new(); r1.seed = 99
	var r2 := RandomNumberGenerator.new(); r2.seed = 99
	var a := NodeGenome.random(3, r1)
	var b := NodeGenome.random(3, r2)
	_check("same seed => identical random genome", JSON.stringify(a.to_stack()) == JSON.stringify(b.to_stack()))
	var ma := a.mutate(r1)
	var mb := b.mutate(r2)
	_check("same seed => identical mutation", JSON.stringify(ma.to_stack()) == JSON.stringify(mb.to_stack()))

	var run1 := _run_convergence(4242, {})
	var run2 := _run_convergence(4242, {})
	_check("same seed => identical full convergence run (gens %d == %d, final genomes equal)" % [run1["gens"], run2["gens"]],
		run1["gens"] == run2["gens"]
		and JSON.stringify((run1["best"] as NodeGenome).to_stack()) == JSON.stringify((run2["best"] as NodeGenome).to_stack()))

# ---------------------------------------------------------------------------------------------------
# 5. combinational reshuffling + breed-algebra plumbing
# ---------------------------------------------------------------------------------------------------

func _test_recombination_and_breed() -> void:
	print("-- 5. multi-parent recombine, kind isolation, breed plumbing --")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260704

	# Three parents: same structure, per-parent distinctive scalar values — the 3-way recombine
	# must mix genes from at least two of them (combinational reshuffling within a generation).
	var proto := NodeGenome.random(3, rng, NodeGenome.DEFAULT_SCHEMA, { "p_structural": 0.0 })
	var parents := []
	var marks := [0.1, 0.5, 0.9]
	for mi in 3:
		var nodes: Array = proto.to_stack()["node_graph"]["nodes"]
		for nd in nodes:
			var pschema: Dictionary = ((NodeGenome.DEFAULT_SCHEMA["types"] as Dictionary).get(String((nd as Dictionary)["type"]), {}) as Dictionary).get("params", {})
			for pk in pschema.keys():
				var spec: Dictionary = pschema[pk]
				if spec.has("min") and spec.has("max"):
					var lo := float(spec["min"]); var hi := float(spec["max"])
					((nd as Dictionary)["params"] as Dictionary)[pk] = lo + (hi - lo) * float(marks[mi])
			(nd as Dictionary).erase("dist")  # re-init fresh distributions centered on the marks
		parents.append(NodeGenome.new(nodes, proto.schema, proto.config))
	var child := NodeGenome.recombine(parents, rng)
	_check("multi-parent recombine child is valid", child.is_valid())
	var contributors := {}
	for nd in child.nodes:
		var pschema: Dictionary = ((NodeGenome.DEFAULT_SCHEMA["types"] as Dictionary).get(String((nd as Dictionary)["type"]), {}) as Dictionary).get("params", {})
		for pk in pschema.keys():
			var spec: Dictionary = pschema[pk]
			if spec.has("min") and spec.has("max"):
				var lo := float(spec["min"]); var hi := float(spec["max"])
				var frac := (float(((nd as Dictionary)["params"] as Dictionary)[pk]) - lo) / maxf(hi - lo, 1e-9)
				for mi in 3:
					if absf(frac - float(marks[mi])) < 0.0001:
						contributors[mi] = true
	_check("3-way recombine mixed genes from >= 2 distinct parents (got %d)" % contributors.size(),
		contributors.size() >= 2)

	# Kinds never interbreed: node x texture degrades to a clone of `a`, lineage still recorded.
	var eg_node := EvolverGenome.new(proto.clone(), "", 0, [], "seed")
	var eg_tex := EvolverGenome.new(TextureGenome.random(3, rng), "", 0, [], "seed")
	var xk := EvolverGenome.crossover(eg_node, eg_tex, 1, rng)
	_check("mixed-kind crossover degrades to a clone of `a` (kind stays 'node')",
		xk.kind() == "node"
		and JSON.stringify((xk.genome as NodeGenome).to_stack()) == JSON.stringify(proto.to_stack()))
	_check("mixed-kind crossover still records both parents", xk.parent_ids == [eg_node.id, eg_tex.id])

	# The EXISTING breed algebra drives kind "node" unchanged (meta_genome.genome_kind).
	var meta := { "population_size": 4, "n_inject": 1, "seed_layers": 3, "genome_kind": "node" }
	var culled := EvolverBreed.breed([], meta, 1, rng)
	var all_node := culled.size() == 4
	for eg in culled:
		if (eg as EvolverGenome).kind() != "node":
			all_node = false
	_check("fully-culled recovery reseeds 4 fresh NODE genomes via genome_kind='node'", all_node)
	var decided := [
		{ "genome": eg_node, "action": "evolve" },
		{ "genome": EvolverGenome.new(NodeGenome.random(3, rng), "", 0, [], "seed"), "action": "save" },
	]
	var next := EvolverBreed.breed(decided, meta, 1, rng)
	var kinds_ok := next.size() == 4
	var origins := {}
	for eg in next:
		if (eg as EvolverGenome).kind() != "node":
			kinds_ok = false
		origins[(eg as EvolverGenome).origin] = true
	_check("keep/pin/crossover/inject breed path stays all-node (origins: %s)" % [origins.keys()], kinds_ok)

# ---------------------------------------------------------------------------------------------------
# 6. the convergence harness — the acceptance metric
# ---------------------------------------------------------------------------------------------------

## Build a (start, target) pair sharing one structure inside the possibility space, then run
## greedy nearest-to-target selection (elitist best-of-K per generation).
func _run_convergence(seed: int, cfg_override: Dictionary, eps: float = 0.06, cap: int = 200, k: int = 8) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var target := NodeGenome.random(3, rng, NodeGenome.DEFAULT_SCHEMA, { "p_structural": 0.0 })
	# Start = same structure, params scrambled uniform, FRESH wide distributions.
	var scrambler := NodeGenome.new(target.to_stack()["node_graph"]["nodes"], target.schema,
		{ "p_structural": 0.0, "tail_w": 1.0 })
	var scrambled: Array = scrambler.mutate(rng).to_stack()["node_graph"]["nodes"]
	for nd in scrambled:
		(nd as Dictionary).erase("dist")
	var cfg := { "p_structural": 0.0 }
	for kk in cfg_override.keys():
		cfg[kk] = cfg_override[kk]
	var start := NodeGenome.new(scrambled, target.schema, cfg)
	return _select_toward(target, start, k, eps, cap, rng)

## Greedy supervised-selection simulator: each generation K mutated children compete with the
## parent (elitism); the nearest-to-target survives. Returns gens/converged/dist/msec/best.
func _select_toward(target: NodeGenome, start: NodeGenome, k: int, eps: float, cap: int,
		rng: RandomNumberGenerator) -> Dictionary:
	var cur := start
	var best_d := NodeGenome.distance(cur, target)
	var t0 := Time.get_ticks_msec()
	var gens := 0
	for _g in cap:
		if best_d <= eps:
			break
		gens += 1
		for _i in k:
			var ch := cur.mutate(rng)
			var d := NodeGenome.distance(ch, target)
			if d < best_d:
				cur = ch
				best_d = d
	return { "gens": gens, "converged": best_d <= eps, "dist": best_d,
		"msec": Time.get_ticks_msec() - t0, "best": cur }

func _test_convergence_harness() -> void:
	print("-- 6. convergence harness: adaptive vs uniform-mutation baseline --")
	var seeds := [101, 202, 303]
	var adaptive_gens := []
	var all_adaptive_converged := true
	var all_faster := true
	for seed in seeds:
		var adaptive := _run_convergence(int(seed), {})
		# Baseline: NON-adaptive uniform mutation — tail_w=1.0 makes every draw uniform over the
		# whole range (no concentration ever influences a draw).
		var baseline := _run_convergence(int(seed), { "tail_w": 1.0 })
		adaptive_gens.append(adaptive["gens"])
		print("  seed %d: adaptive %d gens (%.3f, %d ms, converged=%s) | uniform baseline %d gens (%.3f, %d ms, converged=%s)" % [
			seed, adaptive["gens"], adaptive["dist"], adaptive["msec"], adaptive["converged"],
			baseline["gens"], baseline["dist"], baseline["msec"], baseline["converged"]])
		if not adaptive["converged"]:
			all_adaptive_converged = false
		if baseline["converged"] and int(baseline["gens"]) <= int(adaptive["gens"]):
			all_faster = false
		if float(baseline["dist"]) < float(adaptive["dist"]) and not adaptive["converged"]:
			all_faster = false
	_check("adaptive distributions converge to the in-space target on all %d seeds" % seeds.size(),
		all_adaptive_converged)
	_check("adaptive converges FASTER than the uniform-mutation baseline on every seed", all_faster)

	# ADVERSARIAL premature-concentration trap: converge on A, keep concentrating, then move the
	# target to B — the non-decaying heavy tails must still escape the concentrated basin.
	var rng := RandomNumberGenerator.new()
	rng.seed = 555
	var run_a := _run_convergence(555, {}, 0.06, 200, 8)
	var trapped: NodeGenome = run_a["best"]
	for _i in 30:  # over-concentrate well past convergence
		var deeper := trapped.mutate(rng)
		if NodeGenome.distance(deeper, trapped) < 0.2:
			trapped = deeper
	var sig := _first_scalar_sigma(trapped)
	_check("trap is real: a scalar core sat at the variance floor (sigma %.4f)" % sig, sig <= 0.011 and sig > 0.0)
	var target_b := NodeGenome.random(3, rng, NodeGenome.DEFAULT_SCHEMA, { "p_structural": 0.0 })
	# Same structure as the trapped genome, fresh param values as the moved target.
	var b_nodes: Array = trapped.to_stack()["node_graph"]["nodes"]
	var scr := NodeGenome.new(b_nodes, trapped.schema, { "p_structural": 0.0, "tail_w": 1.0 })
	var moved := scr.mutate(rng)
	var d_before := NodeGenome.distance(trapped, moved)
	var escape := _select_toward(moved, trapped, 8, 0.12, 400, rng)
	print("  moved-target: distance %.3f -> %.3f in %d gens (%d ms)" % [d_before, escape["dist"], escape["gens"], escape["msec"]])
	_check("ADVERSARIAL moved-target: heavy tails escape premature concentration (%.3f -> %.3f)" % [d_before, escape["dist"]],
		bool(escape["converged"]) and d_before > 0.15)

func _first_scalar_sigma(g: NodeGenome) -> float:
	for nd in g.nodes:
		var dists: Dictionary = (nd as Dictionary).get("dist", {})
		for pk in dists.keys():
			var st: Dictionary = dists[pk]
			if String(st.get("kind", "")) == "scalar":
				var range_w := maxf(float(st["hi"]) - float(st["lo"]), 1e-9)
				return float(st["sigma"]) / range_w  # normalized
	return -1.0

# ---------------------------------------------------------------------------------------------------
# 7. the conditional convergence-helper node seam
# ---------------------------------------------------------------------------------------------------

func _test_helper_seam() -> void:
	print("-- 7. helper-node seam: momentum-toward-improvement, condition-scoped --")
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	# One transform node + a FIXED helper_momentum node conditioned on param "gain" only.
	var g := NodeGenome.from_stack({ "node_graph": {
		"nodes": [
			{ "id": "t1", "type": "transform", "params": { "gain": 0.0, "bias": 0.0, "curve": "linear" } },
			{ "id": "h1", "type": "helper_momentum", "fixed": true, "when": { "param": "gain" },
				"params": { "beta": 0.5, "gain": 1.0 } },
		],
		"config": { "p_structural": 0.0 },
	} })
	_check("helper node lives IN the node collection (an evolution method as a node)",
		g.find_node("h1") != null and bool((g.find_node("h1") as Dictionary).get("fixed", false)))
	_check("helper condition survives sanitation",
		String(((g.find_node("h1") as Dictionary).get("when", {}) as Dictionary).get("param", "")) == "gain")
	var child := g.mutate(rng)
	var t1: Dictionary = child.find_node("t1")
	var gain_state: Dictionary = (t1.get("dist", {}) as Dictionary).get("gain", {})
	var bias_state: Dictionary = (t1.get("dist", {}) as Dictionary).get("bias", {})
	_check("momentum transformed ONLY the matching param (gain has 'vel', bias does not)",
		gain_state.has("vel") and not bias_state.has("vel"))
	var rt := NodeGenome.from_stack(JSON.parse_string(JSON.stringify(child.to_stack())))
	_check("helper velocity state serializes with the genome",
		(((rt.find_node("t1") as Dictionary).get("dist", {}) as Dictionary).get("gain", {}) as Dictionary).has("vel"))

	# The helper-carrying genome still converges under selection (the seam does not break the
	# harness); report gens vs a no-helper control for the record.
	var target := NodeGenome.from_stack({ "node_graph": {
		"nodes": [ { "id": "t1", "type": "transform", "params": { "gain": 1.8, "bias": 0.8, "curve": "step" } } ],
		"config": { "p_structural": 0.0 },
	} })
	var start_helper := g
	var no_helper := NodeGenome.from_stack({ "node_graph": {
		"nodes": [ { "id": "t1", "type": "transform", "params": { "gain": 0.0, "bias": 0.0, "curve": "linear" } } ],
		"config": { "p_structural": 0.0 },
	} })
	var rh := RandomNumberGenerator.new(); rh.seed = 888
	var rn := RandomNumberGenerator.new(); rn.seed = 888
	# Distance vs a helperless target counts the helper node as an unmatched-node cost, the same
	# constant for every candidate — converge on the payload genes with a helper-adjusted eps.
	var res_helper := _select_toward(target, start_helper, 8, 0.30, 300, rh)
	var res_plain := _select_toward(target, no_helper, 8, 0.06, 300, rn)
	print("  helper run: %d gens (dist %.3f) | no-helper control: %d gens (dist %.3f)" % [
		res_helper["gens"], res_helper["dist"], res_plain["gens"], res_plain["dist"]])
	_check("helper-carrying genome converges under selection", bool(res_helper["converged"]))
	_check("no-helper control converges (seam is additive, not required)", bool(res_plain["converged"]))

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

## Every param of every node is inside its schema (range / options) — the closure invariant.
func _all_genes_in_schema(g: NodeGenome) -> bool:
	var types: Dictionary = g.schema.get("types", {})
	for nd in g.nodes:
		var t := String((nd as Dictionary).get("type", ""))
		if not types.has(t):
			return false
		var pschema: Dictionary = (types[t] as Dictionary).get("params", {})
		var p: Dictionary = (nd as Dictionary).get("params", {})
		for pk in pschema.keys():
			var spec: Dictionary = pschema[pk]
			if not p.has(pk):
				return false
			if spec.has("options"):
				if not (spec["options"] as Array).has(p[pk]):
					return false
			elif spec.has("min") and spec.has("max"):
				var v := float(p[pk])
				if v < float(spec["min"]) - 0.0001 or v > float(spec["max"]) + 0.0001:
					return false
	return true
