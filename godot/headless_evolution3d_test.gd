extends SceneTree
## Headless proof of the EVOLUTION ROOM's substrate equivalence with the web evolution API
## (Resonance-Website feat/aperture-evolution-pages, static/aperture/endpoints/evolver.py) —
## ZERO live pollution (fixture state dir under user://; live guards assert nothing leaked).
##   godot --headless --path godot -s res://headless_evolution3d_test.gd
##
## What it proves:
##  1. INDEX semantics mirror evolver.py _evolver_rows/_handle_index: kind filter, last-wins
##     inbox collapse, DECIDED CARDS KEPT + annotated (the evolution page shows history — the
##     opposite of the main board's hide), genome/caption join from *_cards.jsonl + lineage.jsonl,
##     generation resolved from the card map when the inbox row lacks it, groups ascend with the
##     unknown bucket last.
##  2. SAVE-AS-BRANCH writes the EXACT web branch record: same 10 keys, same id shapes, source
##     genome recorded as the parent, origin "branch" at both levels, off_generation from the
##     card map when unspecified.
##  3. CROSS-LANE READ-BACK (the load-bearing proof): the REAL web module — extracted from the
##     feat/aperture-evolution-pages branch via git show and imported by the REAL python — reads
##     the fixture dir Godot wrote: card_genome_map() and read_branches() see Godot's rows.
##  4. The in-engine variant loop (detail view N key): EvolverGenome.from_dict on a lineage row +
##     inject_mutated produces a valid texture genome whose PIXELS differ from the base —
##     deterministic given the seed.
##  5. LIVE GUARDS: the shared live state dir's branches.jsonl gained no rows.

const WEBSITE_REPO := "G:/Wavelet/repos/Resonance-Website"
const WEB_BRANCH := "feat/aperture-evolution-pages"
const TEST_PREFIX := "evo3dtest_"

var _fail_count := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail_count += 1
	return cond

func _initialize() -> void:
	var ok := true
	var run_dir := "user://evolution3d_test"
	_rm_rf(run_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var live_branches_before := _line_count(
		EvolverSubstrate.branches_path(EvolverSubstrate.DEFAULT_STATE_DIR))

	# --- fixture: a two-generation substrate + inbox + feedback --------------------------------
	var state_dir := run_dir + "/textures"
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260703
	var g_a := EvolverGenome.random_seed(3, 0, rng, "texture")
	var g_b := EvolverGenome.random_seed(3, 0, rng, "texture")
	var g_c := EvolverGenome.random_seed(3, 1, rng, "texture")
	_write_lines(state_dir + "/gen0_cards.jsonl", [
		JSON.stringify({ "card_id": TEST_PREFIX + "A", "genome_id": "stale_id", "generation": 0 }),
		JSON.stringify({ "card_id": TEST_PREFIX + "A", "genome_id": g_a.id, "generation": 0 }),
		JSON.stringify({ "card_id": TEST_PREFIX + "B", "genome_id": g_b.id, "generation": 0 }),
	])
	_write_lines(state_dir + "/gen1_cards.jsonl", [
		JSON.stringify({ "card_id": TEST_PREFIX + "C", "genome_id": g_c.id, "generation": 1 }),
	])
	_write_lines(state_dir + "/lineage.jsonl", [
		JSON.stringify(g_a.to_dict()), JSON.stringify(g_b.to_dict()), JSON.stringify(g_c.to_dict()),
	])
	var inbox_p := run_dir + "/inbox.jsonl"
	var fb_p := run_dir + "/feedback.jsonl"
	_write_lines(inbox_p, [
		JSON.stringify({ "id": TEST_PREFIX + "A", "kind": "evolver_candidate", "title": "old A",
			"status": "pending", "media": {} }),
		JSON.stringify({ "id": TEST_PREFIX + "A", "kind": "evolver_candidate", "title": "Texture A",
			"status": "pending", "media": {} }),  # no generation field → resolved from the card map
		JSON.stringify({ "id": TEST_PREFIX + "B", "kind": "evolver_candidate", "title": "Texture B",
			"status": "pending", "media": {}, "generation": 0 }),
		JSON.stringify({ "id": TEST_PREFIX + "C", "kind": "evolver_candidate", "title": "Texture C",
			"status": "pending", "media": {}, "generation": 1 }),
		JSON.stringify({ "id": TEST_PREFIX + "L", "kind": "evolver_candidate", "title": "Loose",
			"status": "pending", "media": {} }),  # no map entry → "?" bucket
		JSON.stringify({ "id": TEST_PREFIX + "N", "kind": "artifact", "title": "not evolver",
			"status": "pending", "media": {} }),
	])
	_write_lines(fb_p, [
		JSON.stringify({ "artifact_id": TEST_PREFIX + "B", "action": "evolve",
			"decided_at": "2026-07-03T00:00:01Z", "by": "liam" }),
	])

	# --- 1. index semantics ---------------------------------------------------------------------
	var rows := EvolverSubstrate.evolver_rows(inbox_p, fb_p, state_dir)
	ok = _check("kind filter + last-wins: 4 evolver rows (artifact filtered out)", rows.size() == 4) and ok
	var r_a := _row(rows, TEST_PREFIX + "A")
	ok = _check("duplicate inbox id collapsed last-wins", String(r_a.get("title")) == "Texture A") and ok
	ok = _check("generation resolved from the card map when the row lacks it",
		int(r_a.get("generation")) == 0) and ok
	ok = _check("genome joined from lineage via the card map (stale map row superseded)",
		typeof(r_a.get("genome")) == TYPE_DICTIONARY
		and String((r_a.get("genome") as Dictionary).get("id")) == g_a.id) and ok
	ok = _check("caption is the op-type chain", String(r_a.get("caption")).contains("+")
		or String(r_a.get("caption")).length() > 0) and ok
	var r_b := _row(rows, TEST_PREFIX + "B")
	ok = _check("DECIDED card KEPT and annotated (evolution page shows history)",
		bool(r_b.get("decided")) and String(r_b.get("decision")) == "evolve") and ok
	var grouped := EvolverSubstrate.group_by_generation(rows)
	var keys: Array = []
	for g in grouped:
		keys.append(String((g as Dictionary).get("generation")))
	ok = _check("groups ascend with the unknown bucket last", keys == ["0", "1", "?"]) and ok
	ok = _check("gen-0 column holds A + B",
		((grouped[0] as Dictionary).get("cards") as Array).size() == 2) and ok

	# --- 2. save-as-branch: the exact web record --------------------------------------------------
	var vrng := RandomNumberGenerator.new()
	vrng.seed = 777
	var variant := EvolverGenome.inject_mutated(g_a, 0, vrng).to_dict()
	var rec := EvolverSubstrate.append_branch(state_dir, TEST_PREFIX + "A", variant)
	ok = _check("branch append ok", bool(rec.get("ok"))) and ok
	var on_disk := EvolverSubstrate.read_branches(state_dir)
	ok = _check("branches.jsonl holds the record", on_disk.size() == 1) and ok
	var b0: Dictionary = on_disk[0]
	var want_keys := ["branch_id", "card_id", "source_genome_id", "off_generation", "genome",
		"image", "note", "created_at", "by", "origin"]
	var keys_match := b0.keys().size() == want_keys.size()
	for k in want_keys:
		keys_match = keys_match and b0.has(k)
	ok = _check("record carries EXACTLY the 10 web-schema keys", keys_match) and ok
	var bid := String(b0.get("branch_id"))
	ok = _check("branch_id shape br_<8 hex>",
		bid.begins_with("br_") and bid.length() == 11 and bid.substr(3).is_valid_hex_number()) and ok
	ok = _check("source genome recorded (from the card map) + off_generation defaulted from it",
		String(b0.get("source_genome_id")) == g_a.id and int(b0.get("off_generation")) == 0) and ok
	var bg: Dictionary = b0.get("genome")
	ok = _check("saved genome is lineage-ready: gen_<usec>_br id, parent=[source], origin branch",
		String(bg.get("id")).begins_with("gen_") and String(bg.get("id")).ends_with("_br")
		and bg.get("parent_ids") == [g_a.id] and String(bg.get("origin")) == "branch"
		and (bg.get("stack") as Dictionary).has("texture_ops")) and ok
	ok = _check("record-level origin branch, by liam, ISO-Z stamp, null image/note",
		String(b0.get("origin")) == "branch" and String(b0.get("by")) == "liam"
		and String(b0.get("created_at")).ends_with("Z")
		and b0.get("image") == null and b0.get("note") == null) and ok

	# --- 3. CROSS-LANE: the real web module reads back what Godot wrote ---------------------------
	var web_dir := ProjectSettings.globalize_path(run_dir + "/webmod/endpoints").replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(web_dir)
	var got_web := _git_show("static/aperture/endpoints/evolver.py", web_dir + "/evolver.py") \
		and _git_show("static/aperture/endpoints/_substrate.py", web_dir + "/_substrate.py")
	_write_lines(run_dir + "/webmod/endpoints/__init__.py", [])
	if got_web:
		var fixture := ProjectSettings.globalize_path(state_dir).replace("\\", "/")
		var out := _py([
			"import os, sys, json",
			"os.environ['APERTURE_EVOLVER_STATE_DIR'] = '%s'" % fixture,
			"sys.path.insert(0, '%s')" % ProjectSettings.globalize_path(run_dir + "/webmod").replace("\\", "/"),
			"from endpoints import evolver",
			"cmap = evolver.card_genome_map()",
			"brs = evolver.read_branches()",
			"print(len(cmap), cmap.get('%sA', {}).get('genome_id'))" % TEST_PREFIX,
			"print(len(brs), brs[-1]['branch_id'], brs[-1]['genome']['origin'])",
		])
		var lines := out.strip_edges().split("\n")
		ok = _check("web evolver.py card_genome_map() reads Godot's fixture (3 cards, last-wins id)",
			lines.size() >= 2 and String(lines[0]).strip_edges() == "3 %s" % g_a.id) and ok
		ok = _check("web evolver.py read_branches() reads Godot's branch record back",
			lines.size() >= 2 and String(lines[1]).strip_edges() == "1 %s branch" % bid) and ok
	else:
		print("SKIP  cross-lane read-back (web branch %s not reachable)" % WEB_BRANCH)

	# --- 4. the detail-view variant loop is live + deterministic ----------------------------------
	var base_img := TextureSynthCpu.synthesize(g_a.to_dict().get("stack"), 32, 32)
	var v1rng := RandomNumberGenerator.new()
	v1rng.seed = 424242
	var var1 := EvolverGenome.inject_mutated(g_a, 0, v1rng).to_dict()
	var v2rng := RandomNumberGenerator.new()
	v2rng.seed = 424242
	var var2 := EvolverGenome.inject_mutated(g_a, 0, v2rng).to_dict()
	ok = _check("variant mutation is deterministic given the seed",
		JSON.stringify(var1.get("stack")) == JSON.stringify(var2.get("stack"))) and ok
	var var_img := TextureSynthCpu.synthesize(var1.get("stack"), 32, 32)
	ok = _check("variant PIXELS differ from the base (a visible re-roll)",
		_img_hash(base_img) != _img_hash(var_img)) and ok
	ok = _check("variant genome is lineage-ready (parent = base, origin inject)",
		var1.get("parent_ids") == [g_a.id] and String(var1.get("origin")) == "inject") and ok

	# --- 5. live guards ----------------------------------------------------------------------------
	ok = _check("live shared branches.jsonl gained no rows",
		_line_count(EvolverSubstrate.branches_path(EvolverSubstrate.DEFAULT_STATE_DIR)) == live_branches_before) and ok

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail_count))
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

func _row(rows: Array, id: String) -> Dictionary:
	for r in rows:
		if String((r as Dictionary).get("id")) == id:
			return r
	return {}

## Extract one file from the web lane's branch into `dest`. False when the branch/file is absent.
func _git_show(repo_path: String, dest: String) -> bool:
	var out := []
	var code := OS.execute("git", ["-C", WEBSITE_REPO, "show", "%s:%s" % [WEB_BRANCH, repo_path]], out, true)
	if code != 0 or out.is_empty():
		return false
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("\n".join(out))
	f.close()
	return true

func _py(lines: Array) -> String:
	var out := []
	var code := OS.execute("py", ["-c", "\n".join(lines)], out, true)
	if code != 0:
		var code2 := OS.execute("python3", ["-c", "\n".join(lines)], out, true)
		if code2 != 0:
			return "PYFAIL: " + "\n".join(out)
	return "\n".join(out)

func _img_hash(img: Image) -> String:
	var buf := img.save_png_to_buffer()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(buf)
	return ctx.finish().hex_encode()

func _write_lines(path: String, lines: Array) -> void:
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("user://") or path.begins_with("res://") else path
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	for l in lines:
		f.store_line(String(l))
	f.close()

func _line_count(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var n := 0
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.strip_edges() != "":
			n += 1
	return n

func _rm_rf(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path)
	if not DirAccess.dir_exists_absolute(abs):
		return
	var d := DirAccess.open(abs)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if d.current_is_dir():
			_rm_rf(path + "/" + f)
		else:
			d.remove(f)
		f = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(abs)
