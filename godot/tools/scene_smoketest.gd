extends SceneTree
## SCENE SMOKETEST — the GENERAL, reusable "does this scene actually RENDER on a real launch?" gate.
##
## This is the tool that would have caught the visi-sonor grey screen (#049 recurrence, 2026-07-08):
## the demo was "verified" by a BESPOKE capture harness that `preload`ed the script + used its OWN
## camera, and by headless tests that rebuilt the class cache first — so NEITHER exercised the real
## `.tscn` a fresh double-click launches on a cold class cache. This tool does exactly that, for ANY
## scene, so future render-verification REUSES it instead of writing a new one-off (Liam 2026-07-08:
## "creating composable and generalizable tools ... such that future instances of testing would
## re-use those tools rather than making new ones").
##
## WHAT MAKES IT FAITHFUL (the three things the bespoke harness got wrong):
##   1. Loads the REAL scene via `load(path).instantiate()` — the exact scene-instantiate + root-script
##      PARSE path a launch runs. If the root script fails to parse (the grey-screen bug), `_ready`
##      never fires and the scene builds NOTHING → detected here as child_count == 0.
##   2. Uses the SCENE'S OWN camera (adds no camera of its own). If the scene fails to set up, the
##      frame is genuinely what the user sees, not a harness-framed illusion.
##   3. Runs under a REAL GL context (launch with the GUI/windowed Godot exe, NOT --headless — headless
##      uses the dummy driver and get_image() returns blank). The Python wrapper CLEARS the class
##      cache first so the launch is COLD (faithful to a fresh checkout).
##
## It then AUTO-ANALYZES the captured frame for the failure modes we keep hitting — a flat/blank frame
## (grey default viewport = the grey screen), a blown-out near-white frame (the two-competing-bright-
## WorldEnvironments bug), and an all-black dead frame — and emits a machine-readable verdict.
##
## CALL (via the GUI exe, real GL — the Python wrapper `scene_smoketest.py` does this for you):
##   <godot_gui.exe> --path godot -s res://tools/scene_smoketest.gd -- \
##       --scene res://demo_interactions.tscn --out res://artifacts/smoke.png \
##       --json res://artifacts/smoke.json --settle 90
##
## OUTPUT: writes the PNG + a JSON verdict, prints one machine line `SMOKETEST_JSON:<json>` (grep it),
## a human-readable copy, and a `SMOKETEST: PASS` / `SMOKETEST: FAIL <reasons>` sentinel. quit(0) on
## PASS, quit(1) on FAIL — but judge by the sentinel, not only the code (a Godot crash also non-zeros).

var _scene_path := ""
var _out_png := "res://artifacts/smoketest.png"
var _out_json := "res://artifacts/smoketest.json"
var _settle := 90          # frames to wait before capture (~1.5s at 60fps) so deferred loads + lights settle
var _drive_method := ""    # optional: a no-arg-ish method on the root to pump each frame (audio-reactive scenes)

var _root_inst: Node = null
var _instantiate_ok := true
var _frames := 0
var _load_error := ""

func _initialize() -> void:
	_parse_args()
	if _scene_path == "":
		_emit_fail(["no --scene given"], {})
		quit(1)
		return
	var packed = load(_scene_path)
	if packed == null:
		_load_error = "load('%s') returned null (missing scene or a hard parse error at load time)" % _scene_path
		_emit_fail([_load_error], {})
		quit(1)
		return
	# instantiate() can still succeed with a NULL root script when the script has a parse error — that is
	# precisely the grey-screen shape, which we then catch via child_count == 0 after settle.
	_root_inst = packed.instantiate()
	if _root_inst == null:
		_load_error = "instantiate() returned null for '%s'" % _scene_path
		_emit_fail([_load_error], {})
		quit(1)
		return
	get_root().add_child(_root_inst)

func _process(_dt: float) -> bool:
	_frames += 1
	if _drive_method != "" and _root_inst != null and is_instance_valid(_root_inst) and _root_inst.has_method(_drive_method):
		# best-effort pump; ignore signature mismatch (a scene that needs args just won't be driven).
		if _root_inst.has_method(_drive_method):
			_root_inst.callv(_drive_method, [])
	if _frames >= _settle:
		_capture_and_verdict()
		quit(_last_code)
		return true
	return false

var _last_code := 0

func _capture_and_verdict() -> void:
	var vp := get_root()
	var img: Image = null
	var tex := vp.get_texture()
	if tex != null:
		img = tex.get_image()
	var stats := {}
	var reasons: Array = []

	# --- pixel health signals (computed FIRST — the frame is the ground truth of what rendered) ---
	var frame_has_content := false     # the frame shows real variety (not the flat grey/blank default)
	if img == null:
		reasons.append("no viewport image (are you running with a real GL context, i.e. the GUI exe not --headless?)")
	else:
		stats = _analyze(img)
		var mean := float(stats["lum_mean"])
		var std := float(stats["lum_std"])
		var uniq := int(stats["unique_colors"])
		# FLAT/BLANK: near-uniform single color → the grey default viewport (or flat black/white).
		var is_flat := std < 0.02 and uniq <= 3
		frame_has_content = not is_flat
		if is_flat:
			reasons.append("FLAT frame (lum_std=%.4f, unique_colors=%d) — a blank/grey screen, nothing rendered" % [std, uniq])
		# BLOWN-OUT: near-white wash (the two-competing-WorldEnvironments over-exposure bug).
		if mean > 0.95:
			reasons.append("BLOWN-OUT frame (lum_mean=%.3f) — over-exposed near-white" % mean)
		# DEAD-BLACK: mean≈0 AND almost no color variety → nothing lit (a live dark light-show has many colors).
		if mean < 0.005 and uniq <= 2:
			reasons.append("DEAD frame (lum_mean=%.4f, unique_colors=%d) — nothing rendered/lit" % [mean, uniq])
		# save proof
		var dir := _out_png.get_base_dir()
		if dir != "" and not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		img.save_png(_out_png)

	# --- structural signals ---
	var child_count := 0
	var descendant_count := 0
	var has_current_camera := false
	var root_has_script := false
	if _root_inst != null and is_instance_valid(_root_inst):
		child_count = _root_inst.get_child_count()
		descendant_count = _count_descendants(_root_inst)
		root_has_script = _root_inst.get_script() != null
	has_current_camera = _find_current_camera(get_root()) != null

	# A scene whose root script failed to parse never runs _ready → builds nothing AND shows the flat
	# grey default viewport. Fire "built NOTHING" ONLY when the frame ALSO lacks content: an immediate-
	# mode 2D scene (a Node2D rendering via _draw(), e.g. examples/wfc_demo) legitimately has 0
	# descendants yet paints a full, varied frame — that is NOT a parse failure and must not be flagged.
	# A real grey screen is flat AND has 0 descendants, so it is still caught (by both this and FLAT).
	if descendant_count == 0 and not frame_has_content:
		reasons.append("scene built NOTHING (0 descendants) and the frame has no content — root script likely failed to parse (grey-screen shape)")

	var verdict := {
		"scene": _scene_path,
		"pass": reasons.is_empty(),
		"reasons": reasons,
		"frame_png": _out_png,
		"structural": {
			"root_has_script": root_has_script,
			"child_count": child_count,
			"descendant_count": descendant_count,
			"has_current_camera": has_current_camera,
		},
		"pixels": stats,
		"settle_frames": _settle,
	}
	_write_json(verdict)
	_print_verdict(verdict)
	_last_code = 0 if reasons.is_empty() else 1

## Downsample to 64x64 then compute luminance mean/std + a quantized unique-color count. Downsampling
## makes the check fast AND robust to sub-pixel noise; the quantization (5 bits/channel) distinguishes a
## genuinely lit scene (many buckets) from a flat clear-color (1-2 buckets).
func _analyze(src: Image) -> Dictionary:
	var img := src.duplicate() as Image
	if img.get_format() != Image.FORMAT_RGBA8 and img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGBA8)
	img.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	var n := 64 * 64
	var lum_sum := 0.0
	var lum_sq := 0.0
	var lo := 1.0
	var hi := 0.0
	var colors := {}
	for y in 64:
		for x in 64:
			var c := img.get_pixel(x, y)
			var l := c.get_luminance()
			lum_sum += l
			lum_sq += l * l
			lo = min(lo, l)
			hi = max(hi, l)
			var key := (int(c.r * 31.0) << 10) | (int(c.g * 31.0) << 5) | int(c.b * 31.0)
			colors[key] = true
	var mean := lum_sum / n
	var variance: float = max(0.0, lum_sq / n - mean * mean)
	return {
		"lum_mean": snappedf(mean, 0.0001),
		"lum_std": snappedf(sqrt(variance), 0.0001),
		"lum_min": snappedf(lo, 0.0001),
		"lum_max": snappedf(hi, 0.0001),
		"unique_colors": colors.size(),
	}

func _count_descendants(n: Node) -> int:
	var total := 0
	for c in n.get_children():
		total += 1 + _count_descendants(c)
	return total

func _find_current_camera(n: Node) -> Camera3D:
	if n is Camera3D and (n as Camera3D).current:
		return n as Camera3D
	for c in n.get_children():
		var found := _find_current_camera(c)
		if found != null:
			return found
	return null

func _write_json(verdict: Dictionary) -> void:
	var f := FileAccess.open(_out_json, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(verdict, "  "))
		f.close()

func _print_verdict(verdict: Dictionary) -> void:
	print("SMOKETEST_JSON:", JSON.stringify(verdict))
	print("---- scene smoketest ----")
	print("  scene: ", verdict["scene"])
	print("  structural: ", verdict["structural"])
	print("  pixels: ", verdict["pixels"])
	if verdict["pass"]:
		print("SMOKETEST: PASS")
	else:
		print("SMOKETEST: FAIL  ", verdict["reasons"])

func _emit_fail(reasons: Array, stats: Dictionary) -> void:
	var verdict := {"scene": _scene_path, "pass": false, "reasons": reasons, "pixels": stats}
	_write_json(verdict)
	_print_verdict(verdict)

func _parse_args() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a := argv[i]
		match a:
			"--scene":
				i += 1
				if i < argv.size(): _scene_path = argv[i]
			"--out":
				i += 1
				if i < argv.size(): _out_png = argv[i]
			"--json":
				i += 1
				if i < argv.size(): _out_json = argv[i]
			"--settle":
				i += 1
				if i < argv.size(): _settle = int(argv[i])
			"--drive-method":
				i += 1
				if i < argv.size(): _drive_method = argv[i]
		i += 1
