extends SceneTree
## REAL-TREE #049 TEST for the SCREEN/VIDEO node slice (Visi-sonor Wave 1D, item 10 core).
## Drives the ACTUAL registered primitives (Screen, VideoSource) through a REAL GraphRuntime via
## load_arrangement() + set_input_frame() + evaluate() — the SAME runtime a mounted GraphPanel
## hot-loads an arrangement into. A standalone `PrimScreen.new().evaluate()` would be a FALSE PASS
## (the #049 trap): the behaviour must be proven in the runtime the user actually drives, through
## the registry, over real wires.
##
##   <godot> --headless --path godot -s res://headless_screen_test.gd
##
## What it proves:
##  (a) NON-BLANK SCREEN — the Screen quad's albedo texture is a real on-disk PNG whose pixel
##      VARIANCE > 0 (a blank/solid texture has variance 0). Proven for BOTH sources: a music_video
##      screen fed by a VideoSource frame, and a classic_viz screen (audio-driven / synthetic).
##  (b) PLAYHEAD ADVANCE + EXTERNAL SYNC — a VideoSource advances its own playhead across successive
##      evaluate()s (frame_index increases), AND when an external playhead_seconds is wired in, the
##      emitted frame SNAPS to that value (video stays in step with the mp3 playhead — item 10 sync).
##  (c) CLASSIC_VIZ FALLBACK, NO MEDIA (C-ideal) — with source=classic_viz and NO media file present,
##      the Screen still renders a non-blank frame and does NOT crash. Same for a VideoSource pointed
##      at an absent path: it emits a synthetic animated test pattern, present=false, no crash.
##  (d) TEXT-EQUIVALENCE (T) — the outputs are plain DATA dicts on wires (image PATHS + stats), no
##      Godot Image/Texture object on the wire; any downstream node can subscribe.
##  (e) CONNECTION-ISOLATED-FAILURE (C) — an unknown source_kind on VideoSource is a declared no-op
##      (synthetic pattern, present=false), never a crash; severing the video_frame wire leaves the
##      Screen on its own fallback rather than erroring.

var _fail := 0

func _check(name: String, cond: bool) -> void:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1

func _initialize() -> void:
	_run()

func _variance_of_png(path: String) -> float:
	# Load the emitted PNG and compute luma variance across pixels. variance > 0 <=> non-blank.
	if not FileAccess.file_exists(path):
		return -1.0
	var img := Image.load_from_file(path)
	if img == null or img.get_width() == 0 or img.get_height() == 0:
		return -1.0
	var w := img.get_width()
	var h := img.get_height()
	var n := 0
	var sum := 0.0
	var sumsq := 0.0
	# Sample a grid (cap the work on large frames).
	var step_x: int = maxi(1, w / 32)
	var step_y: int = maxi(1, h / 32)
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := img.get_pixel(x, y)
			var luma := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			sum += luma
			sumsq += luma * luma
			n += 1
			x += step_x
		y += step_y
	if n == 0:
		return -1.0
	var mean := sum / float(n)
	return (sumsq / float(n)) - (mean * mean)

func _run() -> void:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	_check("GraphRuntime built (the real runtime a mounted panel hot-loads into)", rt != null and rt.is_inside_tree())

	# --- (a1) MUSIC_VIDEO screen fed by a VideoSource frame renders a NON-BLANK texture -------------
	# VideoSource (synthetic animated pattern, no real file) -> Screen(source=music_video). The screen
	# quad's albedo texture is the VideoSource's current frame; assert its variance > 0.
	var mv := {
		"format": "resonance.arrangement/v1", "name": "screen_music_video",
		"nodes": [
			{ "id": "vid", "type": "VideoSource", "params": {
				"source_kind": "video", "path": "", "width": 64, "height": 48, "fps": 30.0 } },
			{ "id": "scr", "type": "Screen", "params": {
				"source": "music_video", "size": [1.6, 0.9] } },
		],
		"wires": [
			{ "from": "vid", "out": "video_frame", "to": "scr", "in": "video_frame" },
		],
	}
	rt.load_arrangement(mv)
	_check("music_video arrangement loaded (VideoSource + Screen live)", rt.nodes.size() == 2)
	var out_mv := rt.evaluate()
	var frame_mv: Dictionary = out_mv.get("vid", {}).get("video_frame", {})
	var screen_mv: Dictionary = out_mv.get("scr", {}).get("screen", {})
	_check("VideoSource emitted a video_frame descriptor with an image_path",
		String(frame_mv.get("kind")) == "video_frame" and FileAccess.file_exists(String(frame_mv.get("image_path", ""))))
	_check("Screen emitted a screen descriptor (quad + material.albedo_texture)",
		String(screen_mv.get("kind")) == "screen" and String(screen_mv.get("mesh")) == "quad"
		and String(screen_mv.get("material", {}).get("albedo_texture", "")) != "")
	var tex_path_mv := String(screen_mv.get("texture", {}).get("image_path", ""))
	var var_mv := _variance_of_png(tex_path_mv)
	_check("(a) music_video: the Screen quad renders a NON-BLANK texture (pixel variance > 0)", var_mv > 0.0)

	# --- (d) TEXT-EQUIVALENCE: outputs are plain DATA (paths + stats), no Godot object on the wire ---
	_check("(T) video_frame is plain DATA (image PATH string, not a Godot Image/Texture)",
		typeof(frame_mv.get("image_path")) == TYPE_STRING and not (frame_mv.get("image_path") is Object))
	_check("(T) screen material.albedo_texture is a res://user:// PATH string (renderer-neutral)",
		typeof(screen_mv.get("material", {}).get("albedo_texture")) == TYPE_STRING)

	# --- (b) PLAYHEAD ADVANCE across successive evaluate()s (self-driven, no external wire) ----------
	# The VideoSource above has no external playhead wire, so it advances its own playhead 1/fps per
	# evaluate. Evaluate a few times and assert frame_index strictly increases and playhead grows.
	var f0 := int(out_mv.get("vid", {}).get("video_frame", {}).get("frame_index", -1))
	var p0 := float(out_mv.get("vid", {}).get("video_frame", {}).get("playhead_seconds", -1.0))
	rt.evaluate()
	var out_adv := rt.evaluate()
	var f1 := int(out_adv.get("vid", {}).get("video_frame", {}).get("frame_index", -1))
	var p1 := float(out_adv.get("vid", {}).get("video_frame", {}).get("playhead_seconds", -1.0))
	_check("(b) VideoSource playhead ADVANCES self-driven (frame_index grows across evaluate()s)", f1 > f0)
	_check("(b) VideoSource playhead_seconds grows with self-driven advance", p1 > p0)

	# --- (b) EXTERNAL SYNC: wire an explicit playhead_seconds; the frame SNAPS to it -----------------
	# item-10 sync: the video playhead follows the mp3's playhead_seconds. Wire a Const playhead of
	# 2.0s at fps 30 -> expect frame_index == round(2.0*30) == 60 and playhead == 2.0 exactly.
	var sync := {
		"format": "resonance.arrangement/v1", "name": "screen_playhead_sync",
		"nodes": [
			{ "id": "ph", "type": "Const", "params": { "value": 2.0 } },
			{ "id": "vid", "type": "VideoSource", "params": {
				"source_kind": "video", "path": "", "width": 48, "height": 32, "fps": 30.0 } },
		],
		"wires": [
			{ "from": "ph", "out": "value", "to": "vid", "in": "playhead_seconds" },
		],
	}
	rt.load_arrangement(sync)
	var out_sync := rt.evaluate()
	var frame_sync: Dictionary = out_sync.get("vid", {}).get("video_frame", {})
	_check("(b) EXTERNAL SYNC: playhead SNAPS to the wired value (2.0s exactly)",
		abs(float(frame_sync.get("playhead_seconds", -1.0)) - 2.0) < 0.0001)
	_check("(b) EXTERNAL SYNC: frame_index tracks the synced playhead (round(2.0*30)=60)",
		int(frame_sync.get("frame_index", -1)) == 60)
	# A different external playhead re-syncs (proves it FOLLOWS, not just advances).
	sync["nodes"][0]["params"] = { "value": 0.5 }
	rt.load_arrangement(sync)
	var out_sync2 := rt.evaluate()
	_check("(b) EXTERNAL SYNC: a different mp3 playhead re-snaps the video (0.5s -> frame 15)",
		int(out_sync2.get("vid", {}).get("video_frame", {}).get("frame_index", -1)) == 15)

	# --- (c) CLASSIC_VIZ FALLBACK with NO media file: non-blank, no crash ----------------------------
	# source=classic_viz, an audio LEVEL injected via the frame seam; NO video wired, NO media file.
	# The Screen must still render a non-blank texture and not crash.
	var cv := {
		"format": "resonance.arrangement/v1", "name": "screen_classic_viz",
		"nodes": [
			{ "id": "scr", "type": "Screen", "params": {
				"source": "classic_viz", "size": [1.6, 0.9], "width": 64, "height": 48 } },
		],
		"wires": [],
	}
	rt.load_arrangement(cv)
	rt.set_input_frame({ "signal.band.low": 0.8, "signal.band.mid": 0.4, "signal.band.high": 0.2 })
	var out_cv := rt.evaluate()
	var screen_cv: Dictionary = out_cv.get("scr", {}).get("screen", {})
	_check("(c) classic_viz screen emitted a descriptor with NO media file + NO video wire (no crash)",
		String(screen_cv.get("kind")) == "screen" and String(screen_cv.get("source")) == "classic_viz")
	var var_cv := _variance_of_png(String(screen_cv.get("texture", {}).get("image_path", "")))
	_check("(c) classic_viz: renders a NON-BLANK texture with no media file (variance > 0)", var_cv > 0.0)
	# Advancing time animates the classic viz (a second evaluate yields a different frame path/content).
	rt.set_input_frame({ "signal.band.low": 0.1, "signal.band.mid": 0.9, "signal.band.high": 0.5 })
	var out_cv2 := rt.evaluate()
	var var_cv2 := _variance_of_png(String(out_cv2.get("scr", {}).get("screen", {}).get("texture", {}).get("image_path", "")))
	_check("(c) classic_viz stays non-blank as the audio level changes", var_cv2 > 0.0)

	# --- (e) CONNECTION-ISOLATED-FAILURE: unknown source_kind = declared no-op, never a crash --------
	var unk := {
		"format": "resonance.arrangement/v1", "name": "video_unknown_source",
		"nodes": [
			{ "id": "vid", "type": "VideoSource", "params": {
				"source_kind": "youtube", "path": "https://example/none", "width": 32, "height": 24, "fps": 24.0 } },
			{ "id": "scr", "type": "Screen", "params": { "source": "music_video", "size": [1.6, 0.9] } },
		],
		"wires": [
			{ "from": "vid", "out": "video_frame", "to": "scr", "in": "video_frame" },
		],
	}
	rt.load_arrangement(unk)
	var out_unk := rt.evaluate()
	var frame_unk: Dictionary = out_unk.get("vid", {}).get("video_frame", {})
	_check("(C) unknown source_kind (youtube) is a DECLARED NO-OP: present=false, no crash",
		frame_unk.has("present") and bool(frame_unk.get("present")) == false)
	_check("(C) the no-op VideoSource still emits a synthetic NON-BLANK frame (seam stays general)",
		_variance_of_png(String(frame_unk.get("image_path", ""))) > 0.0)
	var screen_unk: Dictionary = out_unk.get("scr", {}).get("screen", {})
	_check("(C) the Screen fed by a no-op source still renders (falls through cleanly, no crash)",
		String(screen_unk.get("kind")) == "screen"
		and _variance_of_png(String(screen_unk.get("texture", {}).get("image_path", ""))) > 0.0)
	# Sever the video_frame wire: a music_video Screen with NO video input must fall back, not crash.
	unk["wires"] = []
	rt.load_arrangement(unk)
	var out_cut := rt.evaluate()
	var screen_cut: Dictionary = out_cut.get("scr", {}).get("screen", {})
	_check("(C) severing the video wire leaves the Screen on its own fallback (renders, no crash)",
		String(screen_cut.get("kind")) == "screen"
		and _variance_of_png(String(screen_cut.get("texture", {}).get("image_path", ""))) > 0.0)

	rt.free()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)
