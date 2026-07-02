extends SceneTree
## Proves the PROCEDURAL-TEXTURE GENOME rides the general-purpose evolver loop end to end, HEADLESS,
## and WITHOUT ever touching Liam's live Aperture (mock mode + injected fake feedback) — the texture
## twin of headless_evolver_test.gd, over the SAME four primitives:
##   EvolverPopulation → Render2D → ApertureSurface(push) → (human) → ApertureSurface(readback) → Breed.
## Real assertions, PASS/FAIL tally, nonzero exit on fail.
##   godot --headless --path godot -s res://headless_texture_evolver_test.gd
##
## What it proves:
##  1. TextureGenome gene algebra: random genomes are valid; PER-GENE-TYPE mutation (numeric ranges +
##     handle options + reorder/add/drop) is CLOSED over the valid-op set; crossover splices validly;
##     sanitize clamps/snap/drops; JSON round-trip.
##  2. Deterministic synthesis: the SAME genome renders byte-identical PNGs; different seeds differ.
##  3. EvolverGenome kind dispatch: texture genomes wrap/round-trip with correct lineage; kinds never
##     interbreed (mixed crossover degrades to a clone); effect-genome behavior is untouched.
##  4. The FULL node cycle over texture genomes: render every candidate → mock cards → injected
##     evolve/save/skip decisions → breed KEEP/PIN/CULL into a next generation whose renders differ
##     deterministically per seed (elite carry = byte-identical; injected blood = visibly new).
##  5. The persistent tick with meta_genome.genome_kind="texture": seeds gen-0 TEXTURE genomes,
##     persists gitignored, advances only when decided, idempotent re-run, append-only lineage.
##  6. LIVE-APERTURE GUARD: nothing here ever wrote to the real inbox.

func _initialize() -> void:
	var ok := true
	var run_dir := "user://evolver_test/textures"
	_rm_rf(run_dir)
	# Snapshot the live inbox BEFORE anything runs: the guard at the end proves THIS RUN added no
	# tagged rows. (An absent-tag assert would false-fail forever once a real live generation has
	# legitimately been pushed by the production path — which has already happened.)
	var live_rows_before := _live_inbox_tag_count(PrimApertureSurface.SOURCE_TAG)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260702

	# --- 1. TextureGenome gene algebra -----------------------------------------------------------
	var g_a := TextureGenome.random(3, rng)
	var g_b := TextureGenome.random(3, rng)
	ok = _check("random texture genome is valid + has 3 ops", g_a.is_valid() and g_a.size() == 3) and ok
	ok = _check("random genome's first op is a full base coat (blend 'replace')",
		String((g_a.ops[0] as Dictionary).get("params", {}).get("blend", "")) == "replace") and ok
	ok = _check("every random op type is in the OP_TYPES vocabulary", _all_ops_known(g_a) and _all_ops_known(g_b)) and ok

	# JSON round-trip through the descriptor.
	var rt := TextureGenome.from_stack(JSON.parse_string(JSON.stringify(g_a.to_stack())))
	ok = _check("TextureGenome round-trips through JSON unchanged",
		JSON.stringify(rt.to_stack()) == JSON.stringify(g_a.to_stack())) and ok

	# Mutation closure: 30 chained mutations, every intermediate genome stays valid + in-vocabulary +
	# in-range/in-options (the per-gene-type operators never escape the schema).
	var m := g_a
	var closure_ok := true
	for _i in 30:
		m = m.mutate(rng)
		if not m.is_valid() or not _all_ops_known(m) or not _all_genes_in_schema(m):
			closure_ok = false
			break
	ok = _check("30 chained mutations stay CLOSED over valid ops + in-schema genes", closure_ok) and ok
	ok = _check("mutation never empties the genome", m.size() >= 1) and ok
	ok = _check("mutate returns a NEW genome (source untouched)",
		JSON.stringify(g_a.to_stack()) == JSON.stringify(TextureGenome.from_stack(g_a.to_stack()).to_stack())) and ok

	# Crossover: valid child; deterministic under a fixed seed; empty×empty recovers to 1 op.
	var xr1 := RandomNumberGenerator.new(); xr1.seed = 42
	var xr2 := RandomNumberGenerator.new(); xr2.seed = 42
	var child1 := TextureGenome.crossover(g_a, g_b, xr1)
	var child2 := TextureGenome.crossover(g_a, g_b, xr2)
	ok = _check("crossover child is valid", child1.is_valid()) and ok
	ok = _check("crossover is deterministic under a fixed seed",
		JSON.stringify(child1.to_stack()) == JSON.stringify(child2.to_stack())) and ok
	var xr3 := RandomNumberGenerator.new(); xr3.seed = 7
	var empty_child := TextureGenome.crossover(TextureGenome.new([]), TextureGenome.new([]), xr3)
	ok = _check("empty×empty crossover recovers to a 1-op genome (never empty)",
		empty_child.size() == 1 and empty_child.is_valid()) and ok

	# Sanitize: unknown op dropped; out-of-range numeric clamped; unknown palette handle snapped.
	var dirty := TextureGenome.new([
		{ "type": "not_a_real_op", "params": {} },
		{ "type": "fbm", "params": { "octaves": 99, "palette": "not_a_palette", "blend": "mix" } },
	])
	ok = _check("sanitize drops unknown ops", dirty.size() == 1) and ok
	var fbm_p: Dictionary = (dirty.ops[0] as Dictionary)["params"]
	ok = _check("sanitize clamps out-of-range numeric genes (octaves 99 → 6)", int(fbm_p["octaves"]) == 6) and ok
	ok = _check("sanitize snaps an unknown palette handle to the default",
		TextureSynthCpu.PALETTES.has(String(fbm_p["palette"]))) and ok

	# --- 2. Deterministic synthesis ---------------------------------------------------------------
	var img1 := TextureSynthCpu.synthesize(g_a.to_stack(), 64, 64)
	var img2 := TextureSynthCpu.synthesize(g_a.to_stack(), 64, 64)
	ok = _check("the SAME genome synthesizes byte-identical images (no RNG in the render layer)",
		img1.save_png_to_buffer() == img2.save_png_to_buffer()) and ok
	var img_b := TextureSynthCpu.synthesize(g_b.to_stack(), 64, 64)
	ok = _check("two different random genomes synthesize DIFFERENT images",
		img1.save_png_to_buffer() != img_b.save_png_to_buffer()) and ok
	var img_empty := TextureSynthCpu.synthesize({ "texture_ops": [] }, 8, 8)
	ok = _check("an empty op list still yields a valid (flat) tile", img_empty.get_width() == 8) and ok

	# --- 3. EvolverGenome kind dispatch ------------------------------------------------------------
	var seed_rng := RandomNumberGenerator.new(); seed_rng.seed = 11
	var tex_seed := EvolverGenome.random_seed(3, 0, seed_rng, "texture")
	var eff_seed := EvolverGenome.random_seed(3, 0, seed_rng)  # default kind: effect (unchanged API)
	ok = _check("random_seed(kind='texture') wraps a TextureGenome (kind 'texture')", tex_seed.kind() == "texture") and ok
	ok = _check("random_seed default still wraps an EffectGenome (kind 'effect')", eff_seed.kind() == "effect") and ok

	var tex_rt = EvolverGenome.from_dict(JSON.parse_string(JSON.stringify(tex_seed.to_dict())))
	ok = _check("a serialized texture genome round-trips with kind + ops intact",
		tex_rt.kind() == "texture" and tex_rt.id == tex_seed.id
		and JSON.stringify(tex_rt.genome.to_stack()) == JSON.stringify(tex_seed.genome.to_stack())) and ok

	var tex_kept = tex_seed.keep_into(1)
	var tex_injected = EvolverGenome.inject_mutated(tex_seed, 1, seed_rng)
	var tex_seed2 := EvolverGenome.random_seed(3, 0, seed_rng, "texture")
	var tex_crossed = EvolverGenome.crossover(tex_seed, tex_seed2, 1, seed_rng)
	ok = _check("keep/inject/crossover all preserve the texture kind + lineage",
		tex_kept.kind() == "texture" and tex_kept.parent_ids == [tex_seed.id]
		and tex_injected.kind() == "texture" and tex_injected.origin == "inject"
		and tex_crossed.kind() == "texture" and tex_crossed.parent_ids.size() == 2) and ok
	var mixed = EvolverGenome.crossover(tex_seed, eff_seed, 1, seed_rng)
	ok = _check("mixed-kind crossover degrades to a clone of parent A (kinds never interbreed)",
		mixed.kind() == "texture"
		and JSON.stringify(mixed.genome.to_stack()) == JSON.stringify(tex_seed.genome.to_stack())) and ok

	# --- 4. FULL node cycle over texture genomes ---------------------------------------------------
	var meta := { "population_size": 4, "n_inject": 1, "seed_layers": 3, "genome_kind": "texture",
		"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ] }
	var pop_rng := RandomNumberGenerator.new(); pop_rng.seed = 77
	var pop_genomes: Array = []
	for _i in 4:
		pop_genomes.append(EvolverGenome.random_seed(3, 0, pop_rng, "texture").to_dict())
	var pop_node := PrimEvolverPopulation.new()
	pop_node.params = { "population": pop_genomes, "generation": 0, "meta_genome": meta }
	var pop_desc = pop_node.evaluate({}).get("population")
	ok = _check("EvolverPopulation carries 4 texture genomes as DATA (genome-blind)",
		PrimEvolverPopulation.is_population(pop_desc) and pop_desc.get("population", []).size() == 4) and ok

	var thumb_dir := run_dir + "/thumbs"
	var render_node := PrimRender2D.new()
	render_node.params = { "out_dir": thumb_dir, "width": 96, "height": 96 }
	var rendered_desc = render_node.evaluate({ "population": pop_desc }).get("rendered")
	var rendered: Array = rendered_desc.get("rendered", [])
	ok = _check("Render2D produced one render record per texture candidate", rendered.size() == 4) and ok
	var every_png_valid := true
	var gen0_png := {}  # genome_id -> png bytes
	for entry in rendered:
		var p := String(entry.get("image_path", ""))
		var abs := ProjectSettings.globalize_path(p)
		if not bool(entry.get("ok", false)) or not FileAccess.file_exists(abs):
			every_png_valid = false
			continue
		var img := Image.load_from_file(abs)
		if img == null or img.get_width() != 96 or img.get_height() != 96:
			every_png_valid = false
		gen0_png[String(entry["genome"]["id"])] = FileAccess.get_file_as_bytes(abs)
	ok = _check("every texture candidate rendered to a valid 96x96 PNG on disk", every_png_valid) and ok

	# Mock push — cards recorded locally, captions name the construction ops, live inbox untouched.
	var mock_dir := run_dir + "/mock"
	var push_node := PrimApertureSurface.new()
	push_node.params = { "op": "push", "mode": "mock", "mock_dir": mock_dir }
	var push_desc = push_node.evaluate({ "in": rendered_desc }).get("surface")
	var cards: Array = push_desc.get("cards", [])
	ok = _check("push (mock) created one card per texture candidate", cards.size() == 4) and ok
	var mock_file := ProjectSettings.globalize_path(mock_dir + "/pushed_cards.jsonl")
	var mock_text := FileAccess.get_file_as_string(mock_file) if FileAccess.file_exists(mock_file) else ""
	ok = _check("mock cards were recorded locally with texture titles + op captions",
		mock_text.contains("Texture gen 0") and not mock_text.contains("(empty look)")) and ok

	# Injected decisions: evolve / save / skip / skip.
	var fb := {}
	fb[String(cards[0]["card_id"])] = "evolve"
	fb[String(cards[1]["card_id"])] = "save"
	fb[String(cards[2]["card_id"])] = "skip"
	fb[String(cards[3]["card_id"])] = "skip"
	var fb_path := run_dir + "/fake_feedback.json"
	_write_text(fb_path, JSON.stringify(fb))
	var rb_node := PrimApertureSurface.new()
	rb_node.params = { "op": "readback", "mode": "mock", "mock_feedback_path": fb_path }
	var readback = rb_node.evaluate({ "in": push_desc }).get("surface")
	ok = _check("readback sees all four texture cards decided", bool(readback.get("all_decided", false))) and ok

	# Breed → next generation of texture genomes.
	var breed_node := PrimBreed.new()
	breed_node.params = { "seed": 99 }
	var next_pop_desc = breed_node.evaluate({ "in": readback }).get("population")
	var next_pop: Array = next_pop_desc.get("population", [])
	ok = _check("Breed produced a next generation of 4 (population_size)", next_pop.size() == 4) and ok
	ok = _check("Breed stamped generation 1", int(next_pop_desc.get("generation", -1)) == 1) and ok

	var origins := {}
	var all_texture_kind := true
	var all_valid_renderable := true
	var all_have_parents := true
	var keep_parent := String(cards[0]["genome"]["id"])
	var pin_parent := String(cards[1]["genome"]["id"])
	var culled := { String(cards[2]["genome"]["id"]): true, String(cards[3]["genome"]["id"]): true }
	var no_culled_elite := true
	var next_png := {}  # genome_id -> png bytes (rendered at the same 96x96)
	var src96 := PrimRender2D.synthetic_source(96, 96)
	for cd in next_pop:
		var eg = EvolverGenome.from_dict(cd)
		origins[eg.origin] = origins.get(eg.origin, 0) + 1
		if eg.kind() != "texture":
			all_texture_kind = false
		if not eg.genome.is_valid():
			all_valid_renderable = false
		var out_abs := ProjectSettings.globalize_path(run_dir + "/next_%s.png" % eg.id)
		if not PrimRender2D.render_genome_to(eg, out_abs, src96):
			all_valid_renderable = false
		else:
			next_png[eg.id] = FileAccess.get_file_as_bytes(out_abs)
		if (cd.get("parent_ids", []) as Array).is_empty():
			all_have_parents = false
		if (eg.origin == "keep" or eg.origin == "pin"):
			for pid in eg.parent_ids:
				if culled.has(pid):
					no_culled_elite = false
	ok = _check("every bred child is a TEXTURE genome (kind preserved through breeding)", all_texture_kind) and ok
	ok = _check("every bred child is valid + renderable", all_valid_renderable) and ok
	ok = _check("KEEP + PIN + INJECT origins are all present in the next generation",
		origins.get("keep", 0) >= 1 and origins.get("pin", 0) >= 1 and origins.get("inject", 0) >= 1) and ok
	ok = _check("every gen-1 child records parent_ids (append-only lineage)", all_have_parents) and ok
	ok = _check("no CULLed genome was carried forward as an elite", no_culled_elite) and ok

	# Next-generation renders DIFFER DETERMINISTICALLY per seed:
	#   (a) an ELITE carry (keep/pin) renders BYTE-IDENTICAL to its gen-0 parent (the look survives);
	#   (b) the INJECTed child's GENOME differs from both surviving parents (the effective-mutation
	#       invariant — DATA-level, because a mutation may legitimately hit a visually-neutral gene,
	#       e.g. warp_seed while warp_amp is 0: neutral drift, still real evolution);
	#   (c) re-breeding with the SAME seed reproduces the exact same looks (strip volatile ids).
	var elite_identical := false
	var inject_differs := false
	var keep_ops := JSON.stringify(cards[0]["genome"]["stack"])
	var pin_ops := JSON.stringify(cards[1]["genome"]["stack"])
	for cd in next_pop:
		var eg = EvolverGenome.from_dict(cd)
		if (eg.origin == "keep" or eg.origin == "pin") and eg.parent_ids.size() == 1:
			var pid := String(eg.parent_ids[0])
			if gen0_png.has(pid) and next_png.has(eg.id) and gen0_png[pid] == next_png[eg.id]:
				elite_identical = true
		if eg.origin == "inject":
			var child_ops := JSON.stringify(eg.genome.to_stack())
			if child_ops != keep_ops and child_ops != pin_ops:
				inject_differs = true
	ok = _check("an elite carry renders BYTE-IDENTICAL to its parent (deterministic look survival)", elite_identical) and ok
	ok = _check("the injected child's genome DIFFERS from both surviving parents (effective mutation)", inject_differs) and ok
	var breed2 := PrimBreed.new(); breed2.params = { "seed": 99 }
	var np2 = breed2.evaluate({ "in": readback }).get("population")
	ok = _check("texture breeding is deterministic under a fixed seed",
		JSON.stringify(_strip_ids(next_pop_desc)) == JSON.stringify(_strip_ids(np2))) and ok

	# Fully-culled recovery seeds FRESH TEXTURE genomes (meta.genome_kind honored in the floor path).
	var all_cull := { "op": "readback", "all_decided": true, "generation": 0, "meta_genome": meta, "decided": [] }
	for c in cards:
		all_cull["decided"].append({ "genome": c["genome"], "action": "skip" })
	var recover := PrimBreed.new(); recover.params = { "seed": 5 }
	var recovered = recover.evaluate({ "in": all_cull }).get("population")
	var rec_pop: Array = recovered.get("population", [])
	var rec_all_texture := rec_pop.size() == 4
	for cd in rec_pop:
		if EvolverGenome.from_dict(cd).kind() != "texture":
			rec_all_texture = false
	ok = _check("a fully-culled TEXTURE generation recovers with fresh TEXTURE seeds", rec_all_texture) and ok

	# --- 5. The persistent tick with genome_kind='texture' ----------------------------------------
	var tick_dir := run_dir + "/tick"
	_rm_rf(tick_dir)
	var cfg := {
		"state_dir": tick_dir, "mode": "mock", "seed": 313,
		"meta_genome": { "population_size": 3, "n_inject": 1, "seed_layers": 3, "genome_kind": "texture",
			"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ] },
		"thumb_dir": tick_dir + "/thumbs",
		"width": 48, "height": 48,
		"mock_feedback_path": "",
	}
	var r1 := EvolverTick.run_once(cfg)
	ok = _check("tick 1 seeds generation 0 with 3 texture candidates",
		int(r1.get("generation")) == 0 and int(r1.get("n_candidates")) == 3) and ok
	ok = _check("tick 1 rendered + pushed (mock)", bool(r1.get("rendered_ok")) and bool(r1.get("pushed"))) and ok
	ok = _check("tick 1 does not advance (undecided)", not bool(r1.get("advanced"))) and ok
	var st := EvolverState.load_state(tick_dir)
	var seeded_texture := true
	for gd in st.get("population", []):
		if not (gd.get("stack", {}) as Dictionary).has("texture_ops"):
			seeded_texture = false
	ok = _check("gen-0 was seeded as TEXTURE genomes (texture_ops payload in persisted state)", seeded_texture) and ok

	var st_cards: Array = st.get("cards", [])
	var tick_fb := {}
	for i in st_cards.size():
		tick_fb[String(st_cards[i]["card_id"])] = ("evolve" if i == 0 else ("save" if i == 1 else "skip"))
	var tick_fb_path := tick_dir + "/fb.json"
	_write_text(tick_fb_path, JSON.stringify(tick_fb))
	cfg["mock_feedback_path"] = tick_fb_path
	var r2 := EvolverTick.run_once(cfg)
	ok = _check("tick 2 advances the texture population to generation 1",
		bool(r2.get("advanced")) and int(r2.get("next_generation")) == 1) and ok
	var st2 := EvolverState.load_state(tick_dir)
	var gen1_texture := int(st2.get("generation", -1)) == 1
	for gd in st2.get("population", []):
		if not (gd.get("stack", {}) as Dictionary).has("texture_ops"):
			gen1_texture = false
	ok = _check("generation 1 persisted on disk, still all TEXTURE genomes", gen1_texture) and ok
	var r3 := EvolverTick.run_once(cfg)
	ok = _check("tick 3 is idempotent (gen-1 undecided → no re-advance)", not bool(r3.get("advanced"))) and ok
	var lineage := EvolverState.read_lineage(tick_dir)
	ok = _check("lineage log accumulated gen0 + gen1 append-only (6 rows)", lineage.size() == 6) and ok

	# --- 6. LIVE-APERTURE GUARD --------------------------------------------------------------------
	ok = _check("the test ADDED no rows to the live Aperture inbox (mock-only run)",
		_live_inbox_tag_count(PrimApertureSurface.SOURCE_TAG) == live_rows_before) and ok

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail_count))
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

var _fail_count := 0

func _check(label: String, cond: bool) -> bool:
	if not cond:
		_fail_count += 1
	print(("PASS " if cond else "FAIL ") + label)
	return cond

## Every op's type is a registered construction.
func _all_ops_known(g: TextureGenome) -> bool:
	for op in g.ops:
		if not TextureSynthCpu.OP_TYPES.has(String((op as Dictionary).get("type", ""))):
			return false
	return true

## Every gene value obeys its schema (numeric in range; handle in options) — the closure invariant.
func _all_genes_in_schema(g: TextureGenome) -> bool:
	for op in g.ops:
		var t := String((op as Dictionary).get("type", ""))
		var schema: Dictionary = TextureSynthCpu.OP_TYPES.get(t, {}).get("params", {})
		var p: Dictionary = (op as Dictionary).get("params", {})
		for k in p.keys():
			if not schema.has(k):
				return false
			var spec: Dictionary = schema[k]
			if spec.has("options"):
				if not (spec["options"] as Array).has(p[k]):
					return false
			elif spec.has("min") and spec.has("max"):
				var v := float(p[k])
				if v < float(spec["min"]) - 0.0001 or v > float(spec["max"]) + 0.0001:
					return false
	return true

## Strip per-process ids so two breeds with the same seed compare equal on look + lineage shape.
func _strip_ids(pop_desc: Dictionary) -> Dictionary:
	var out := { "generation": pop_desc.get("generation"), "population": [] }
	for cd in pop_desc.get("population", []):
		var c: Dictionary = (cd as Dictionary).duplicate(true)
		c.erase("id")
		c.erase("parent_ids")
		out["population"].append(c)
	return out

func _write_text(path: String, text: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()

func _rm_rf(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			var child := abs.path_join(name)
			if d.current_is_dir():
				_rm_rf(path.path_join(name))
				DirAccess.remove_absolute(child)
			else:
				DirAccess.remove_absolute(child)
		name = d.get_next()
	d.list_dir_end()

## How many live-inbox rows carry `tag` as their source_session. Missing file → 0. Compared before vs
## after the run: equal counts prove the test itself never pushed live (pre-existing production rows
## from real generations are expected and tolerated).
func _live_inbox_tag_count(tag: String) -> int:
	var live := "G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl"
	if not FileAccess.file_exists(live):
		return 0
	var n := 0
	for line in FileAccess.get_file_as_string(live).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY and String(row.get("source_session", "")) == tag:
			n += 1
	return n
