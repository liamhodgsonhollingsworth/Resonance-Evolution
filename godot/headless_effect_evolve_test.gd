extends SceneTree
## Proves L3 — the EVOLVER GENOME over the effect-layer list ("evolving shaders" in its simplest real
## form). The genome IS the ordered effect-stack; mutate perturbs/reorders/adds/drops a layer, and
## crossover MIXES two genomes into a VALID new stack. Every produced genome `to_stack()`s into a
## descriptor the L0 CPU oracle (EffectStackCpu) applies unchanged — so evolution and rendering share
## one renderer-neutral DATA surface. Headless + deterministic (seeded RNG).
##   godot --headless --path godot -s res://headless_effect_evolve_test.gd

func _initialize() -> void:
	var ok := true
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242

	var src := Image.create(4, 4, false, Image.FORMAT_RGBAF)
	for y in 4:
		for x in 4:
			var v: float = 0.2 if x < 2 else 0.8
			src.set_pixel(x, y, Color(v, v, v, 1.0))

	# --- 1. A random genome is a VALID effect stack the CPU oracle can apply. ---
	var g := EffectGenome.random(4, rng)
	ok = _check("random genome has the requested layer count", g.size() == 4) and ok
	ok = _check("random genome is valid (all known effect types)", g.is_valid()) and ok
	var stack := g.to_stack()
	ok = _check("genome.to_stack() is an effect_stack descriptor", PrimEffectStack.is_effect_stack(stack)) and ok
	var applied := EffectStackCpu.apply(stack, src)
	ok = _check("the applied genome yields a same-size image", applied.get_width() == 4 and applied.get_height() == 4) and ok

	# --- 2. CROSSOVER mixes two genomes into a VALID new stack (the core "evolving shaders" claim). ---
	# Parent A: a flatten→posterize "poster" look. Parent B: an "ink" outline-over-grain look.
	var parent_a := EffectGenome.new([
		{ "type": "kuwahara", "params": { "radius": 2 } },
		{ "type": "posterize", "params": { "levels": 4 } },
	])
	var parent_b := EffectGenome.new([
		{ "type": "paper_grain", "params": { "amount": 0.2, "scale": 6.0, "seed": 5 } },
		{ "type": "edge_darken", "params": { "strength": 1.0, "threshold": 0.1 } },
		{ "type": "outline", "params": { "threshold": 0.2 } },
	])
	var child := EffectGenome.crossover(parent_a, parent_b, rng)
	ok = _check("crossover child is a valid genome", child.is_valid()) and ok
	# One-point splice = prefix(A) + suffix(B), so its length is within [0, len(A)+len(B)] and every
	# layer came from one of the two parents (closure over the valid set).
	ok = _check("crossover child length is bounded by the two parents",
		child.size() <= parent_a.size() + parent_b.size()) and ok
	var child_types := {}
	for layer in child.to_stack()["stack"]:
		child_types[String(layer["type"])] = true
	var parent_types := { "kuwahara": true, "posterize": true, "paper_grain": true, "edge_darken": true, "outline": true }
	var all_from_parents := true
	for t in child_types.keys():
		if not parent_types.has(t):
			all_from_parents = false
	ok = _check("every crossover-child layer type comes from a parent", all_from_parents) and ok
	# The mixed stack APPLIES cleanly through the oracle — a new look, rendered as DATA.
	var child_img := EffectStackCpu.apply(child.to_stack(), src)
	ok = _check("the crossover-mixed stack applies through the CPU oracle", child_img.get_width() == 4) and ok

	# Determinism: same parents + same seed → identical child stack (reproducible evolution).
	var rng2 := RandomNumberGenerator.new(); rng2.seed = 9001
	var rng3 := RandomNumberGenerator.new(); rng3.seed = 9001
	var c1 := EffectGenome.crossover(parent_a, parent_b, rng2)
	var c2 := EffectGenome.crossover(parent_a, parent_b, rng3)
	ok = _check("crossover is deterministic under a fixed seed",
		JSON.stringify(c1.to_stack()) == JSON.stringify(c2.to_stack())) and ok

	# Uniform crossover is also valid (a second mix operator the evolver can choose).
	var cu := EffectGenome.crossover_uniform(parent_a, parent_b, rng)
	ok = _check("uniform crossover yields a valid genome", cu.is_valid()) and ok

	# --- 3. MUTATE is one local edit, non-destructive (parent unchanged), and stays valid. ---
	var before := JSON.stringify(parent_b.to_stack())
	var mutated := parent_b.mutate(rng)
	ok = _check("mutate leaves the parent genome unchanged (non-destructive)",
		JSON.stringify(parent_b.to_stack()) == before) and ok
	ok = _check("mutated genome is still valid", mutated.is_valid()) and ok
	ok = _check("the mutated genome applies through the CPU oracle",
		EffectStackCpu.apply(mutated.to_stack(), src).get_width() == 4) and ok

	# Over a batch of mutations, at least one actually CHANGES the stack (mutation is effective, not a
	# perpetual no-op) AND every result stays valid (closure holds across many edits).
	var changed_any := false
	var all_valid := true
	var m_rng := RandomNumberGenerator.new(); m_rng.seed = 7
	for _i in 30:
		var mm := parent_b.mutate(m_rng)
		if not mm.is_valid():
			all_valid = false
		if JSON.stringify(mm.to_stack()) != before:
			changed_any = true
	ok = _check("a batch of mutations produces at least one real change", changed_any) and ok
	ok = _check("every mutation in the batch stays valid (closure invariant)", all_valid) and ok

	# --- 4. SANITATION: a genome built from garbage/out-of-range DATA is coerced to a valid stack
	# (the evolver can never emit a descriptor the applier chokes on). ---
	var dirty := EffectGenome.new([
		{ "type": "posterize", "params": { "levels": 999 } },     # out of range → clamped
		{ "type": "not_a_real_effect", "params": {} },            # unknown → passthrough
		"garbage-not-a-dict",                                     # dropped
		{ "type": "kuwahara", "params": { "radius": -5 } },       # below range → clamped to min
	])
	ok = _check("sanitation drops the non-dict layer", dirty.size() == 3) and ok
	var dirty_stack := dirty.to_stack()
	ok = _check("sanitation clamps an out-of-range param into the schema range",
		int(dirty_stack["stack"][0]["params"]["levels"]) <= 16) and ok
	ok = _check("sanitation maps an unknown effect to passthrough",
		String(dirty_stack["stack"][1]["type"]) == "passthrough") and ok
	ok = _check("sanitized genome is valid + applies through the oracle",
		dirty.is_valid() and EffectStackCpu.apply(dirty_stack, src).get_width() == 4) and ok

	# --- 5. ROUND-TRIP: genome → stack → JSON → from_stack → genome is stable (DATA portability). ---
	var rt_stack = JSON.parse_string(JSON.stringify(child.to_stack()))
	var rt := EffectGenome.from_stack(rt_stack)
	ok = _check("genome round-trips through JSON + from_stack",
		JSON.stringify(rt.to_stack()) == JSON.stringify(child.to_stack())) and ok

	# --- 6. The whole evolve→pick loop runs end-to-end as DATA: seed a population, evolve a generation
	# by mutate+crossover, every candidate renders. (The fitness/pick step is the interactive surface,
	# out of THIS increment — here we only prove the genome operators feed the oracle as a closed loop.) ---
	var pop := []
	var pop_rng := RandomNumberGenerator.new(); pop_rng.seed = 2024
	for _i in 4:
		pop.append(EffectGenome.random(pop_rng.randi_range(1, 3), pop_rng))
	var next_gen := []
	for i in pop.size():
		var a: EffectGenome = pop[i]
		var b: EffectGenome = pop[(i + 1) % pop.size()]
		next_gen.append(EffectGenome.crossover(a, b, pop_rng).mutate(pop_rng))
	var every_renders := true
	for cand in next_gen:
		if not cand.is_valid() or EffectStackCpu.apply(cand.to_stack(), src).get_width() != 4:
			every_renders = false
	ok = _check("a full evolve generation (crossover+mutate) yields candidates that all render", every_renders) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
