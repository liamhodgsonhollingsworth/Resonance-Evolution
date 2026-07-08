extends SceneTree
## HEADLESS SELF-TEST for the ITEM-10 VISI-SONOR DEMO (Wave 4 — the reportable integration gate).
##
##   <godot> --headless --path godot -s res://headless_visisonor_demo_test.gd
##
## Judge PASS by the sentinel "RESULT: ALL PASS" (NOT the exit code — Godot's is unreliable headless).
##
## It drives the REAL DemoInteractions controller (the one the desktop shortcut opens), which builds the
## Aperture3D room + mounts the AudioEffectSpectrumAnalyzer bus + loads demo_visisonor_room.json + wires
## every fixture, and asserts — via prim_compare_diff as the oracle — the four demo-critical properties:
##   (a) band values CHANGE when audio plays vs silence (the analyzer->bands path is live), AND the demo's
##       own compute_bands() changes over time (the running feed is not static).
##   (b) EACH fixture's device.set_led receipt RGB tracks its bound band (a bass frame vs a treble frame
##       produces different receipts on a bass-bound vs treble-bound fixture).
##   (c) prim_freq_to_color yields a WARM hue for a bass-dominant frame and a COOL hue for a treble frame.
##   (d) the prim_screen quad renders a NON-BLANK frame (image variance > 0).
##
## Headless has a DUMMY audio driver, so the LIVE analyzer produces no real magnitudes — the demo runs in
## its synthetic-fallback mode (prim_demo_audio_loop) for the running-feed assertions, and the analyzer->
## bands path is proven separately with prim_spectrum's SYNTHETIC magnitude provider (the exact seam a
## live room fills from the analyzer instance). So every assertion runs with zero live audio + zero hardware.

const DemoScript := preload("res://aperture/demo_interactions.gd")
const WorldActions := preload("res://runtime/world_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	await _test_analyzer_bands_change_with_audio()
	await _test_demo_builds_and_drives()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)


# --- (a) the analyzer->bands path: audio present -> non-zero bands, far from silence (CompareDiff oracle)
func _test_analyzer_bands_change_with_audio() -> void:
	var spec := PrimSpectrum.new()
	get_root().add_child(spec)
	spec.params = { "n_bands": 16, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.0, "normalize": true }
	# SILENCE
	spec.set_magnitude_provider(func(_a: float, _b: float) -> float: return 0.0)
	var silence := _plain(spec.evaluate({}).get("bands"))
	# AUDIO (energy in the low range)
	spec.set_magnitude_provider(func(from_hz: float, to_hz: float) -> float:
		var center := sqrt(maxf(1.0, from_hz) * maxf(1.0, to_hz))
		return 0.9 if center < 250.0 else 0.03)
	var audio := _plain(spec.evaluate({}).get("bands"))
	_check("(a) analyzer: audio present -> at least one strong band (>0.5)", _maxf(audio) > 0.5)
	_check("(a) analyzer: silence -> all bands ~0", _maxf(silence) < 0.001)
	var cmp := PrimCompareDiff.new()
	get_root().add_child(cmp)
	cmp.params = { "metric": "l2" }
	var d := float(cmp.evaluate({ "candidate": audio, "reference": silence }).get("d", 0.0))
	_check("(a) analyzer: bands CHANGE with audio vs silence (l2 > 0.3, CompareDiff oracle)", d > 0.3)
	cmp.free()
	spec.free()


# --- (b)(c)(d): build the REAL demo controller and assert the running light show ---------------------
func _test_demo_builds_and_drives() -> void:
	# Clean host-wide device.* baseline so the demo's own boot is what registers the ops.
	DeviceActions.unregister_device_ops_host()
	var demo = DemoScript.new()
	get_root().add_child(demo)
	await process_frame
	await process_frame
	_check("demo controller built the Aperture3D room + visi-sonor layer",
		demo.room != null and is_instance_valid(demo.room))

	# The demo runs in synthetic-fallback mode headless (dummy audio driver). Drive it several frames so
	# the synthetic loop advances (kick + sweep), then confirm compute_bands() is a LIVE, changing feed.
	var b0: Dictionary = demo.compute_bands(0.10)
	demo.drive_visisonor(b0)
	for i in range(30):
		demo.drive_once(Vector3(0, 1.7, 8), 0.10)
	var b1: Dictionary = demo.compute_bands(0.10)
	_check("(a) demo feed: compute_bands returns the signal.band.* seam keys",
		b1.has("signal.band.low") and b1.has("signal.band.mid") and b1.has("signal.band.high"))
	# The running feed changes over time (not a static frame): compare two frames far apart in the loop.
	var cmp := PrimCompareDiff.new()
	get_root().add_child(cmp)
	cmp.params = { "metric": "l2" }
	var feed_d := float(cmp.evaluate({
		"candidate": [float(b0.get("signal.band.low")), float(b0.get("signal.band.mid")), float(b0.get("signal.band.high"))],
		"reference": [float(b1.get("signal.band.low")), float(b1.get("signal.band.mid")), float(b1.get("signal.band.high"))],
	}).get("d", 0.0))
	_check("(a) demo feed: the running band feed CHANGES over time (l2 > 0, not static)", feed_d > 0.0)

	# --- (b) each fixture's device.set_led receipt RGB tracks its bound band -------------------------
	# Drive a clearly BASS-dominant frame, then a clearly TREBLE-dominant frame, and assert a bass-bound
	# fixture and a treble-bound fixture produce DIFFERENT receipts across the two frames.
	var bass_frame := { "signal.band.low": 0.95, "signal.band.mid": 0.1, "signal.band.high": 0.05,
		"signal.band.sub": 0.9, "signal.band.lowmid": 0.2, "signal.band.highmid": 0.05, "signal.energy": 0.6 }
	var treble_frame := { "signal.band.low": 0.05, "signal.band.mid": 0.1, "signal.band.high": 0.95,
		"signal.band.sub": 0.05, "signal.band.lowmid": 0.1, "signal.band.highmid": 0.9, "signal.energy": 0.6 }

	# Find a bass-bound fixture (a big lamp, addr 0) and a treble-bound fixture (a small strip pixel).
	var bass_addr := 0
	var treble_addr := 111   # the last strip pixel (smallest -> highest band)
	_check("(b) size->freq: the BIG lamp (addr 0) is bound to a LOW band (sub/low)",
		demo.addr_band_key(bass_addr).findn("low") >= 0 or demo.addr_band_key(bass_addr).findn("sub") >= 0)
	_check("(b) size->freq: the SMALL strip pixel (addr 111) is bound to a HIGH band (high/treble)",
		demo.addr_band_key(treble_addr).findn("high") >= 0 or demo.addr_band_key(treble_addr).findn("treble") >= 0)

	demo.drive_visisonor(bass_frame)
	var bass_lamp_on_bass: Dictionary = demo.led_receipt(bass_addr)
	var treble_pix_on_bass: Dictionary = demo.led_receipt(treble_addr)
	demo.drive_visisonor(treble_frame)
	var bass_lamp_on_treble: Dictionary = demo.led_receipt(bass_addr)
	var treble_pix_on_treble: Dictionary = demo.led_receipt(treble_addr)

	# The bass-bound lamp is BRIGHT on the bass frame and DIM on the treble frame (its band went 0.9->~0).
	var bass_lamp_lum_bass := _lum(bass_lamp_on_bass)
	var bass_lamp_lum_treble := _lum(bass_lamp_on_treble)
	_check("(b) receipt: bass-bound lamp is brighter on a BASS frame than a TREBLE frame (tracks its band)",
		bass_lamp_lum_bass > bass_lamp_lum_treble + 0.02)
	# The treble-bound pixel is BRIGHT on the treble frame and DIM on the bass frame.
	var treble_pix_lum_bass := _lum(treble_pix_on_bass)
	var treble_pix_lum_treble := _lum(treble_pix_on_treble)
	_check("(b) receipt: treble-bound pixel is brighter on a TREBLE frame than a BASS frame (tracks its band)",
		treble_pix_lum_treble > treble_pix_lum_bass + 0.02)
	# Every receipt is a well-formed device.set_led (declarative, ok, not a no-op).
	_check("(b) receipt: fixture receipts are declarative device.set_led (ok, not noop)",
		str(bass_lamp_on_bass.get("op")) == "device.set_led" and bass_lamp_on_bass.get("ok") == true
		and bass_lamp_on_bass.get("noop", null) == null)

	# --- (c) freq_to_color warm-for-bass / cool-for-treble ------------------------------------------
	var ftc = demo.freq_to_color_node()
	var warm: Dictionary = ftc.evaluate({ "bass": 0.9, "treble": 0.05, "amplitude": 0.9 }).get("value", {})
	var cool: Dictionary = ftc.evaluate({ "bass": 0.05, "treble": 0.9, "amplitude": 0.9 }).get("value", {})
	# WARM: red > blue. COOL: blue > red. (the item-6 bass=warm / treble=cool spec, verbatim.)
	_check("(c) freq_to_color: a BASS-dominant frame yields a WARM hue (r > b)",
		float(warm.get("r", 0.0)) > float(warm.get("b", 1.0)))
	_check("(c) freq_to_color: a TREBLE-dominant frame yields a COOL hue (b > r)",
		float(cool.get("b", 0.0)) > float(cool.get("r", 1.0)))
	# CompareDiff oracle: the warm and cool colours are genuinely different.
	cmp.params = { "metric": "l2" }
	var color_d := float(cmp.evaluate({
		"candidate": [float(warm.get("r")), float(warm.get("g")), float(warm.get("b"))],
		"reference": [float(cool.get("r")), float(cool.get("g")), float(cool.get("b"))],
	}).get("d", 0.0))
	_check("(c) freq_to_color: warm vs cool are genuinely different colours (l2 > 0.2)", color_d > 0.2)

	# --- (d) the screen quad renders a NON-BLANK frame ----------------------------------------------
	# drive_visisonor already re-textured the screen from the last (treble) frame; assert variance > 0.
	demo.drive_visisonor(bass_frame)   # one more frame to be sure the screen was textured
	var stats: Dictionary = demo.screen_stats()
	_check("(d) screen: the quad renders a NON-BLANK frame (variance > 0)",
		float(stats.get("variance", 0.0)) > 0.0)

	cmp.free()
	demo.queue_free()
	DeviceActions.unregister_device_ops_host()


# --- helpers ---------------------------------------------------------------------------------------

func _plain(v) -> Array:
	var out: Array = []
	if v is PackedFloat32Array or v is Array:
		for x in v:
			out.append(float(x))
	return out

func _maxf(a: Array) -> float:
	var m := 0.0
	for x in a:
		m = maxf(m, float(x))
	return m

## Luminance of a device.set_led receipt (r,g,b).
func _lum(receipt: Dictionary) -> float:
	return 0.2126 * float(receipt.get("r", 0.0)) + 0.7152 * float(receipt.get("g", 0.0)) + 0.0722 * float(receipt.get("b", 0.0))
