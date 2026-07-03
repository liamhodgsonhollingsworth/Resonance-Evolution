extends SceneTree
## Headless proof of the GODOT APERTURE 3D data path — read equivalence, WRITE equivalence, and
## the in-engine live-iteration loop — with ZERO live pollution (every write goes to a temp dir;
## live-substrate guards assert nothing leaked). Real assertions, PASS/FAIL tally, nonzero exit.
##   godot --headless --path godot -s res://headless_aperture3d_test.gd
##
## What it proves:
##  1. READ (http channel): parse_inbox_body normalizes the /api/aperture/inbox body — images
##     (file:// stripped, carousel preserved), actions, generation, text/link cards.
##  2. READ (file channel): read_inbox_file mirrors the server semantics — last-wins id collapse,
##     latest-action hide (skip hides; skip→unskip restores; evolve hides a decided evolver card).
##  3. WRITE equivalence: ApertureActions file mode appends the EXACT rows the web tools write —
##     and the REAL aperture_feedback.py / aperture_bookmark.py READ BACK what Godot wrote
##     (executed via py with the module path patched to the temp file — the load-bearing proof).
##  4. The ApertureInbox/ApertureAction PRIMITIVES drive the same modules through GraphRuntime.
##  5. LIVE ITERATION: seed wall arrangement → LiveHost poll loads it → nudge_gene writes the
##     file → poll hotloads → the synthesized tile pixels CHANGE (and revert edits are stable).
##  6. EVOLVER TICK (mock): tick seeds gen-0 texture candidates; in-engine decisions recorded to
##     the mock feedback file; next tick BREEDS generation 1. Never touches the live Aperture.
##  7. LIVE GUARDS: the live inbox gained no rows from this run; the live feedback.jsonl gained
##     no rows carrying this test's artifact ids.

const LIVE_INBOX := "G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl"
const LIVE_FEEDBACK := "G:/Wavelet/Alethea-cc/state/aperture/feedback.jsonl"
const TEST_PREFIX := "ap3dtest_"

var _fail_count := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail_count += 1
	return cond

func _initialize() -> void:
	var ok := true
	var run_dir := "user://aperture3d_test"
	_rm_rf(run_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var live_inbox_before := _line_count(LIVE_INBOX)
	var live_fb_test_rows_before := _rows_with_prefix(LIVE_FEEDBACK, TEST_PREFIX)

	# --- 1. READ, http channel: parse the server body -------------------------------------------
	var body := JSON.stringify({
		"ok": true,
		"artifacts": [
			{ "id": TEST_PREFIX + "img", "source_session": "s1", "kind": "preview",
				"title": "A picture", "subtitle": "sub", "summary": null,
				"media": { "image_url": "file://G:/tmp/one.png", "text": null, "link": null,
					"images": ["file://G:/tmp/one.png", "G:/tmp/two.png"] },
				"actions": null, "disposition": "content", "created_at": "2026-07-02T00:00:00Z",
				"status": "pending" },
			{ "id": TEST_PREFIX + "evo", "source_session": "s2", "kind": "evolver_candidate",
				"title": "Texture 3", "subtitle": null, "summary": null,
				"media": { "image_url": "file:///G:/tmp/t3.png", "images": ["file:///G:/tmp/t3.png"] },
				"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ],
				"disposition": "decision", "created_at": "2026-07-02T00:00:00Z",
				"status": "pending", "generation": 2 },
			{ "id": TEST_PREFIX + "txt", "source_session": "s3", "kind": "artifact",
				"title": "Words", "media": { "text": "hello world", "link": "http://x/y" },
				"actions": null, "disposition": "content", "status": "pending" },
		],
		"skipped": [], "version": "t",
	})
	var parsed := ApertureInbox.parse_inbox_body(body)
	ok = _check("http body → 3 normalized cards", parsed.size() == 3) and ok
	var c0: Dictionary = parsed[0]
	ok = _check("carousel preserved + file:// stripped",
		c0.get("images", []).size() == 2 and String(c0["images"][0]) == "G:/tmp/one.png"
		and String(c0["images"][1]) == "G:/tmp/two.png") and ok
	var c1: Dictionary = parsed[1]
	ok = _check("file:///G:/ triple-slash form also resolves to a drive path",
		String(c1["images"][0]) == "G:/tmp/t3.png") and ok
	ok = _check("evolver card keeps actions + generation",
		c1.get("actions", []).size() == 2 and int(c1.get("generation")) == 2) and ok
	var c2: Dictionary = parsed[2]
	ok = _check("text card carries text + link, no images",
		String(c2.get("text")) == "hello world" and String(c2.get("link")) == "http://x/y"
		and c2.get("images", []).is_empty()) and ok
	ok = _check("malformed / not-ok bodies → []",
		ApertureInbox.parse_inbox_body("{nope").is_empty()
		and ApertureInbox.parse_inbox_body(JSON.stringify({ "ok": false, "artifacts": [ {} ] })).is_empty()) and ok

	# --- 2. READ, file channel: substrate semantics ----------------------------------------------
	var inbox_p := run_dir + "/inbox.jsonl"
	var fb_p := run_dir + "/feedback.jsonl"
	_write_lines(inbox_p, [
		JSON.stringify({ "id": TEST_PREFIX + "a", "kind": "artifact", "title": "old title", "status": "pending" }),
		JSON.stringify({ "id": TEST_PREFIX + "a", "kind": "artifact", "title": "corrected title", "status": "pending" }),
		JSON.stringify({ "id": TEST_PREFIX + "b", "kind": "artifact", "title": "skipped one", "status": "pending" }),
		JSON.stringify({ "id": TEST_PREFIX + "c", "kind": "artifact", "title": "restored one", "status": "pending" }),
		JSON.stringify({ "id": TEST_PREFIX + "d", "kind": "evolver_candidate", "title": "decided evo", "status": "pending",
			"actions": [ { "id": "evolve", "label": "Evolve" } ] }),
	])
	_write_lines(fb_p, [
		JSON.stringify({ "artifact_id": TEST_PREFIX + "b", "action": "skip", "decided_at": "2026-07-02T00:00:01Z", "by": "liam" }),
		JSON.stringify({ "artifact_id": TEST_PREFIX + "c", "action": "skip", "decided_at": "2026-07-02T00:00:02Z", "by": "liam" }),
		JSON.stringify({ "artifact_id": TEST_PREFIX + "c", "action": "unskip", "decided_at": "2026-07-02T00:00:03Z", "by": "liam" }),
		JSON.stringify({ "artifact_id": TEST_PREFIX + "d", "action": "evolve", "decided_at": "2026-07-02T00:00:04Z", "by": "liam" }),
	])
	var visible := ApertureInbox.read_inbox_file(inbox_p, fb_p)
	var vis_ids: Array = []
	for v in visible:
		vis_ids.append(String(v.get("id")))
	ok = _check("file channel shows exactly the pending, un-hidden ids (a + c)",
		vis_ids == [TEST_PREFIX + "a", TEST_PREFIX + "c"]) and ok
	ok = _check("duplicate id collapsed LAST-WINS (corrected title shown)",
		String((visible[0] as Dictionary).get("title")) == "corrected title") and ok

	# --- 3. WRITE equivalence: file-mode rows + REAL python tool read-back ------------------------
	var out_fb := run_dir + "/out_feedback.jsonl"
	var out_bm := run_dir + "/out_bookmarks.jsonl"
	var writer := ApertureActions.new({ "mode": "file", "feedback_path": out_fb, "bookmarks_path": out_bm })
	var card := { "id": TEST_PREFIX + "w1", "title": "A card", "kind": "artifact",
		"images": ["G:/tmp/one.png"], "link": "http://x/y" }
	ok = _check("skip write ok", bool(writer.act(card, "skip").get("ok"))) and ok
	ok = _check("evolve write ok", bool(writer.act({ "id": TEST_PREFIX + "w2" }, "evolve").get("ok"))) and ok
	ok = _check("save write ok", bool(writer.act({ "id": TEST_PREFIX + "w2" }, "save").get("ok"))) and ok
	ok = _check("bookmark routed to bookmark channel",
		String(writer.act(card, "bookmark").get("channel")) == "bookmark") and ok
	ok = _check("unbookmark write ok", bool(writer.act(card, "unbookmark").get("ok"))) and ok
	var fb_rows := _read_jsonl(out_fb)
	ok = _check("feedback file holds 3 decision rows", fb_rows.size() == 3) and ok
	var r0: Dictionary = fb_rows[0]
	ok = _check("decision row schema matches aperture_feedback.record exactly",
		r0.get("artifact_id") == TEST_PREFIX + "w1" and r0.get("action") == "skip"
		and String(r0.get("by")) == "liam" and String(r0.get("decided_at")).ends_with("Z")
		and r0.keys().size() == 4) and ok
	var bm_rows := _read_jsonl(out_bm)
	var b0: Dictionary = bm_rows[0]
	ok = _check("bookmark row schema matches aperture_bookmark.record (tile_id/saved_at/by + context)",
		b0.get("tile_id") == TEST_PREFIX + "w1" and String(b0.get("saved_at")).ends_with("Z")
		and String(b0.get("by")) == "liam" and b0.get("title") == "A card"
		and b0.get("image_url") == "G:/tmp/one.png" and not b0.has("action")) and ok
	var b1: Dictionary = bm_rows[1]
	ok = _check("unbookmark row carries the toggle action", String(b1.get("action", "")) == "unbookmark") and ok

	# THE load-bearing equivalence proof: the REAL python tools read back what Godot wrote.
	var fb_abs := ProjectSettings.globalize_path(out_fb).replace("\\", "/")
	var py1 := _py([
		"import sys, pathlib",
		"sys.path.insert(0, 'G:/Wavelet/Alethea-cc/tools')",
		"import aperture_feedback as af",
		"af.feedback_path = lambda: pathlib.Path('%s')" % fb_abs,
		"d = af.latest_decision('%sw2')" % TEST_PREFIX,
		"print(d['action'], d['by'])",
	])
	ok = _check("aperture_feedback.py reads back Godot's rows (latest-wins: save)",
		py1.strip_edges() == "save liam") and ok
	var bm_abs := ProjectSettings.globalize_path(out_bm).replace("\\", "/")
	var py2 := _py([
		"import sys, pathlib",
		"sys.path.insert(0, 'G:/Wavelet/Alethea-cc/tools')",
		"import aperture_bookmark as ab",
		"ab.bookmarks_path = lambda: pathlib.Path('%s')" % bm_abs,
		"ids = ab.bookmarked_tile_ids()",
		"print(sorted(ids))",
	])
	ok = _check("aperture_bookmark.py reads back Godot's rows (unbookmark toggled OFF → empty set)",
		py2.strip_edges() == "[]") and ok

	# --- 4. The primitives drive the same modules through GraphRuntime ----------------------------
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({ "nodes": [
		{ "id": "inbox", "type": "ApertureInbox",
			"params": { "source": "file", "inbox_path": inbox_p, "feedback_path": fb_p } },
	], "wires": [] })
	var outs := rt.evaluate()
	var prim_cards: Array = (outs.get("inbox", {}) as Dictionary).get("cards", [])
	ok = _check("ApertureInbox primitive surfaces the same 2 cards", prim_cards.size() == 2) and ok
	var act_prim := PrimApertureAction.new()
	act_prim.params = { "mode": "file", "feedback_path": out_fb, "bookmarks_path": out_bm }
	var act_res: Dictionary = act_prim.evaluate({ "card": TEST_PREFIX + "w3", "action": "skip" }).get("result")
	ok = _check("ApertureAction primitive writes a decision row",
		bool(act_res.get("ok")) and _read_jsonl(out_fb).size() == 4) and ok

	# --- 5. LIVE ITERATION: file-write → LiveHost hotload → tile pixels change --------------------
	var wall_dir := run_dir + "/wall"
	var wall_arr := wall_dir + "/wall_arrangement.json"
	LiveWall.seed_arrangement(wall_arr, 3, 20260702)
	var wrt := GraphRuntime.new()
	get_root().add_child(wrt)
	var host := LiveHost.new()
	host.runtime = wrt
	host.path = wall_arr
	get_root().add_child(host)
	ok = _check("initial poll loads the wall arrangement", host.poll_once()) and ok
	ok = _check("3 tile Const nodes live in the runtime", LiveWall.tile_ids(wrt).size() == 3) and ok
	ok = _check("arrangement rev is stamped", host.rev == 1) and ok
	var desc0: Dictionary = (wrt.nodes["tile0"] as Primitive).params.get("value", {})
	var hash_before := _img_hash(TextureSynthCpu.synthesize(desc0, 32, 32))
	var nudged := LiveWall.nudge_gene(wall_arr, 0, 1.25)
	ok = _check("nudge_gene edited a schema gene on disk (%s)" % String(nudged.get("gene", "?")),
		bool(nudged.get("ok")) and int(nudged.get("rev")) == 2) and ok
	ok = _check("the gene VALUE actually changed", float(nudged.get("from")) != float(nudged.get("to"))) and ok
	ok = _check("hotload picks the file change up", host.poll_once() and host.rev == 2) and ok
	var desc1: Dictionary = (wrt.nodes["tile0"] as Primitive).params.get("value", {})
	var hash_after := _img_hash(TextureSynthCpu.synthesize(desc1, 32, 32))
	ok = _check("the synthesized tile PIXELS changed (live visual update)", hash_before != hash_after) and ok
	ok = _check("identical re-save does NOT retrigger (content-hash idempotence)", not host.poll_once()) and ok

	# --- 6. EVOLVER TICK (mock): seed → in-engine decisions → breed gen+1 -------------------------
	var evo_dir := run_dir + "/evolver"
	var evo_fb := evo_dir + "/feedback.json"
	var t1 := LiveWall.run_tick(evo_dir, evo_fb, 424242)
	ok = _check("tick 1 seeds generation 0 (4 texture candidates, mock-pushed)",
		int(t1.get("generation")) == 0 and int(t1.get("n_candidates")) == 4
		and bool(t1.get("pushed")) and not bool(t1.get("advanced"))) and ok
	var st := EvolverState.load_state(evo_dir)
	var all_texture := true
	for gd in st.get("population", []):
		if not (gd.get("stack", {}) as Dictionary).has("texture_ops"):
			all_texture = false
	ok = _check("gen-0 population is TEXTURE genomes", all_texture) and ok
	# decide every candidate in-engine (the same write the E/V/X keys perform on candidate tiles)
	var verdicts := ["evolve", "save", "evolve", "skip"]
	var cards_arr: Array = st.get("cards", [])
	for i in cards_arr.size():
		LiveWall.record_mock_decision(evo_fb, String((cards_arr[i] as Dictionary).get("card_id")), verdicts[i % verdicts.size()])
	var t2 := LiveWall.run_tick(evo_dir, evo_fb, 424242)
	ok = _check("tick 2 advances to generation 1 after in-engine decisions",
		bool(t2.get("advanced")) and int(t2.get("next_generation")) == 1) and ok
	ok = _check("generation 1 persisted", int(EvolverState.load_state(evo_dir).get("generation", -1)) == 1) and ok

	# --- 7. LIVE GUARDS ----------------------------------------------------------------------------
	ok = _check("live inbox row count unchanged (no live pushes from this run)",
		_line_count(LIVE_INBOX) == live_inbox_before) and ok
	ok = _check("live feedback.jsonl carries NO rows with this test's ids",
		_rows_with_prefix(LIVE_FEEDBACK, TEST_PREFIX) == live_fb_test_rows_before
		and live_fb_test_rows_before == 0) and ok

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail_count))
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

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

func _read_jsonl(path: String) -> Array:
	var out: Array = []
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("user://") or path.begins_with("res://") else path
	if not FileAccess.file_exists(abs):
		return out
	for line in FileAccess.get_file_as_string(abs).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out

func _line_count(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	var n := 0
	for line in FileAccess.get_file_as_string(path).split("\n"):
		if line.strip_edges() != "":
			n += 1
	return n

func _rows_with_prefix(path: String, prefix: String) -> int:
	var n := 0
	for row in _read_jsonl(path):
		if String(row.get("artifact_id", row.get("tile_id", ""))).begins_with(prefix):
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
