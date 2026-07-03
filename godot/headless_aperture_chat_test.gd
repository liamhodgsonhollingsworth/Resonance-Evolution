extends SceneTree
## Headless verification of the Aperture chat store + scene-link launcher:
##
##   godot --headless --path godot -s res://headless_aperture_chat_test.gd
##   godot --headless --path godot -s res://headless_aperture_chat_test.gd -- --live
##
## Proves (all against a TEMP channel dir — the live chat is never touched):
##   * chat write/read ROUND-TRIP in the exact web schema (acm_<hex32> id, ISO-8601Z ts,
##     verbatim text incl. unicode, in_reply_to threading);
##   * durability semantics mirror aperture_chat.py: per-message recovery copies reconcile a
##     LOST chat.jsonl (deleted file / torn line) back into every read;
##   * events.jsonl folding (assigned_to last-label-wins, read_by union);
##   * scene_link parsing (dict + resonance:// URL forms), SAFETY rejections (traversal,
##     drive letter, whitespace, bad extension), and exact spawn-argv construction;
##   * with `-- --live`: actually spawns the painterly 3D scene in a separate window,
##     verifies the process is running, then kills it (host-only; not for CI).
## Mirrors headless_chip_test.gd style (PASS/FAIL lines, RESULT, non-zero exit on failure).

# Class-cache-independent loads (mistake #046 / grey-screen defect, 2026-07-03): resolve the
# classes under test by PATH so this suite parses on a fresh checkout with NO .godot class
# cache — the exact context the desktop-shortcut launcher runs in. Before this, the whole
# file failed to PARSE without a cache ("Identifier ApertureSceneLauncher not declared").
const ApertureChatStore = preload("res://aperture/aperture_chat_store.gd")
const ApertureSceneLauncher = preload("res://aperture/scene_launcher.gd")

var _ok := true


func _initialize() -> void:
	var tmp := OS.get_user_data_dir() + "/tmp_chat_test_" + str(Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(tmp)

	_test_chat_roundtrip(tmp)
	_test_chat_recovery(tmp)
	_test_events_fold(tmp)
	_test_scene_link_parse()
	_test_scene_link_safety()
	_test_scene_link_argv()
	if OS.get_cmdline_user_args().has("--live"):
		_test_live_spawn()

	_cleanup(tmp)
	print("RESULT: %s" % ("PASS" if _ok else "FAIL"))
	quit(0 if _ok else 1)


func _check(name: String, cond: bool) -> void:
	print("%s: %s" % ["PASS" if cond else "FAIL", name])
	_ok = _ok and cond


# ---------------------------------------------------------------- chat round-trip
func _test_chat_roundtrip(tmp: String) -> void:
	var d := tmp + "/rt"
	var text1 := "iterate: make the sky more purple — テスト ünïcode"
	var r1 := ApertureChatStore.append_message(d, "liam", text1)
	_check("append returns a row", not r1.is_empty())
	var id1 := String(r1.get("id", ""))
	_check("id is acm_<hex32>", id1.begins_with("acm_") and id1.length() == 4 + 32)
	var ts := String(r1.get("ts", ""))
	_check("ts is ISO-8601 Z", ts.length() == 20 and ts.ends_with("Z") and ts[10] == "T")
	var r2 := ApertureChatStore.append_message(d, "session-abc", "on it", id1)
	_check("reply row created", not r2.is_empty())

	var msgs := ApertureChatStore.read_messages(d)
	_check("round-trip: 2 messages", msgs.size() == 2)
	_check("text VERBATIM", msgs.size() == 2 and String(msgs[0]["text"]) == text1)
	_check("in_reply_to threads", msgs.size() == 2 and String(msgs[1]["in_reply_to"]) == id1)
	_check("first message unthreaded (null)", msgs.size() == 2 and msgs[0]["in_reply_to"] == null)
	_check("empty text rejected", ApertureChatStore.append_message(d, "liam", "   ").is_empty())

	# Schema equivalence: the chat.jsonl line must be one JSON object per line with the exact
	# five web-schema keys (what aperture_chat.py / the web board parse).
	var lines := FileAccess.get_file_as_string(d + "/chat.jsonl").strip_edges().split("\n")
	_check("chat.jsonl has 2 lines", lines.size() == 2)
	var parsed = JSON.parse_string(lines[0])
	var keys_ok: bool = typeof(parsed) == TYPE_DICTIONARY and parsed.has("id") and parsed.has("ts") \
		and parsed.has("from") and parsed.has("text") and parsed.has("in_reply_to")
	_check("row carries the 5 schema keys", keys_ok)
	_check("per-message recovery copy exists",
		FileAccess.file_exists(d + "/messages/" + id1 + ".json"))


# ---------------------------------------------------------------- recovery semantics
func _test_chat_recovery(tmp: String) -> void:
	var d := tmp + "/rec"
	var r1 := ApertureChatStore.append_message(d, "liam", "first")
	var r2 := ApertureChatStore.append_message(d, "liam", "second")
	# Lost chat.jsonl entirely → reads still serve both from the per-message copies.
	DirAccess.remove_absolute(d + "/chat.jsonl")
	var msgs := ApertureChatStore.read_messages(d)
	_check("lost chat.jsonl: both re-surface", msgs.size() == 2)
	# Torn/partial line + one surviving row → the torn row re-surfaces from its copy.
	var f := FileAccess.open(d + "/chat.jsonl", FileAccess.WRITE)
	f.store_string(JSON.stringify(r1) + "\n{\"id\": \"acm_torn")  # torn tail, no newline
	f.close()
	msgs = ApertureChatStore.read_messages(d)
	var ids := msgs.map(func(m): return m["id"])
	_check("torn line: reconciles to 2 rows", msgs.size() == 2 and ids.has(r2["id"]))


# ---------------------------------------------------------------- events fold
func _test_events_fold(tmp: String) -> void:
	var d := tmp + "/fold"
	var r := ApertureChatStore.append_message(d, "liam", "route me")
	var mid := String(r["id"])
	var f := FileAccess.open(d + "/events.jsonl", FileAccess.WRITE)
	f.store_string(JSON.stringify({"ts": "2026-07-03T00:00:00Z", "id": mid, "type": "label",
		"by": "s1", "to": "s1"}) + "\n")
	f.store_string(JSON.stringify({"ts": "2026-07-03T00:00:01Z", "id": mid, "type": "label",
		"by": "s1", "to": "s2"}) + "\n")  # reassign — last-label-wins
	f.store_string(JSON.stringify({"ts": "2026-07-03T00:00:02Z", "id": mid, "type": "read",
		"by": "s2"}) + "\n")
	f.close()
	var rows := ApertureChatStore.fold(d)
	_check("fold: 1 row", rows.size() == 1)
	_check("assigned_to last-label-wins", rows.size() == 1 and String(rows[0]["assigned_to"]) == "s2")
	_check("read_by union", rows.size() == 1 and (rows[0]["read_by"] as Array) == ["s2"])


# ---------------------------------------------------------------- scene_link parse
func _test_scene_link_parse() -> void:
	var p := ApertureSceneLauncher.parse({"scene": "examples/painterly_scene.tscn",
		"mode": "3d", "params": {"seed": 7}})
	_check("dict form parses", bool(p.get("ok", false)))
	_check("scene normalized to res://",
		String(p.get("scene", "")) == "res://examples/painterly_scene.tscn")
	var url := "resonance://open?target=godot&scene=res%3A%2F%2Fexamples%2Fpainterly_scene.tscn" \
		+ "&mode=3d&params=%7B%22seed%22%3A7%7D"
	var q := ApertureSceneLauncher.parse(url)
	_check("resonance:// URL form parses", bool(q.get("ok", false)))
	_check("URL and dict agree on scene", String(q.get("scene", "")) == String(p.get("scene", "")))
	_check("URL params decode", bool(q.get("ok", false)) and int((q["params"] as Dictionary).get("seed", 0)) == 7)
	_check("webpage target is not a scene link",
		not bool(ApertureSceneLauncher.parse("resonance://open?target=webpage&link=x").get("ok", true)))
	# Round-trip: dict → resonance URL → parse ⇒ same scene+mode (web/Godot equivalence).
	var back := ApertureSceneLauncher.parse(ApertureSceneLauncher.to_resonance_url(p))
	_check("to_resonance_url round-trips", bool(back.get("ok", false))
		and String(back["scene"]) == String(p["scene"]) and String(back["mode"]) == "3d")


func _test_scene_link_safety() -> void:
	_check("reject traversal", ApertureSceneLauncher.clean_scene("res://../../evil.tscn") == "")
	_check("reject drive letter", ApertureSceneLauncher.clean_scene("C:/evil.tscn") == "")
	_check("reject whitespace", ApertureSceneLauncher.clean_scene("a b.tscn") == "")
	_check("reject non-scene ext", ApertureSceneLauncher.clean_scene("run.exe") == "")
	_check("accept bare relative", ApertureSceneLauncher.clean_scene("a/b.tscn") == "res://a/b.tscn")
	_check("backslashes normalized", ApertureSceneLauncher.clean_scene("a\\b.scn") == "res://a/b.scn")


func _test_scene_link_argv() -> void:
	var args := ApertureSceneLauncher.build_args({"scene": "res://examples/painterly_scene.tscn",
		"project_path": "G:/Wavelet/repos/Resonance-Evolution/godot", "mode": "3d",
		"params": {"seed": 7}})
	var want := PackedStringArray(["--path", "G:/Wavelet/repos/Resonance-Evolution/godot",
		"res://examples/painterly_scene.tscn", "--", "--mode=3d", "--scene-params={\"seed\":7}"])
	_check("argv exact (project+mode+params)", args == want)
	var plain := ApertureSceneLauncher.build_args({"scene": "aperture/aperture_board.tscn"})
	_check("argv defaults to THIS project", plain.size() == 3 and plain[0] == "--path"
		and plain[2] == "res://aperture/aperture_board.tscn"
		and plain[1] == ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/"))
	_check("bad link → empty argv", ApertureSceneLauncher.build_args({"scene": "nope.exe"}).is_empty())


# ---------------------------------------------------------------- live spawn (opt-in)
func _test_live_spawn() -> void:
	var pid := ApertureSceneLauncher.launch({"scene": "res://examples/painterly_scene.tscn",
		"mode": "3d"})
	_check("live: spawn returns pid", pid > 0)
	OS.delay_msec(2500)
	var running := OS.is_process_running(pid)
	_check("live: separate window process is running", running)
	if running:
		OS.kill(pid)


func _cleanup(tmp: String) -> void:
	# Best-effort recursive remove of the temp channel (never fails the test).
	var da := DirAccess.open(tmp)
	if da == null:
		return
	for sub in da.get_directories():
		var sd := tmp + "/" + sub
		var sda := DirAccess.open(sd)
		if sda == null:
			continue
		for inner in sda.get_directories():
			var idir := sd + "/" + inner
			var ida := DirAccess.open(idir)
			if ida != null:
				for fn in ida.get_files():
					DirAccess.remove_absolute(idir + "/" + fn)
			DirAccess.remove_absolute(idir)
		for fn in sda.get_files():
			DirAccess.remove_absolute(sd + "/" + fn)
		DirAccess.remove_absolute(sd)
	DirAccess.remove_absolute(tmp)
