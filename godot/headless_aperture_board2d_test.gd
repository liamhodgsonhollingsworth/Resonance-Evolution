extends SceneTree
## Headless parity proof for the 2D GODOT APERTURE BOARD — the "functions the exact same as the
## web board" verification (Liam 2026-07-03, card apx_11a5dce2). ZERO live pollution: every write
## goes to a temp dir; live-substrate guards assert nothing leaked. Real assertions, PASS/FAIL
## tally, nonzero exit.
##   godot --headless --path godot -s res://headless_aperture_board2d_test.gd
##
## What it proves:
##  1. BUCKET PARITY: a fixture inbox routes exactly as aperture.js routes it — evolver candidates
##     to the evolver entry (never grid/banner), preview/decision pushes to the notifications
##     banner, ambient content to the grid; the FILE channel mirrors the SERVER's routing rules.
##  2. ORDER PARITY (the load-bearing cross-check): disperse_by_type's output order is compared to
##     the REAL aperture.js contentTypeOf+disperseByType executed via node on the SAME fixture —
##     identical id order + identical per-tile content types, or FAIL.
##  3. Cap (BOARD_CAP), pinned hoist, and determinism match the web constants/behavior.
##  4. TILE INSTANTIATION: ApertureBoard2D (file mode, fixture substrate) renders the same tiles
##     in the same regions — grid tile count/ids, banner rows, the "N candidates are waiting"
##     evolver entry, and the ChatPanelSlot embed point for the peer chat lane.
##  5. WRITE ROUND-TRIP: skip/bookmark/undo through the board write rows byte-compatible with the
##     web files — the REAL aperture_feedback.py / aperture_bookmark.py read back what the board
##     wrote, and skip ids match the web's skipId semantics (unprefixed substrate ids for
##     feedback; web DOM tile ids for bookmarks).
##  6. VIEWPORT INTERACTION (input-fix arc, 2026-07-03): real InputEventMouseButton pushed
##     through the viewport at each affordance's ON-SCREEN rect, so occlusion / mouse-filter /
##     wrong-action bugs are caught — image-region clicks open the card (the image wrapper used
##     to eat them), opens fire on press+release-inside (web `click` semantics), never on the
##     bare press, resonance:// scene-link cards launch in-engine, hover reveals ✕/☆, clicking
##     ✕ skips the RIGHT card without click-through, decision buttons record their verbatim
##     action id, and wheel scroll still reaches the ScrollContainer over STOP tiles.
##  7. LIVE GUARDS: the live inbox/feedback/bookmarks gained no rows from this run.

const LIVE_INBOX := "G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl"
const LIVE_FEEDBACK := "G:/Wavelet/Alethea-cc/state/aperture/feedback.jsonl"
const LIVE_BOOKMARKS := "G:/Wavelet/Alethea-cc/state/aperture/bookmarks.jsonl"
const APERTURE_JS_CANDIDATES := [
	"G:/Wavelet/repos/Resonance-Website/static/aperture/aperture.js",
	"G:/Wavelet/repos/RW-aperture-preview/static/aperture/aperture.js",
]
const TEST_PREFIX := "ap2dtest_"

# Class-cache-independent loads (grey-screen defect, 2026-07-03): the suite must run on a FRESH
# checkout with NO .godot class cache — exactly the context that produced the defect — so every
# aperture class is resolved by PATH here too.
const ApertureBoardLogic = preload("res://aperture/aperture_board_logic.gd")
const ApertureInbox = preload("res://aperture/aperture_inbox.gd")
const ApertureBoard2D = preload("res://aperture/aperture_board_2d.gd")

var _fail_count := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail_count += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	var ok := true
	var run_dir := "user://aperture2d_test"
	_rm_rf(run_dir)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(run_dir))
	var live_inbox_before := _line_count(LIVE_INBOX)
	var live_fb_before := _rows_with_prefix(LIVE_FEEDBACK, TEST_PREFIX)
	var live_bm_before := _rows_with_prefix(LIVE_BOOKMARKS, TEST_PREFIX)

	# ---- fixture: a mixed inbox (raw rows, server shape minus the annotations) -------------------
	var content_rows := _content_fixture()
	var rows: Array = []
	rows.append({ "id": TEST_PREFIX + "evo1", "kind": "evolver_candidate", "title": "Texture A",
		"media": { "image_url": "G:/nonexistent/a.png" }, "status": "pending", "generation": 0,
		"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ],
		"disposition": "decision" })
	rows.append({ "id": TEST_PREFIX + "evo2", "kind": "evolver_candidate", "title": "Texture B",
		"media": { "image_url": "G:/nonexistent/b.png" }, "status": "pending", "generation": 0,
		"actions": [ { "id": "evolve", "label": "Evolve" } ], "disposition": "decision" })
	rows.append({ "id": TEST_PREFIX + "notif_q", "kind": "question", "title": "A genuine decision",
		"media": { "text": "pick one" }, "status": "pending", "disposition": "decision",
		"actions": [ { "id": "yes", "label": "Yes" }, { "id": "no", "label": "No" } ] })
	rows.append({ "id": TEST_PREFIX + "notif_prev", "kind": "preview", "title": "Look at this",
		"media": { "text": "a show-you push", "link": "http://127.0.0.1:1/x" }, "status": "pending",
		"disposition": "content" })
	rows.append_array(content_rows)

	var inbox_p := run_dir + "/inbox.jsonl"
	var fb_p := run_dir + "/feedback.jsonl"
	var bm_p := run_dir + "/bookmarks.jsonl"
	var lines: Array = []
	for r in rows:
		lines.append(JSON.stringify(r))
	_write_lines(inbox_p, lines)
	_write_lines(fb_p, [])

	# ---- 1. bucket parity (file channel = server routing) ----------------------------------------
	var cards: Array = []
	for r in rows:
		cards.append(ApertureBoardLogic.normalize_row(r))
	var composed := ApertureBoardLogic.compose(cards)
	var evolver: Array = composed["evolver"]
	var notifs: Array = composed["notifications"]
	var grid: Array = composed["grid"]
	ok = _check("evolver candidates route to the evolver bucket (2)", evolver.size() == 2) and ok
	ok = _check("decision + preview pushes route to the notifications banner (2)",
		notifs.size() == 2 and String((notifs[0] as Dictionary).get("id")).ends_with("notif_q")
		and String((notifs[1] as Dictionary).get("id")).ends_with("notif_prev")) and ok
	ok = _check("ambient content routes to the grid (%d)" % content_rows.size(),
		grid.size() == content_rows.size()) and ok
	var grid_has_misrouted := false
	for g in grid:
		if ApertureBoardLogic.is_evolver_candidate(g) or ApertureBoardLogic.is_notification(g):
			grid_has_misrouted = true
	ok = _check("no evolver/notification card leaks into the grid", not grid_has_misrouted) and ok

	# ---- 2. ORDER PARITY vs the REAL aperture.js (node cross-check) ------------------------------
	var gd_ids: Array = []
	var gd_types: Array = []
	for g in grid:
		gd_ids.append(String((g as Dictionary).get("id")))
		gd_types.append(ApertureBoardLogic.content_type_of(g))
	var aperture_js := ""
	for cand in APERTURE_JS_CANDIDATES:
		if FileAccess.file_exists(cand):
			aperture_js = cand
			break
	var node_ok := false
	var node_out := ""
	if aperture_js != "":
		var web_tiles: Array = []
		for r in content_rows:
			var row: Dictionary = r
			var media: Dictionary = row.get("media", {})
			var imgs: Array = []
			var mimgs = media.get("images")
			if typeof(mimgs) == TYPE_ARRAY:
				for u in mimgs:
					imgs.append(String(u))
			if imgs.is_empty() and media.get("image_url") != null and String(media.get("image_url")) != "":
				imgs.append(String(media.get("image_url")))
			# artifactToTile shape: kind "artifact", category "artifact", media carried through
			web_tiles.append({ "id": row.get("id"), "kind": "artifact", "category": "artifact",
				"title": row.get("title", ""), "subtitle": row.get("subtitle"),
				"summary": row.get("summary"), "media": { "link": media.get("link"), "text": media.get("text") },
				"images": imgs, "image_url": imgs[0] if imgs.size() > 0 else null })
		var tiles_json := run_dir + "/web_tiles.json"
		_write_lines(tiles_json, [JSON.stringify(web_tiles)])
		var mjs := run_dir + "/xcheck.mjs"
		_write_lines(mjs, [
			"import fs from \"fs\";",
			"const src = fs.readFileSync(process.argv[2], \"utf8\");",
			"const start = src.indexOf(\"/* ---------------------------------------------- content-TYPE dispersion\");",
			"const end = src.indexOf(\"/* --------------------------------------------------------------- pool / refill */\");",
			"if (start < 0 || end < 0) { console.error(\"block not found\"); process.exit(2); }",
			"const mod = new Function(src.slice(start, end) + \"\\nreturn { contentTypeOf, disperseByType };\")();",
			"const tiles = JSON.parse(fs.readFileSync(process.argv[3], \"utf8\"));",
			"const out = mod.disperseByType(tiles);",
			"console.log(JSON.stringify({ ids: out.map(t => t.id), types: out.map(mod.contentTypeOf) }));",
		])
		var stdout: Array = []
		var code := OS.execute("node", [ProjectSettings.globalize_path(mjs), aperture_js,
			ProjectSettings.globalize_path(tiles_json)], stdout, true)
		node_out = "\n".join(stdout).strip_edges()
		if code == 0 and node_out != "":
			var out_lines := node_out.split("\n")
			var parsed = JSON.parse_string(String(out_lines[out_lines.size() - 1]))
			if typeof(parsed) == TYPE_DICTIONARY:
				var js_ids: Array = parsed.get("ids", [])
				var js_types: Array = parsed.get("types", [])
				node_ok = true
				ok = _check("ORDER PARITY: GDScript disperse order == REAL aperture.js disperse order",
					str(js_ids) == str(gd_ids)) and ok
				ok = _check("TYPE PARITY: GDScript content types == REAL aperture.js content types",
					str(js_types) == str(gd_types)) and ok
	if not node_ok:
		# node or aperture.js unavailable → the cross-check cannot run; that is a FAIL here because
		# this check is the load-bearing equivalence proof on this host (node is installed).
		ok = _check("node cross-check executed (node + aperture.js present) [" + node_out + "]", false) and ok

	# determinism (the web algorithm is deliberately stable across reloads)
	var again: Array = []
	for g in ApertureBoardLogic.compose(cards)["grid"]:
		again.append(String((g as Dictionary).get("id")))
	ok = _check("dispersion is deterministic across composes", str(again) == str(gd_ids)) and ok

	# ---- 3. cap + pinned hoist --------------------------------------------------------------------
	var many: Array = []
	for i in 40:
		many.append(ApertureBoardLogic.normalize_row({ "id": TEST_PREFIX + "bulk%02d" % i,
			"kind": "artifact", "title": "Bulk %d" % i, "media": { "text": "t%d" % i },
			"status": "pending", "disposition": "content" }))
	ok = _check("grid is capped at BOARD_CAP=30 (web Spec 5)",
		(ApertureBoardLogic.compose(many)["grid"] as Array).size() == 30) and ok
	var pinned_board := [
		ApertureBoardLogic.normalize_board_tile({ "id": "tile_x1", "kind": "content",
			"category": "art", "title": "unpinned", "link_url": "https://example.com/a" }),
		ApertureBoardLogic.normalize_board_tile({ "id": "tile_writing_evolution", "kind": "writing_evolution",
			"category": "module", "title": "Writing Evolution", "pinned": true }),
	]
	var with_board: Array = ApertureBoardLogic.compose(cards.slice(0, 8), pinned_board)["grid"]
	ok = _check("pinned board tile hoists to the FRONT of the grid (hoistPinned)",
		with_board.size() > 0 and String((with_board[0] as Dictionary).get("id")) == "tile_writing_evolution") and ok

	# ---- 4. tile instantiation (the board scene, file mode, zero network) -------------------------
	var board := ApertureBoard2D.new()
	board.config = {
		"mode": "file",
		"base_url": "http://127.0.0.1:1",   # never used in file mode
		"inbox_path": inbox_p,
		"feedback_path": fb_p,
		"bookmarks_path": bm_p,
		"board_json_path": "",
		"mount_chat": false,                # the chat panel is the peer lane's own tested scene
	}
	board.size = Vector2(1600, 1000)
	get_root().add_child(board)
	await process_frame          # let the deferred _ready build the UI first
	await board.refresh()
	var shown: Array = board._last_compose.get("grid", [])
	var tile_count := 0
	for col in board._masonry.get_children():
		tile_count += (col as VBoxContainer).get_child_count()
	ok = _check("grid renders one tile Control per composed card (%d)" % shown.size(),
		tile_count == shown.size() and board._displayed.size() == shown.size()) and ok
	ok = _check("grid compose order matches the pure-logic order (same tiles, same order)",
		str(_ids_of(shown)) == str(gd_ids)) and ok
	ok = _check("notifications banner shows the 2 pushed notifications",
		board._notif_row.visible and board._notif_row.get_child_count() == 2) and ok
	var entry_text := _all_label_text(board._evolver_row)
	ok = _check("evolver entry tile: 'Evolution' + '2 candidates are waiting' (web strings)",
		board._evolver_row.visible and "Evolution" in entry_text
		and "2 candidates are waiting" in entry_text and "Open the evolution page" in entry_text) and ok
	ok = _check("ChatPanelSlot embed point exists for the peer chat lane",
		board.chat_panel_slot != null and board.chat_panel_slot.name == "ChatPanelSlot"
		and board.chat_panel_slot.get_child_count() == 0) and ok
	ok = _check("defensive status line names the file substrate + card count (grey-screen floor)",
		board._status_label != null and "file substrate" in board._status_label.text
		and "cards" in board._status_label.text) and ok

	# defensive floor: an EMPTY substrate must still say something visible (never a silent grey board)
	var empty_dir := run_dir + "/empty"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(empty_dir))
	_write_lines(empty_dir + "/inbox.jsonl", [])
	_write_lines(empty_dir + "/feedback.jsonl", [])
	var board0 := ApertureBoard2D.new()
	board0.config = { "mode": "file", "base_url": "http://127.0.0.1:1",
		"inbox_path": empty_dir + "/inbox.jsonl", "feedback_path": empty_dir + "/feedback.jsonl",
		"bookmarks_path": empty_dir + "/bookmarks.jsonl", "board_json_path": "", "mount_chat": false }
	board0.size = Vector2(1600, 1000)
	get_root().add_child(board0)
	await process_frame
	await board0.refresh()
	ok = _check("EMPTY substrate → status line says 0 cards + an empty-board hint (grey-screen floor)",
		board0._status_label != null and "0 cards" in board0._status_label.text
		and "empty board" in board0._status_label.text) and ok
	board0.queue_free()

	# ---- 5. write round-trip (byte-compatible with the web files) ---------------------------------
	var first: Dictionary = shown[0]
	var first_tile: Control = board._displayed[String(first.get("id"))]
	board._skip(first, first_tile)
	var fb_rows := _read_jsonl(fb_p)
	ok = _check("skip writes ONE feedback row", fb_rows.size() == 1) and ok
	if fb_rows.size() == 1:
		var r0: Dictionary = fb_rows[0]
		ok = _check("skip row is byte-compatible: {artifact_id, action, decided_at, by} under the web skipId",
			r0.get("artifact_id") == first.get("skip_id") and r0.get("action") == "skip"
			and String(r0.get("by")) == "liam" and String(r0.get("decided_at")).ends_with("Z")
			and r0.keys().size() == 4) and ok
	ok = _check("skipped tile leaves the displayed set", not board._displayed.has(String(first.get("id")))) and ok
	var fb_abs := ProjectSettings.globalize_path(fb_p).replace("\\", "/")
	var py1 := _py([
		"import sys, pathlib",
		"sys.path.insert(0, 'G:/Wavelet/Alethea-cc/tools')",
		"import aperture_feedback as af",
		"af.feedback_path = lambda: pathlib.Path('%s')" % fb_abs,
		"d = af.latest_decision('%s')" % String(first.get("skip_id")),
		"print(d['action'], d['by'])",
	])
	ok = _check("REAL aperture_feedback.py reads the board's skip back", py1.strip_edges() == "skip liam") and ok

	# undo (Ctrl+Z parity): durable unskip; the web's hidden-set no longer hides the id
	board._undo_archive()
	fb_rows = _read_jsonl(fb_p)
	ok = _check("undo appends an 'unskip' row (append-only supersession)",
		fb_rows.size() == 2 and fb_rows[1].get("action") == "unskip"
		and fb_rows[1].get("artifact_id") == first.get("skip_id")) and ok
	ok = _check("after undo the id is un-hidden (latest-action-wins, same semantics the web reads)",
		not ApertureInbox.hidden_ids(fb_p).has(String(first.get("skip_id")))) and ok
	ok = _check("undo restores the tile to the grid", board._displayed.has(String(first.get("id")))) and ok

	# bookmark: keyed on the web DOM tile id ("tile_artifact_<id>"), read back by the real tool
	var second: Dictionary = shown[1]
	var dummy_btn := Button.new()
	get_root().add_child(dummy_btn)
	board._bookmark(second, dummy_btn)
	var bm_rows := _read_jsonl(bm_p)
	var want_dom := "tile_artifact_" + String(second.get("id"))
	ok = _check("bookmark row carries the web DOM tile id + saved_at/by (byte-compatible)",
		bm_rows.size() == 1 and bm_rows[0].get("tile_id") == want_dom
		and String(bm_rows[0].get("by")) == "liam"
		and String(bm_rows[0].get("saved_at")).ends_with("Z")) and ok
	ok = _check("bookmark button flips to the saved ★", dummy_btn.text == "★") and ok
	var bm_abs := ProjectSettings.globalize_path(bm_p).replace("\\", "/")
	var py2 := _py([
		"import sys, pathlib",
		"sys.path.insert(0, 'G:/Wavelet/Alethea-cc/tools')",
		"import aperture_bookmark as ab",
		"ab.bookmarks_path = lambda: pathlib.Path('%s')" % bm_abs,
		"print(sorted(ab.bookmarked_tile_ids()))",
	])
	ok = _check("REAL aperture_bookmark.py reads the board's save back",
		py2.strip_edges() == "['%s']" % want_dom) and ok

	# ---- 6. viewport-level interaction (input-fix arc, 2026-07-03) --------------------------------
	# Every click below is a REAL InputEventMouseButton pushed through the viewport at the
	# affordance's on-screen rect — the same routing (hit test, mouse_filter, z-order, capture)
	# a live mouse goes through — so "looks clickable but is not hittable" and "fires the wrong
	# action" both FAIL here. Headless has no OS cursor, so Button-hover is established the way
	# probe'd empirically: NOTIFICATION_MOUSE_ENTER + NOTIFICATION_MOUSE_ENTER_SELF, then the
	# synthesized press+release fires BaseButton.pressed exactly like a real click.
	board.queue_free()                                # clear earlier boards off the hit-test plane
	dummy_btn.queue_free()
	await process_frame
	await process_frame

	var idir := run_dir + "/interact"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(idir))
	# a REAL loadable image, so the image region renders (a broken image degrades to text style)
	var real_img := Image.create(64, 48, false, Image.FORMAT_RGB8)
	real_img.fill(Color(0.2, 0.4, 0.6))
	var img_path := ProjectSettings.globalize_path(idir + "/real.png").replace("\\", "/")
	real_img.save_png(img_path)
	var irows := [
		{ "id": TEST_PREFIX + "iimg", "kind": "artifact", "title": "Clickable image card",
			"media": { "image_url": img_path, "link": "https://example.com/openme" },
			"status": "pending", "disposition": "content" },
		{ "id": TEST_PREFIX + "iscene", "kind": "artifact", "title": "Open the WFC demo",
			"media": { "text": "a scene link",
				"link": "resonance://open?target=godot&scene=res%3A%2F%2Fexamples%2Fwfc_demo.tscn&mode=2d" },
			"status": "pending", "disposition": "content" },
		{ "id": TEST_PREFIX + "itxt", "kind": "artifact", "title": "Text card",
			"media": { "text": "body", "link": "https://example.com/text" },
			"status": "pending", "disposition": "content" },
		{ "id": TEST_PREFIX + "idec", "kind": "question", "title": "Decide me",
			"media": { "text": "pick" }, "status": "pending", "disposition": "decision",
			"actions": [ { "id": "yes", "label": "Yes" }, { "id": "no", "label": "No" } ] },
	]
	var ilines: Array = []
	for r in irows:
		ilines.append(JSON.stringify(r))
	_write_lines(idir + "/inbox.jsonl", ilines)
	_write_lines(idir + "/feedback.jsonl", [])

	# The headless root window is tiny (100x100) and a ScrollContainer CLIPS hit-testing to its
	# visible rect, so the board is hosted in an explicitly-sized parent Control — the FULL_RECT
	# anchors then size the board (and its scroll viewport) to 1600x1000 regardless of the window.
	var host := Control.new()
	host.size = Vector2(1600, 1000)
	get_root().add_child(host)
	var board2 := ApertureBoard2D.new()
	board2.config = { "mode": "file", "base_url": "http://127.0.0.1:1",
		"inbox_path": idir + "/inbox.jsonl", "feedback_path": idir + "/feedback.jsonl",
		"bookmarks_path": idir + "/bookmarks.jsonl", "board_json_path": "", "mount_chat": false }
	var opened: Array = []
	board2.open_url_handler = func(u): opened.append(String(u))
	var launched: Array = []
	# set() so a board WITHOUT the seam (pre-fix) still runs — and then FAILS the launch assert
	board2.set("scene_launch_handler", func(c): launched.append(String((c as Dictionary).get("id", ""))))
	host.add_child(board2)
	# A scripted-in (no .tscn) board child of a plain Control lays out 0x0 — the live scene gets
	# its FULL_RECT from aperture_board_2d.tscn. Apply the same anchors+offsets explicitly so the
	# scroll viewport (which CLIPS hit-testing) actually covers the 1600x1000 host.
	board2.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	await board2.refresh()
	await process_frame
	await process_frame

	# 6a. the IMAGE REGION opens the card (the image wrapper PanelContainer used to eat the click)
	var t_img: Control = board2._displayed[TEST_PREFIX + "iimg"]
	var img_region := (t_img.get_child(0) as Control).get_child(0) as Control
	ok = _check("image tile renders a non-degraded image region",
		img_region.visible and img_region.get_global_rect().size.y > 20.0) and ok
	_vp_click(img_region.get_global_rect().get_center())
	await process_frame
	ok = _check("click on the IMAGE REGION opens the card link (wrapper no longer eats it)",
		str(opened) == str(["https://example.com/openme"])) and ok

	# 6b. web `click` semantics: a bare press opens nothing; press-then-release-outside aborts
	opened.clear()
	var t_txt: Control = board2._displayed[TEST_PREFIX + "itxt"]
	var txt_center := t_txt.get_global_rect().get_center()
	_vp_button(txt_center, true)
	await process_frame
	ok = _check("bare mouse-DOWN opens nothing (web fires on click, not press)", opened.is_empty()) and ok
	_vp_button(Vector2(2, 998), false)
	await process_frame
	ok = _check("press then release-OUTSIDE opens nothing (aborted click)", opened.is_empty()) and ok

	# 6c. a full press+release on the same tile opens exactly once, with the RIGHT destination
	_vp_click(txt_center)
	await process_frame
	ok = _check("press+release on the SAME tile opens its OWN link exactly once",
		str(opened) == str(["https://example.com/text"])) and ok

	# 6d. a resonance:// scene-link card launches the scene IN-ENGINE, never a url open
	opened.clear()
	var t_sc: Control = board2._displayed[TEST_PREFIX + "iscene"]
	_vp_click(t_sc.get_global_rect().get_center())
	await process_frame
	ok = _check("scene_link card launches in-engine via the launcher seam (no shell_open)",
		str(launched) == str([TEST_PREFIX + "iscene"]) and opened.is_empty()) and ok

	# 6e. hover reveals ✕/☆; clicking ✕ skips the RIGHT card and does NOT click through
	opened.clear()
	var skip_btn := _find_glyph_button(t_img, "✕")
	ok = _check("✕ skip button exists and is hidden until hover",
		skip_btn != null and not skip_btn.visible) and ok
	_hover(t_img)
	ok = _check("hovering the tile reveals the ✕ skip button", skip_btn != null and skip_btn.visible) and ok
	if skip_btn != null:
		_hover(skip_btn)
		_vp_click(skip_btn.get_global_rect().get_center())
		await process_frame
	var ifb := _read_jsonl(idir + "/feedback.jsonl")
	ok = _check("clicking ✕ writes the durable skip for the RIGHT card (button actually hittable)",
		ifb.size() == 1 and ifb[0].get("action") == "skip"
		and ifb[0].get("artifact_id") == TEST_PREFIX + "iimg") and ok
	ok = _check("clicking ✕ does NOT also open the card underneath (no click-through)",
		opened.is_empty()) and ok
	ok = _check("the skipped tile leaves the grid", not board2._displayed.has(TEST_PREFIX + "iimg")) and ok

	# 6f. a decision banner button records its verbatim action id (right action, right card)
	var t_dec: Control = board2._notif_row.get_child(0)
	var yes_btn := _find_glyph_button(t_dec, "Yes")
	ok = _check("decision card renders its Yes action button", yes_btn != null) and ok
	if yes_btn != null:
		_hover(yes_btn)
		_vp_click(yes_btn.get_global_rect().get_center())
		await process_frame
	ifb = _read_jsonl(idir + "/feedback.jsonl")
	ok = _check("clicking Yes records the verbatim action id for the decision card",
		ifb.size() == 2 and ifb[1].get("action") == "yes"
		and ifb[1].get("artifact_id") == TEST_PREFIX + "idec") and ok
	ok = _check("deciding never opens a url", opened.is_empty()) and ok

	# 6g. wheel scroll still reaches the ScrollContainer over STOP tiles (regression guard)
	host.size = Vector2(1600, 60)           # shrink the viewport so the content overflows
	await process_frame
	await process_frame
	# a point that is BOTH inside the visible scroll rect and on a remaining tile
	var vis := (board2._scroll as Control).get_global_rect()
	var trect := (board2._displayed[TEST_PREFIX + "itxt"] as Control).get_global_rect()
	var wheel_at := Vector2(trect.get_center().x,
		clampf(trect.position.y + 5.0, vis.position.y + 5.0, vis.end.y - 5.0))
	for i in 3:
		var w := InputEventMouseButton.new()
		w.button_index = MOUSE_BUTTON_WHEEL_DOWN
		w.pressed = true
		w.position = wheel_at
		w.global_position = wheel_at
		w.factor = 1.0
		get_root().push_input(w)
	await process_frame
	ok = _check("mouse wheel over a tile scrolls the board (nothing eats the wheel)",
		board2._scroll.scroll_vertical > 0) and ok
	host.queue_free()
	await process_frame

	# ---- 7. live guards ----------------------------------------------------------------------------
	ok = _check("live inbox unchanged", _line_count(LIVE_INBOX) == live_inbox_before) and ok
	ok = _check("live feedback gained no test rows",
		_rows_with_prefix(LIVE_FEEDBACK, TEST_PREFIX) == live_fb_before) and ok
	ok = _check("live bookmarks gained no test rows",
		_rows_with_prefix(LIVE_BOOKMARKS, TEST_PREFIX) == live_bm_before) and ok

	print("RESULT: ", "ALL PASS" if ok else ("%d FAIL" % _fail_count))
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# fixture — the exact clumped shape the web dispersion test uses (images, then papers, then art,
# then text, then multi-image places), so the cross-check exercises every content-type bucket.
# ---------------------------------------------------------------------------------------------------

func _content_fixture() -> Array:
	var rows: Array = []
	for i in 4:
		rows.append({ "id": TEST_PREFIX + "img%d" % i, "kind": "artifact", "title": "Astro %d" % i,
			"media": { "image_url": "G:/nonexistent/img%d.png" % i }, "status": "pending",
			"disposition": "content" })
	for i in 4:
		rows.append({ "id": TEST_PREFIX + "pap%d" % i, "kind": "artifact", "title": "Paper %d" % i,
			"media": { "link": "https://arxiv.org/abs/2401.0%d" % i, "text": "abstract %d" % i },
			"status": "pending", "disposition": "content" })
	for i in 3:
		rows.append({ "id": TEST_PREFIX + "art%d" % i, "kind": "artifact", "title": "Portfolio %d" % i,
			"media": { "link": "https://www.artstation.com/artwork/x%d" % i }, "status": "pending",
			"disposition": "content" })
	for i in 3:
		rows.append({ "id": TEST_PREFIX + "txt%d" % i, "kind": "artifact", "title": "Article %d" % i,
			"media": { "text": "body text %d" % i, "link": "https://example.com/a%d" % i },
			"status": "pending", "disposition": "content" })
	for i in 2:
		rows.append({ "id": TEST_PREFIX + "plc%d" % i, "kind": "artifact", "title": "Structure %d" % i,
			"media": { "images": ["G:/nonexistent/p%da.png" % i, "G:/nonexistent/p%db.png" % i] },
			"status": "pending", "disposition": "content" })
	return rows

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

# ---- viewport-interaction helpers (input-fix arc, 2026-07-03) ------------------------------------

## One synthesized left-button press at `pos` (window coords), routed through the viewport's
## real hit-testing — exactly what a physical mouse press produces.
func _vp_button(pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev)

## A full click: press + release at the same point (the web `click` gesture).
func _vp_click(pos: Vector2) -> void:
	_vp_button(pos, true)
	_vp_button(pos, false)

## Establish hover in headless (no OS cursor). Two distinct mechanisms, both needed:
##   * BaseButton only fires `pressed` on the release when its INTERNAL hover flag is set —
##     empirically (Godot 4.6) that flag is set by NOTIFICATION_MOUSE_ENTER(+_SELF);
##   * the `mouse_entered` SIGNAL (what the tile's reveal handler listens to) is emitted by the
##     viewport's live cursor tracking, NOT by the notification — emit it explicitly.
func _hover(ctrl: Control) -> void:
	ctrl.notification(Control.NOTIFICATION_MOUSE_ENTER)
	if "NOTIFICATION_MOUSE_ENTER_SELF" in ClassDB.class_get_integer_constant_list("Control"):
		ctrl.notification(ClassDB.class_get_integer_constant("Control", "NOTIFICATION_MOUSE_ENTER_SELF"))
	ctrl.emit_signal("mouse_entered")

## Depth-first search for the Button whose text is `glyph` under `node` (✕ / ☆ / action labels).
func _find_glyph_button(node: Node, glyph: String) -> Button:
	if node is Button and (node as Button).text == glyph:
		return node
	for c in node.get_children():
		var hit := _find_glyph_button(c, glyph)
		if hit != null:
			return hit
	return null

func _ids_of(cards: Array) -> Array:
	var out: Array = []
	for c in cards:
		out.append(String((c as Dictionary).get("id")))
	return out

func _all_label_text(node: Node) -> String:
	var parts: Array = []
	if node is Label:
		parts.append((node as Label).text)
	for c in node.get_children():
		parts.append(_all_label_text(c))
	return " ".join(parts)

func _py(lines: Array) -> String:
	var out := []
	var code := OS.execute("py", ["-c", "\n".join(lines)], out, true)
	if code != 0:
		var code2 := OS.execute("python3", ["-c", "\n".join(lines)], out, true)
		if code2 != 0:
			return "PYFAIL: " + "\n".join(out)
	return "\n".join(out)

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
