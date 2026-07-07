extends SceneTree
## HEADLESS SELF-TEST for the visi-sonor AUDIO ANALYSIS chain (Slice 1A):
##   prim_audio_source -> prim_spectrum -> prim_spectrum_bands -> set_input_frame(signal.band.low/mid/high)
##
##   <godot> --headless --path godot -s res://headless_audio_test.gd
##
## Judge PASS by the sentinel "RESULT: ALL PASS" (NOT the exit code — Godot's is unreliable headless).
##
## Why this shape (hardware-free + real-tree):
##   • A headless host has a DUMMY audio driver, so a live AudioStreamPlayer produces no real analyzer
##     magnitudes. The band-CHANGE proof therefore drives prim_spectrum through its SYNTHETIC magnitude
##     provider (set_magnitude_provider) — a KNOWN spectrum injected node-side — so every assertion runs
##     with zero live audio and zero hardware (item 9). The provider seam is the EXACT one a live room
##     fills from the analyzer instance, so the band-binning + EMA path under test is the real one.
##   • The INJECTION proof runs the chain on a REAL GraphRuntime (the same set_input_frame seam the
##     running room uses), then reads the injected frame back through BOTH a PrimInput and a
##     PrimSensor(mode='frame') — the downstream readers the plan names — proving the frame-key contract
##     end to end. PrimCompareDiff (l2) is the pass/fail oracle for "silence vs signal differ".
##   • The mp3 SOURCE contract is exercised directly: a real bundled clip if present (asserts a live
##     stream + advancing/defined playhead), else the MISSING-path declared no-op (ok:false, missing:true)
##     — the C-ideal fail-safe — plus the unknown-kind declared no-op. No un-specced source is wired.

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	_test_source_mp3_and_noops()
	_test_spectrum_bands_change_with_audio()
	_test_spectrum_bands_named_binning()
	_test_full_chain_injects_frame_and_downstream_reads()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- 1. prim_audio_source: mp3 wired; other kinds + missing file = declared no-ops (C ideal) --------

func _test_source_mp3_and_noops() -> void:
	# UNKNOWN / unwired kinds: stream/mic/loopback + a bogus kind all emit the declared no-op descriptor
	# (null stream, playhead 0, noop:true) — never a crash, never a live player. This is the general
	# seam with only mp3 wired (Liam's no-auto-generalize rule).
	for kind in ["stream", "mic", "loopback", "totally-unknown"]:
		var src := PrimAudioSource.new()
		get_root().add_child(src)
		src.params = { "source_kind": kind }
		var out: Dictionary = src.evaluate({})
		_check("SOURCE: kind '%s' is a declared no-op (null stream, noop:true)" % kind,
			out.get("pcm_stream") == null and out.get("noop") == true
			and float(out.get("playhead_seconds", -1.0)) == 0.0)
		src.free()

	# MP3 with a MISSING path: the C-ideal fail-safe — a declared missing no-op (ok:false, missing:true),
	# NOT a crash and NOT a live player. A host without the clip stays inert.
	var miss := PrimAudioSource.new()
	get_root().add_child(miss)
	miss.params = { "source_kind": "mp3", "path": "res://__no_such_clip__.mp3", "autoplay": false }
	var mout: Dictionary = miss.evaluate({})
	_check("SOURCE: mp3 with a missing path is a declared no-op (ok:false, missing:true)",
		mout.get("ok") == false and mout.get("missing") == true and mout.get("pcm_stream") == null)
	miss.free()

	# MP3 with a REAL bundled clip if one exists — asserts a live AudioStream + defined playhead. If no
	# clip is bundled (the common case in CI/headless), this arm is SKIPPED (reported), not failed: the
	# missing-path no-op above already proves the fail-safe, and the band pipeline is proven synthetically.
	var clip := _find_bundled_mp3()
	if clip == "":
		print("SKIP  SOURCE: no bundled .mp3 found under res://assets — live-stream arm skipped (no-op path proven above)")
	else:
		var src := PrimAudioSource.new()
		get_root().add_child(src)
		src.params = { "source_kind": "mp3", "path": clip, "autoplay": true, "loop": true, "bus": "VisiSonorTest" }
		var out: Dictionary = src.evaluate({})
		_check("SOURCE: real mp3 clip loads a live AudioStream (ok:true, stream != null)",
			out.get("ok") == true and out.get("pcm_stream") != null)
		_check("SOURCE: playhead_seconds is a defined float >= 0",
			out.get("playhead_seconds") != null and float(out.get("playhead_seconds")) >= 0.0)
		src.free()

## Find any bundled .mp3 under res://assets (best-effort; returns "" if none). Kept tolerant so the
## test is portable across checkouts that may or may not ship a demo clip.
func _find_bundled_mp3() -> String:
	var roots := ["res://assets", "res://assets/audio", "res://"]
	for r in roots:
		var dir := DirAccess.open(r)
		if dir == null:
			continue
		dir.list_dir_begin()
		var f := dir.get_next()
		while f != "":
			if not dir.current_is_dir() and f.to_lower().ends_with(".mp3"):
				dir.list_dir_end()
				return r.path_join(f)
			f = dir.get_next()
		dir.list_dir_end()
	return ""

# --- 2. prim_spectrum: bands CHANGE with audio present vs silence (synthetic provider) --------------

func _test_spectrum_bands_change_with_audio() -> void:
	var spec := PrimSpectrum.new()
	get_root().add_child(spec)
	spec.params = { "n_bands": 16, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.0, "normalize": true }

	# SILENCE: an all-zero magnitude provider -> all bands ~0.
	spec.set_magnitude_provider(func(_a: float, _b: float) -> float: return 0.0)
	var silence := _to_arr(spec.evaluate({}).get("bands"))
	_check("SPECTRUM: silence -> all bands ~0", _max(silence) < 0.001)

	# AUDIO: a provider with energy concentrated in the LOW range (a 'bass' spectrum). Bands overlapping
	# the low frequencies read high; the rest stay low. Values must differ materially from silence.
	spec.set_magnitude_provider(func(from_hz: float, to_hz: float) -> float:
		var center := sqrt(maxf(1.0, from_hz) * maxf(1.0, to_hz))
		return 0.9 if center < 200.0 else 0.02)
	var audio := _to_arr(spec.evaluate({}).get("bands"))
	_check("SPECTRUM: audio present -> at least one band is strong (> 0.5)", _max(audio) > 0.5)

	# ORACLE: the two band vectors must be far apart (l2 >> 0). PrimCompareDiff is the pass/fail oracle.
	var cmp := PrimCompareDiff.new()
	get_root().add_child(cmp)
	cmp.params = { "metric": "l2" }
	# CompareDiff's l2 metric compares plain Arrays (not PackedFloat32Array), so hand it plain arrays —
	# this is the realistic use: the generic oracle takes a generic numeric array off any wire.
	var d := float(cmp.evaluate({
		"candidate": _as_plain(audio), "reference": _as_plain(silence) }).get("d", 0.0))
	_check("SPECTRUM: bands CHANGE with audio vs silence (l2 distance > 0.3, CompareDiff oracle)", d > 0.3)
	cmp.free()

	# EMA SMOOTHING is load-bearing: with heavy smoothing, a single audio frame after silence only
	# PARTIALLY moves toward the raw value (out = s*prev + (1-s)*raw), so it lags — proving the smoother
	# is wired, not a pass-through. smoothing=0.8 -> after one frame a raw-0.9 band sits near 0.18, not 0.9.
	var sm := PrimSpectrum.new()
	get_root().add_child(sm)
	sm.params = { "n_bands": 8, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.8, "normalize": true }
	sm.set_magnitude_provider(func(_a: float, _b: float) -> float: return 0.0)
	sm.evaluate({})   # seed EMA state at 0 (silence)
	sm.set_magnitude_provider(func(_a: float, _b: float) -> float: return 0.9)
	var one := _to_arr(sm.evaluate({}).get("bands"))
	_check("SPECTRUM: EMA lag — one frame of 0.9 after silence stays well below 0.9 (smoothing wired)",
		_max(one) > 0.0 and _max(one) < 0.5)
	sm.free()
	spec.free()

# --- 3. prim_spectrum_bands: raw bands -> named sub/bass/.../treble + low/mid/high -------------------

func _test_spectrum_bands_named_binning() -> void:
	# Feed a raw 16-band vector that is HOT in the low third and cold elsewhere. The named 'low' (=max of
	# sub/bass) must read high; 'high' (=max of highmid/treble) must read low.
	var raw := PackedFloat32Array()
	raw.resize(16)
	for i in range(16):
		raw[i] = 0.95 if i < 4 else 0.05
	var nb := PrimSpectrumBands.new()
	get_root().add_child(nb)
	nb.params = { "band_edges_hz": [20.0, 60.0, 250.0, 500.0, 2000.0, 6000.0, 20000.0], "min_hz": 20.0, "max_hz": 20000.0 }
	var out: Dictionary = nb.evaluate({ "bands": raw })
	var named: Dictionary = out.get("named", {})
	# all six canonical bands (mid preserved under mid_band due to the name collision) + the seam triple.
	_check("BANDS: named dict has all six canonical bands + the low/mid/high seam triple",
		named.has("sub") and named.has("bass") and named.has("lowmid") and named.has("mid_band")
		and named.has("highmid") and named.has("treble")
		and named.has("low") and named.has("mid") and named.has("high"))
	_check("BANDS: low > high for a bass-heavy spectrum (freq binning correct)",
		float(out.get("low", 0.0)) > float(out.get("high", 1.0)))
	_check("BANDS: low/mid/high ports mirror the named dict",
		float(out.get("low")) == float(named.get("low"))
		and float(out.get("high")) == float(named.get("high")))
	_check("BANDS: every named value is in [0,1]",
		_all_in_unit([named.get("sub"), named.get("bass"), named.get("lowmid"),
			named.get("mid_band"), named.get("highmid"), named.get("treble"),
			named.get("low"), named.get("mid"), named.get("high")]))

	# EMPTY input = a declared no-op: every named band 0.0, never a crash (C ideal).
	var empty: Dictionary = nb.evaluate({ "bands": null })
	_check("BANDS: absent input -> all-zero named bands (declared no-op, no crash)",
		float(empty.get("low", -1.0)) == 0.0 and float(empty.get("high", -1.0)) == 0.0)
	nb.free()

# --- 4. FULL CHAIN: inject signal.band.low/mid/high; a downstream Input + Sensor(frame) read it -----

func _test_full_chain_injects_frame_and_downstream_reads() -> void:
	# Build the chain as standalone primitives (source -> spectrum -> bands), drive prim_spectrum with a
	# synthetic BASS spectrum so low >> high, then INJECT the named triple into a REAL GraphRuntime via
	# the EXISTING set_input_frame seam. A downstream PrimInput('signal.band.low') and a
	# PrimSensor(mode='frame', sensor_id='signal.band.high') read their keys back out — the exact
	# portability contract visisonor_loop.json + demo_interactions.gd already rely on.
	var spec := PrimSpectrum.new()
	get_root().add_child(spec)
	spec.params = { "n_bands": 16, "min_hz": 20.0, "max_hz": 20000.0, "smoothing": 0.0 }
	spec.set_magnitude_provider(func(from_hz: float, to_hz: float) -> float:
		var center := sqrt(maxf(1.0, from_hz) * maxf(1.0, to_hz))
		return 0.9 if center < 200.0 else 0.05)
	var bands = spec.evaluate({}).get("bands")

	var nb := PrimSpectrumBands.new()
	get_root().add_child(nb)
	nb.params = { "band_edges_hz": [20.0, 60.0, 250.0, 500.0, 2000.0, 6000.0, 20000.0], "min_hz": 20.0, "max_hz": 20000.0 }
	var named_out: Dictionary = nb.evaluate({ "bands": bands })
	var lo := float(named_out.get("low"))
	var md := float(named_out.get("mid"))
	var hi := float(named_out.get("high"))
	_check("CHAIN: analyzed bass spectrum -> low (%.2f) > high (%.2f)" % [lo, hi], lo > hi)

	# The INJECTOR step (what the demo integration / a host runs each frame): deposit the named triple
	# under the exact keys the existing arrangements read. This is the SEAM — reused, not reinvented.
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1", "name": "audio_chain_readers",
		"nodes": [
			{ "id": "in_low", "type": "Input", "params": { "input_id": "signal.band.low", "default": -1.0 } },
			{ "id": "sen_high", "type": "Sensor", "params": { "mode": "frame", "sensor_id": "signal.band.high", "default": -1.0 } },
		],
		"wires": [],
	})
	rt.set_input_frame({ "signal.band.low": lo, "signal.band.mid": md, "signal.band.high": hi })
	_check("CHAIN: set_input_frame round-trips the injected low key",
		rt.get_input_frame().get("signal.band.low") == lo)
	var out := rt.evaluate()
	var read_low = out.get("in_low", {}).get("value")
	var read_high = out.get("sen_high", {}).get("value")
	_check("CHAIN: downstream PrimInput reads signal.band.low off the frame (== injected)",
		read_low == lo)
	_check("CHAIN: downstream PrimSensor(mode='frame') reads signal.band.high off the SAME seam (== injected)",
		read_high == hi)

	# ORACLE: what the downstream nodes read must EQUAL what the chain produced (CompareDiff dict oracle).
	var cmp := PrimCompareDiff.new()
	get_root().add_child(cmp)
	cmp.params = { "metric": "dict_equality" }
	var d := float(cmp.evaluate({
		"candidate": { "low": read_low, "high": read_high },
		"reference": { "low": lo, "high": hi },
	}).get("d", 1.0))
	_check("CHAIN: downstream reads == chain output (CompareDiff dict_equality == 0.0)", d == 0.0)

	# C-ideal at the seam: an Input whose key the frame LACKS falls to params.default, chain still runs.
	rt.set_input_frame({ "signal.band.low": lo })   # no high key this frame
	var out2 := rt.evaluate()
	_check("CHAIN: absent high key -> downstream Sensor falls to its default (-1.0), no crash",
		out2.get("sen_high", {}).get("value") == -1.0)

	cmp.free()
	rt.free()
	nb.free()
	spec.free()

# --- helpers ---------------------------------------------------------------------------------------

func _to_arr(v) -> PackedFloat32Array:
	if v is PackedFloat32Array:
		return v
	var out := PackedFloat32Array()
	if v is Array:
		for x in v:
			out.append(float(x))
	return out

## Convert a PackedFloat32Array to a plain Array (CompareDiff's l2/abs metrics compare plain Arrays).
func _as_plain(a: PackedFloat32Array) -> Array:
	var out: Array = []
	for x in a:
		out.append(float(x))
	return out

func _max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for x in a:
		m = maxf(m, x)
	return m

func _all_in_unit(vals: Array) -> bool:
	for v in vals:
		if v == null:
			return false   # a missing key is a failure (float(null) would crash)
		var f := float(v)
		if f < 0.0 or f > 1.0:
			return false
	return true
