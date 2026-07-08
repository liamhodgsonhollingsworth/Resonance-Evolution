extends SceneTree
## FRAME CAPTURE + LIVE-AUDIO PROBE for the item-10 visi-sonor demo (Wave 4). Run with a REAL display +
## audio driver (NOT --headless) so the analyzer produces real magnitudes and the viewport actually renders:
##
##   <godot_gui.exe> --path godot -s res://capture_visisonor_frame.gd
##
## It builds the DemoInteractions controller (room + lights + screen + audio chain), plays the bundled mp3
## on the VisiSonor analyzer bus, drives the light show while the mp3 sweeps bass->mid->treble, prints the
## LIVE analyzer bands (proof the real mp3->analyzer->bands path is non-zero), and saves proof frames to
## godot/artifacts/:
##   visisonor_demo_wide.png    — a wide shot of the whole room light show.
##   visisonor_demo_screen.png  — a shot facing the TV/screen so the spectrum bars are clearly visible.
##   visisonor_demo_t0/_t1/_t2  — the WIDE shot at ~0s (bass/warm), ~4s (mid), ~8s (treble/cool).
##   visisonor_demo_frame.png   — overwritten with the good wide shot (the legacy name the PR referenced).
##
## Uses its OWN capture Camera3D (made current) so framing is deterministic. CRITICAL: in a SceneTree the
## viewport image reflects the frame drawn BEFORE this tick, so we AIM on one tick and GRAB on the NEXT —
## a two-phase (aim, settle, grab) schedule so each shot captures its own camera + audio moment.

const DemoScript := preload("res://aperture/demo_interactions.gd")
const PrimSpectrumBandsRef := preload("res://primitives/prim_spectrum_bands.gd")

# Wide-shot camera: stand near the back wall INSIDE the 8x8 room (z in -4..4), eye height, looking at the
# fixtures + screen wall. Screen-facing camera: centered on the screen quad at (0,1.7,-3.9), close on it.
const WIDE_POS := Vector3(0.0, 2.4, 3.4)
const WIDE_LOOK := Vector3(0.0, 1.5, -3.2)
const SCREEN_POS := Vector3(0.0, 1.7, -1.2)
const SCREEN_LOOK := Vector3(0.0, 1.7, -3.9)

var _demo = null
var _cam: Camera3D = null
var _frames := 0
var _did_probe := false
# Each shot: aim at `aim_at`, wait `settle` ticks, then grab as `name`. Scheduled by absolute frame number.
# Spread across the mp3 sweep (bass early -> treble late) so t0/t1/t2 clearly differ in color.
var _schedule: Array = []
var _sidx := 0

func _initialize() -> void:
	_demo = DemoScript.new()
	get_root().add_child(_demo)
	_cam = Camera3D.new()
	_cam.name = "CaptureCam"
	_cam.fov = 70.0
	_cam.near = 0.05
	_cam.far = 100.0
	get_root().add_child(_cam)
	# look_at_from_position works whether or not the node is settled in the tree (unlike look_at).
	_cam.look_at_from_position(WIDE_POS, WIDE_LOOK, Vector3.UP)
	_cam.make_current()
	# (aim_frame, grab_frame, name, pos, look). grab_frame > aim_frame so the re-aimed camera is drawn first.
	_schedule = [
		{ "aim": 68,  "grab": 72,  "name": "wide",   "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "aim": 78,  "grab": 82,  "name": "t0",     "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "aim": 300, "grab": 304, "name": "t1",     "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "aim": 540, "grab": 544, "name": "t2",     "pos": WIDE_POS,   "look": WIDE_LOOK },
		{ "aim": 580, "grab": 590, "name": "screen", "pos": SCREEN_POS, "look": SCREEN_LOOK },
		{ "aim": 596, "grab": 600, "name": "frame",  "pos": WIDE_POS,   "look": WIDE_LOOK },
	]

func _process(_dt: float) -> bool:
	_frames += 1
	if _demo != null and is_instance_valid(_demo) and _demo.room != null:
		_demo.drive_once(Vector3(0, 1.7, 8), 0.033)
	if _frames == 60 and not _did_probe:
		_probe_live_bands()
		_did_probe = true
	for shot in _schedule:
		if int(shot["aim"]) == _frames:
			_cam.look_at_from_position(shot["pos"], shot["look"], Vector3.UP)
			_cam.make_current()
		if int(shot["grab"]) == _frames:
			_grab_named(str(shot["name"]))
	if _frames >= 610:
		quit(0)
	return false

## Read the LIVE analyzer bands off the VisiSonor bus and print them — evidence the real path is non-zero.
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

## Save the current rendered viewport to godot/artifacts/visisonor_demo_<name>.png. Also prints the screen
## quad's texture presence + a small screen-region average so a reviewer can see the bars are non-black.
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
