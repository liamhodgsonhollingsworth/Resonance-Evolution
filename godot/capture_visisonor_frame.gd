extends SceneTree
## FRAME CAPTURE + LIVE-AUDIO PROBE for the item-10 visi-sonor demo (Wave 4). Run with a REAL display +
## audio driver (NOT --headless) so the analyzer produces real magnitudes and the viewport actually renders:
##
##   <godot_gui.exe> --path godot -s res://capture_visisonor_frame.gd
##
## It (1) builds the DemoInteractions controller (room + lights + screen + audio chain), (2) plays the
## bundled mp3 on the VisiSonor analyzer bus, (3) waits several frames for the analyzer to fill + the lights
## to react, (4) prints the LIVE analyzer bands (proof the real mp3->analyzer->bands path is non-zero), and
## (5) saves the rendered viewport to godot/artifacts/visisonor_demo_frame.png. Then quits.

const DemoScript := preload("res://aperture/demo_interactions.gd")
const PrimSpectrumBandsRef := preload("res://primitives/prim_spectrum_bands.gd")

var _demo = null
var _frames := 0

func _initialize() -> void:
	_demo = DemoScript.new()
	get_root().add_child(_demo)

func _process(_dt: float) -> bool:
	_frames += 1
	# Drive the demo each frame so the lights + screen react to the playing mp3.
	if _demo != null and is_instance_valid(_demo) and _demo.room != null:
		_demo.drive_once(Vector3(0, 1.7, 8), 0.05)
	# Give the analyzer + renderer ~90 frames (~1.5s at the default cap) to fill + settle, then probe+grab.
	if _frames == 90:
		_probe_live_bands()
		_grab_frame()
		quit(0)
	return false

## Read the LIVE analyzer bands straight off the VisiSonor bus (the real mp3 is playing) and print them,
## so a reviewer sees the real path produced non-zero energy — the evidence the task asks for.
func _probe_live_bands() -> void:
	var spec := PrimSpectrum.new()
	get_root().add_child(spec)
	spec.params = { "bus": "VisiSonor", "effect_index": 0, "n_bands": 16, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.0, "gain": 4.0 }
	var raw = spec.evaluate({}).get("bands")
	var mx := 0.0
	var sm := 0.0
	if raw is PackedFloat32Array or raw is Array:
		for x in raw:
			mx = maxf(mx, float(x))
			sm += float(x)
	var nb := PrimSpectrumBandsRef.new()
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

## Save the rendered viewport to the artifacts PNG (visual proof the room+lights+screen render).
func _grab_frame() -> void:
	var vp := get_root()
	var img := vp.get_texture().get_image()
	if img == null:
		print("CAPTURE: viewport image was null (no render target).")
		return
	var dir := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("visisonor_demo_frame.png")
	var e := img.save_png(path)
	if e == OK:
		var st := PrimVideoSource.image_stats(img)
		print("CAPTURE: wrote %s (%dx%d, variance=%.5f)" % [path, img.get_width(), img.get_height(), float(st.get("variance", 0.0))])
	else:
		print("CAPTURE: save_png failed err=%d" % e)
