extends SceneTree
## FRAME CAPTURE + LIVE-AUDIO PROBE for the item-10 visi-sonor demo (Wave 4). Run with a REAL display +
## audio driver (NOT --headless) so the analyzer produces real magnitudes and the viewport actually renders:
##
##   <godot_gui.exe> --path godot -s res://capture_visisonor_frame.gd
##
## It (1) builds the DemoInteractions controller (room + lights + screen + audio chain), (2) plays the
## bundled mp3 on the VisiSonor analyzer bus, (3) drives the light show while the mp3 sweeps bass->mid->treble,
## (4) prints the LIVE analyzer bands (proof the real mp3->analyzer->bands path is non-zero), and
## (5) saves SEVERAL proof frames to godot/artifacts/:
##      visisonor_demo_wide.png    — a wide shot of the whole room light show (from the back of the room).
##      visisonor_demo_screen.png  — a shot facing the TV/screen so the spectrum bars are clearly visible.
##      visisonor_demo_t0/_t1/_t2  — the WIDE shot at ~0s (bass/warm), ~4s (mid), ~8s (treble/cool), so the
##                                   colors visibly DIFFER across the sweep.
##      visisonor_demo_frame.png   — overwritten with the good wide shot (the legacy name the PR referenced).
## Then quits. Uses its OWN capture Camera3D (made current) so framing is deterministic, not the room's.

const DemoScript := preload("res://aperture/demo_interactions.gd")
const PrimSpectrumBandsRef := preload("res://primitives/prim_spectrum_bands.gd")

# Wide-shot camera: stand at the back of the 8x8 room, eye height, looking toward the fixtures + far wall.
const WIDE_POS := Vector3(0.0, 2.2, 6.6)
const WIDE_LOOK := Vector3(0.0, 1.6, -3.0)
# Screen-facing camera: closer, centered on the screen quad at (0,1.7,-3.9), looking straight at it.
const SCREEN_POS := Vector3(0.0, 1.7, 0.5)
const SCREEN_LOOK := Vector3(0.0, 1.7, -3.9)

var _demo = null
var _cam: Camera3D = null
var _frames := 0
var _shots: Array = []     # queue of { at_frame, name, pos, look }
var _did_probe := false

func _initialize() -> void:
	_demo = DemoScript.new()
	get_root().add_child(_demo)
	# Our own capture camera, made current so IT frames the shot (not the room's first-person camera).
	_cam = Camera3D.new()
	_cam.name = "CaptureCam"
	_cam.fov = 68.0
	_cam.near = 0.05
	_cam.far = 100.0
	get_root().add_child(_cam)
	_aim(WIDE_POS, WIDE_LOOK)
	_cam.make_current()
	# Schedule the timed shots. The mp3 sweeps bass->treble over ~8s; at ~60fps a frame is ~1/60s, but the
	# analyzer needs ~1s to fill, so the t-shots are spread across the render loop by frame count. We give
	# generous spacing so the live sweep (when the audio driver is present) clearly changes the colors.
	_shots = [
		{ "at": 70,  "name": "wide",   "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "at": 80,  "name": "t0",     "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "at": 320, "name": "t1",     "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "at": 560, "name": "t2",     "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "at": 600, "name": "screen", "pos": SCREEN_POS, "look": SCREEN_LOOK },
	]

func _process(_dt: float) -> bool:
	_frames += 1
	# Drive the demo each frame so the lights + screen react to the playing mp3. A steady dt so the synthetic
	# fallback (if the audio driver is absent) still sweeps its kick+sweep across the same frame budget.
	if _demo != null and is_instance_valid(_demo) and _demo.room != null:
		_demo.drive_once(Vector3(0, 1.7, 8), 0.033)
	# Probe the live bands once, early enough that the analyzer has filled.
	if _frames == 65 and not _did_probe:
		_probe_live_bands()
		_did_probe = true
	# Fire each scheduled shot at its frame.
	for shot in _shots:
		if int(shot["at"]) == _frames:
			_aim(shot["pos"], shot["look"])
			# One extra frame settle so the re-aimed camera renders before grab: defer the grab by returning
			# and grabbing next tick would complicate the loop; instead aim, then grab the CURRENT frame (the
			# camera transform is applied before the viewport draws this tick in the SceneTree main loop).
			_grab_named(str(shot["name"]))
	if _frames >= 620:
		# Overwrite the legacy single-frame name with the good wide shot for back-compat with the PR text.
		_aim(WIDE_POS, WIDE_LOOK)
		_grab_named("frame")
		quit(0)
	return false

func _aim(pos: Vector3, look: Vector3) -> void:
	if _cam == null or not is_instance_valid(_cam):
		return
	_cam.position = pos
	if not pos.is_equal_approx(look):
		_cam.look_at(look, Vector3.UP)

## Read the LIVE analyzer bands straight off the VisiSonor bus (the real mp3 is playing) and print them,
## so a reviewer sees the real path produced non-zero energy — the evidence the task asks for.
func _probe_live_bands() -> void:
	var spec: Node = PrimSpectrum.new()
	get_root().add_child(spec)
	spec.params = { "bus": "VisiSonor", "effect_index": 0, "n_bands": 16, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.0, "gain": 4.0 }
	var raw = spec.evaluate({}).get("bands")
	var mx := 0.0
	var sm := 0.0
	if raw is PackedFloat32Array or raw is Array:
		for x in raw:
			mx = maxf(mx, float(x))
			sm += float(x)
	var nb: Node = PrimSpectrumBandsRef.new()
	get_root().add_child(nb)
	nb.params = { "band_edges_hz": [20.0, 60.0, 250.0, 500.0, 2000.0, 6000.0, 20000.0], "min_hz": 20.0, "max_hz": 20000.0 }
	var named: Dictionary = nb.evaluate({ "bands": raw }).get("named", {})
	print("LIVE_BANDS audio_live=%s max_raw=%.4f sum_raw=%.4f low=%.4f mid=%.4f high=%.4f" % [
		str(_demo.audio_is_live()), mx, sm,
		float(named.get("low", 0.0)), float(named.get("mid", 0.0)), float(named.get("high", 0.0))])
	if mx > 0.0001:
		print("LIVE_PATH: NON-ZERO analyzer bands from the real mp3 -> the live path is proven.")
	else:
		print("LIVE_PATH: analyzer read ~zero (no real audio driver / clip silent this frame).")
	spec.free()
	nb.free()

## Save the current rendered viewport to godot/artifacts/visisonor_demo_<name>.png (visual proof).
func _grab_named(name: String) -> void:
	var vp := get_root()
	var img := vp.get_texture().get_image()
	if img == null:
		print("CAPTURE[%s]: viewport image was null (no render target)." % name)
		return
	var dir := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("visisonor_demo_%s.png" % name)
	var e := img.save_png(path)
	if e == OK:
		var st := PrimVideoSource.image_stats(img)
		print("CAPTURE[%s]: wrote %s (%dx%d, variance=%.5f)" % [name, path, img.get_width(), img.get_height(), float(st.get("variance", 0.0))])
	else:
		print("CAPTURE[%s]: save_png failed err=%d" % [name, e])
