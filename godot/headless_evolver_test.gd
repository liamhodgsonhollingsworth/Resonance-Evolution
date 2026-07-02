extends SceneTree
## Proves GZ-EVOLVE.1 — the SUPERVISED PAINTERLY EVOLVER loop as a NODE SYSTEM, end to end, HEADLESS,
## and WITHOUT ever touching Liam's live Aperture (mock mode + an injected fake-feedback file). The loop:
##   EvolverPopulation → Render2D → ApertureSurface(push) → (human) → ApertureSurface(readback) → Breed
##   → EvolverPopulation(next).
## Real assertions, PASS/FAIL tally, nonzero exit on fail (not print-only).
##   godot --headless --path godot -s res://headless_evolver_test.gd
##
## What it proves (the FULL data-path cycle):
##  1. Lineage genome: random_seed/keep/pin/crossover/inject set correct append-only lineage + round-trip.
##  2. EvolverPopulation node emits a `population` descriptor (genomes + meta_genome) as DATA.
##  3. Render2D renders EVERY candidate to a valid NON-EMPTY PNG on disk.
##  4. ApertureSurface(mock) push records cards (card↔genome map) WITHOUT touching the live Aperture.
##  5. ApertureSurface(mock) readback maps the three actions evolve/save/skip from injected feedback.
##  6. Breed maps evolve→KEEP, save→PIN, skip→CULL into a next generation of the right SIZE with
##     KEEP/CROSSOVER/INJECT applied and append-only lineage (parent_ids present, never mutated).
##  7. The persistent TICK (EvolverTick) seeds gen-0, persists state under the gitignored dir, advances
##     only when all decided, and a RE-RUN resumes (idempotent) — state survives on disk.

func _initialize() -> void:
	var ok := true

	# A unique, gitignored state dir for this run (under godot/state/evolver/painterly, which is in
	# godot/.gitignore). user:// also works headless; we use an absolute temp under res:// state so the
	# test exercises the real gitignored path. Cleaned at the start so the idempotency check is honest.
	var run_dir := "user://evolver_test/painterly"
	_rm_rf(run_dir)

	# Snapshot the live inbox BEFORE anything runs. The final guard proves THIS RUN added no tagged
	# rows — an absent-tag assert (the original form) false-fails forever once the PRODUCTION path has
	# legitimately pushed a real live generation with the same SOURCE_TAG, which has now happened.
	var live_rows_before := _live_inbox_tag_count(PrimApertureSurface.SOURCE_TAG)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260630

	# --- 1. Lineage genome: lineage is correct + append-only + round-trips through JSON. -------------
	var seed_a := EvolverGenome.random_seed(3, 0, rng)
	var seed_b := EvolverGenome.random_seed(3, 0, rng)
	ok = _check("random_seed has generation 0 + no parents + origin 'seed'",
		seed_a.generation == 0 and seed_a.parent_ids.is_empty() and seed_a.origin == "seed") and ok
	ok = _check("two seeds have distinct ids", seed_a.id != seed_b.id) and ok

	var kept := seed_a.keep_into(1)
	ok = _check("keep_into records the source as the sole parent + origin 'keep'",
		kept.parent_ids == [seed_a.id] and kept.origin == "keep" and kept.generation == 1) and ok
	var pinned := seed_a.pin_into(1)
	ok = _check("pin_into records origin 'pin' (a saved breeder)",
		pinned.origin == "pin" and pinned.parent_ids == [seed_a.id]) and ok

	var crossed := EvolverGenome.crossover(seed_a, seed_b, 1, rng)
	ok = _check("crossover records BOTH parents + origin 'crossover'",
		crossed.parent_ids.size() == 2 and crossed.parent_ids.has(seed_a.id)
		and crossed.parent_ids.has(seed_b.id) and crossed.origin == "crossover") and ok
	ok = _check("crossover child is a valid effect genome", crossed.genome.is_valid()) and ok

	var injected := EvolverGenome.inject_mutated(seed_a, 1, rng)
	ok = _check("inject_mutated records the source as parent + origin 'inject'",
		injected.parent_ids == [seed_a.id] and injected.origin == "inject") and ok
	ok = _check("injected child is still a valid effect genome", injected.genome.is_valid()) and ok

	# Append-only: keep/pin/crossover/inject NEVER mutate the source's lineage.
	ok = _check("breeding leaves the SOURCE genome's lineage untouched (append-only)",
		seed_a.parent_ids.is_empty() and seed_a.origin == "seed" and seed_a.generation == 0) and ok

	# Round-trip through dict/JSON.
	var rt = EvolverGenome.from_dict(JSON.parse_string(JSON.stringify(crossed.to_dict())))
	ok = _check("EvolverGenome round-trips through JSON (id/gen/parents/stack preserved)",
		rt.id == crossed.id and rt.generation == crossed.generation
		and rt.parent_ids == crossed.parent_ids
		and JSON.stringify(rt.genome.to_stack()) == JSON.stringify(crossed.genome.to_stack())) and ok

	# --- 2. EvolverPopulation node emits a `population` descriptor (DATA). ---------------------------
	var meta := { "population_size": 4, "n_inject": 1, "seed_layers": 3,
		"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ] }
	var pop_genomes: Array = []
	var pop_rng := RandomNumberGenerator.new(); pop_rng.seed = 7
	for _i in 4:
		pop_genomes.append(EvolverGenome.random_seed(3, 0, pop_rng).to_dict())
	var pop_node := PrimEvolverPopulation.new()
	pop_node.params = { "population": pop_genomes, "generation": 0, "meta_genome": meta }
	var pop_desc = pop_node.evaluate({}).get("population")
	ok = _check("EvolverPopulation emits a population descriptor", PrimEvolverPopulation.is_population(pop_desc)) and ok
	ok = _check("population descriptor carries all 4 genomes", pop_desc.get("population", []).size() == 4) and ok
	ok = _check("meta_genome merges over defaults (population_size honoured)",
		int(pop_desc.get("meta_genome", {}).get("population_size", -1)) == 4) and ok

	# --- 3. Render2D renders EVERY candidate to a valid NON-EMPTY PNG. -------------------------------
	var thumb_dir := run_dir + "/thumbs"
	var render_node := PrimRender2D.new()
	render_node.params = { "out_dir": thumb_dir, "width": 48, "height": 48 }
	var rendered_desc = render_node.evaluate({ "population": pop_desc }).get("rendered")
	var rendered: Array = rendered_desc.get("rendered", [])
	ok = _check("Render2D produced one render record per candidate", rendered.size() == 4) and ok
	var every_png_valid := true
	for entry in rendered:
		var p := String(entry.get("image_path", ""))
		var abs := ProjectSettings.globalize_path(p)
		if not bool(entry.get("ok", false)) or not FileAccess.file_exists(abs):
			every_png_valid = false
		else:
			# Non-empty + loadable as an image of the requested size.
			var img := Image.load_from_file(abs)
			if img == null or img.get_width() != 48 or img.get_height() != 48:
				every_png_valid = false
	ok = _check("every candidate rendered to a valid, non-empty 48x48 PNG on disk", every_png_valid) and ok

	# --- 4. ApertureSurface(mock) push records cards WITHOUT the live Aperture. ----------------------
	var mock_dir := run_dir + "/mock"
	var push_node := PrimApertureSurface.new()
	push_node.params = { "op": "push", "mode": "mock", "mock_dir": mock_dir }
	var push_desc = push_node.evaluate({ "in": rendered_desc }).get("surface")
	var cards: Array = push_desc.get("cards", [])
	ok = _check("push (mock) created one card per candidate", cards.size() == 4) and ok
	var card_ids_unique := {}
	var all_map_back := true
	for c in cards:
		card_ids_unique[String(c.get("card_id"))] = true
		if not (c.get("genome") is Dictionary and String(c["genome"].get("id", "")) != ""):
			all_map_back = false
	ok = _check("each card has a unique id mapping back to its genome", card_ids_unique.size() == 4 and all_map_back) and ok
	# It did NOT touch the live Aperture: the live inbox file is unchanged (proven by the live-Aperture
	# guard at the END of this test; here we assert the mock wrote its OWN local file instead).
	var mock_cards_file := ProjectSettings.globalize_path(mock_dir + "/pushed_cards.jsonl")
	ok = _check("push (mock) wrote cards to its LOCAL mock file (not the live inbox)",
		FileAccess.file_exists(mock_cards_file)) and ok

	# --- 5. ApertureSurface(mock) readback maps the three actions from injected feedback. ------------
	# Inject a fake-feedback file mapping the four cards to evolve / save / skip / (pending).
	# card[0]→evolve(KEEP), card[1]→save(PIN), card[2]→skip(CULL), card[3]→skip(CULL).
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
	ok = _check("readback reports all four cards decided (none pending)", bool(readback.get("all_decided", false))) and ok
	var decided: Array = readback.get("decided", [])
	var actions_seen := {}
	for d in decided:
		actions_seen[String(d.get("action"))] = actions_seen.get(String(d.get("action")), 0) + 1
	ok = _check("readback mapped evolve/save/skip from the injected feedback",
		actions_seen.get("evolve", 0) == 1 and actions_seen.get("save", 0) == 1
		and actions_seen.get("skip", 0) == 2) and ok

	# A PENDING card (no feedback row) is reported as not-all-decided (the human-paced wait state).
	var fb_partial := {}
	fb_partial[String(cards[0]["card_id"])] = "evolve"  # only one decided
	var fb_partial_path := run_dir + "/fake_feedback_partial.json"
	_write_text(fb_partial_path, JSON.stringify(fb_partial))
	var rb_partial := PrimApertureSurface.new()
	rb_partial.params = { "op": "readback", "mode": "mock", "mock_feedback_path": fb_partial_path }
	var rb_partial_desc = rb_partial.evaluate({ "in": push_desc }).get("surface")
	ok = _check("a partially-decided generation reports all_decided=false (waits for Liam)",
		not bool(rb_partial_desc.get("all_decided", true))) and ok

	# --- 6. Breed maps KEEP/PIN/CULL into a next generation of the right size + applies the operators.
	var breed_node := PrimBreed.new()
	breed_node.params = { "seed": 99 }
	var next_pop_desc = breed_node.evaluate({ "in": readback }).get("population")
	var next_pop: Array = next_pop_desc.get("population", [])
	ok = _check("Breed produced a next generation of population_size (4)", next_pop.size() == 4) and ok
	ok = _check("Breed stamped the next generation index (1)", int(next_pop_desc.get("generation", -1)) == 1) and ok

	# Every child renders (closure: the bred genomes are valid effect stacks).
	var src48 := PrimRender2D.synthetic_source(48, 48)
	var every_child_renders := true
	var origins := {}
	var keep_parent := String(cards[0]["genome"]["id"])  # the evolve'd genome
	var pin_parent := String(cards[1]["genome"]["id"])   # the save'd genome
	var culled_parents := { String(cards[2]["genome"]["id"]): true, String(cards[3]["genome"]["id"]): true }
	var a_keep_or_pin_survived := false
	var inject_present := false
	var no_culled_carried_as_elite := true
	for cd in next_pop:
		var eg := EvolverGenome.from_dict(cd)
		origins[eg.origin] = origins.get(eg.origin, 0) + 1
		if not eg.genome.is_valid() or not PrimRender2D.render_genome_to(eg, ProjectSettings.globalize_path(run_dir + "/_t_%s.png" % eg.id), src48):
			every_child_renders = false
		# A kept/pinned survivor carries one of the surviving parents.
		if eg.origin == "keep" or eg.origin == "pin":
			if eg.parent_ids == [keep_parent] or eg.parent_ids == [pin_parent]:
				a_keep_or_pin_survived = true
		if eg.origin == "inject":
			inject_present = true
		# Append-only lineage: parent_ids is present + non-mutated; a CULLED genome is never an elite
		# carry-forward (origin keep/pin), only possibly a crossover/inject SOURCE.
		if (eg.origin == "keep" or eg.origin == "pin"):
			for pid in eg.parent_ids:
				if culled_parents.has(pid):
					no_culled_carried_as_elite = false
	ok = _check("every bred child is a valid, renderable genome", every_child_renders) and ok
	ok = _check("a KEEP/PIN survivor carried a surviving parent forward", a_keep_or_pin_survived) and ok
	ok = _check("at least one INJECT (fresh mutated blood) is present", inject_present) and ok
	ok = _check("no CULLed genome was carried forward as an elite (keep/pin)", no_culled_carried_as_elite) and ok
	var all_have_parents := true
	for cd in next_pop:
		if (cd.get("parent_ids", []) as Array).is_empty():
			all_have_parents = false  # gen-1 children all descend from gen-0 → every one has a parent
	ok = _check("every gen-1 child records its parent_ids (lineage append-only)", all_have_parents) and ok

	# Breed determinism: same decided generation + same seed → identical next generation.
	var breed2 := PrimBreed.new(); breed2.params = { "seed": 99 }
	var np2 = breed2.evaluate({ "in": readback }).get("population")
	ok = _check("Breed is deterministic under a fixed seed",
		JSON.stringify(_strip_ids(next_pop_desc)) == JSON.stringify(_strip_ids(np2))) and ok

	# A fully-CULLED generation still recovers (inject from a random seed → never an empty population).
	var all_cull := { "op": "readback", "all_decided": true, "generation": 0,
		"meta_genome": meta, "decided": [] }
	for c in cards:
		all_cull["decided"].append({ "genome": c["genome"], "action": "skip" })
	var recover := PrimBreed.new(); recover.params = { "seed": 5 }
	var recovered = recover.evaluate({ "in": all_cull }).get("population")
	ok = _check("a fully-culled generation still recovers to population_size (inject floor)",
		(recovered.get("population", []) as Array).size() == 4) and ok

	# --- 7. The persistent TICK: seed gen-0, persist under the gitignored dir, advance, RESUME. ------
	var tick_dir := run_dir + "/tick"
	_rm_rf(tick_dir)
	# Tick 1 with NO feedback yet → seeds gen-0, renders, pushes (mock), reads back → NOT all decided.
	var cfg := {
		"state_dir": tick_dir, "mode": "mock", "seed": 4242,
		"meta_genome": { "population_size": 3, "n_inject": 1, "seed_layers": 3,
			"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ] },
		"thumb_dir": tick_dir + "/thumbs",
		"mock_feedback_path": "",  # no feedback → pending
	}
	var r1 := EvolverTick.run_once(cfg)
	ok = _check("tick 1 seeds generation 0 with 3 candidates", int(r1.get("generation")) == 0 and int(r1.get("n_candidates")) == 3) and ok
	ok = _check("tick 1 rendered all candidates + pushed cards", bool(r1.get("rendered_ok")) and bool(r1.get("pushed"))) and ok
	ok = _check("tick 1 does NOT advance (generation undecided)", not bool(r1.get("advanced"))) and ok
	var state_file := ProjectSettings.globalize_path(tick_dir + "/state.json")
	ok = _check("tick persisted state.json under the gitignored state dir", FileAccess.file_exists(state_file)) and ok

	# Read the persisted gen-0 cards, write a feedback file deciding ALL of them, then tick again.
	var st := EvolverState.load_state(tick_dir)
	var st_cards: Array = st.get("cards", [])
	var tick_fb := {}
	for i in st_cards.size():
		tick_fb[String(st_cards[i]["card_id"])] = ("evolve" if i == 0 else ("save" if i == 1 else "skip"))
	var tick_fb_path := tick_dir + "/fb.json"
	_write_text(tick_fb_path, JSON.stringify(tick_fb))
	cfg["mock_feedback_path"] = tick_fb_path

	# Tick 2 (idempotent re-run): same state loaded, now all decided → BREED + advance to generation 1.
	var r2 := EvolverTick.run_once(cfg)
	ok = _check("tick 2 sees the generation fully decided", bool(r2.get("all_decided"))) and ok
	ok = _check("tick 2 advances to generation 1 (bred next gen)",
		bool(r2.get("advanced")) and int(r2.get("next_generation")) == 1) and ok
	var st2 := EvolverState.load_state(tick_dir)
	ok = _check("persisted state advanced to generation 1 on disk", int(st2.get("generation", -1)) == 1) and ok
	ok = _check("generation 1 was rendered + pushed by the advancing tick", bool(st2.get("pushed", false)) and (st2.get("cards", []) as Array).size() == 3) and ok

	# Idempotency: tick 3 with the SAME (stale) feedback (gen-0 cards) → gen-1 cards are undecided → NO
	# further advance (the loop is human-paced + the re-run is a safe no-op for the new generation).
	var r3 := EvolverTick.run_once(cfg)
	ok = _check("tick 3 is idempotent: gen-1 undecided → does not advance again", not bool(r3.get("advanced"))) and ok
	var st3 := EvolverState.load_state(tick_dir)
	ok = _check("state stays at generation 1 across the idempotent re-run", int(st3.get("generation", -1)) == 1) and ok

	# Lineage log is append-only: gen-0 (3) + gen-1 (3) = 6 rows, each with parent_ids on gen-1.
	var lineage := EvolverState.read_lineage(tick_dir)
	ok = _check("lineage log accumulated all genomes append-only (gen0 + gen1 = 6 rows)", lineage.size() == 6) and ok

	# --- 8. LIVE-APERTURE GUARD: the whole test never wrote to Liam's real inbox. --------------------
	# The live inbox is G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl. We did all pushes in
	# mock mode, so the count of rows tagged with this evolver's SOURCE_TAG must be UNCHANGED from the
	# start-of-run snapshot (pre-existing rows from real production generations are expected).
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

## Strip the non-deterministic `id` fields so two breeds with the same seed compare equal on the look +
## lineage shape (the ids are per-process unique by design — see EvolverGenome.new_id).
func _strip_ids(pop_desc: Dictionary) -> Dictionary:
	var out := { "generation": pop_desc.get("generation"), "population": [] }
	for cd in pop_desc.get("population", []):
		var c: Dictionary = (cd as Dictionary).duplicate(true)
		c.erase("id")
		c.erase("parent_ids")  # parent_ids reference per-process ids too
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

## How many live-inbox rows carry `tag` as their source_session (missing file → 0). Compared before
## vs after the run: equal counts prove the test itself never pushed live, while tolerating the rows
## real production generations have legitimately pushed with the same tag.
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
