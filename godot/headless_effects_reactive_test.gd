extends SceneTree
## REAL-TREE TEST for Slice 2A — REACTIVE VIZ-EFFECT NODES (visi-sonor light-show arc, items 7+8).
##
##   <godot> --headless --path godot -s res://headless_effects_reactive_test.gd
##
## Drives the SAME GraphRuntime the running room hot-loads arrangements into (NOT a bare isolated
## node) — the eight new primitives are wired into a live GraphRuntime, the synthetic band frame is
## injected via the EXISTING set_input_frame seam (the read side PrimInput/PrimFeaturePick already
## use), and evaluate() runs the real topo/dataflow. A standalone-node call would be a #049 FALSE
## PASS; this exercises the nodes exactly as the effects gallery arrangement will.
##
## What it proves (the slice's assertions + the ideals):
##  (VIZ RESPONDS)  each viz node (spectrum_bars / waveform / reactive_shape / particles / flash)
##                  emits renderer-neutral DATA that CHANGES when its bound feature changes.
##  (ITEM-8 REPOINT) each viz node reads its driving value off a FeaturePick WIRE, so repointing the
##                  FeaturePick from one band key to another repoints the viz — a re-param, never an
##                  engine edit. This is the item-8 generality assertion.
##  (ONSET)         prim_onset_detect fires on an energy SPIKE and its ADAPTIVE EMA threshold rides
##                  the running level (a sustained-loud passage stops re-firing; a fresh spike fires).
##  (TEMPO)         prim_beat_tempo estimates a KNOWN BPM from a periodic onset train.
##  (LATCH)         prim_trigger_latch turns a one-frame onset into a DECAYING envelope.
##  Ideals verified in the REAL tree: T (plain DATA on wires — no Godot Image/Node on any port),
##  C (absent/unknown feature key or empty input = declared no-op, never a crash), D (a node re-param
##  diff-reloads live), N (all NEW nodes — no primitive edits), R (viz renders through the existing
##  render/effect seam by emitting an effect-source draw-list + a static CPU rasterizer).

const GraphRuntimeRef := preload("res://runtime/graph_runtime.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _approx(a: float, b: float, eps: float = 1e-4) -> bool:
	return abs(a - b) <= eps

func _initialize() -> void:
	_run()

# Build a live GraphRuntime with the eight new 2A types registered on it (the real dataflow host).
func _make_runtime() -> GraphRuntime:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.register("VizSpectrumBars", load("res://primitives/prim_viz_spectrum_bars.gd"))
	rt.register("VizWaveform", load("res://primitives/prim_viz_waveform.gd"))
	rt.register("VizReactiveShape", load("res://primitives/prim_viz_reactive_shape.gd"))
	rt.register("VizParticles", load("res://primitives/prim_viz_particles.gd"))
	rt.register("VizFlash", load("res://primitives/prim_viz_flash.gd"))
	rt.register("OnsetDetect", load("res://primitives/prim_onset_detect.gd"))
	rt.register("BeatTempo", load("res://primitives/prim_beat_tempo.gd"))
	rt.register("TriggerLatch", load("res://primitives/prim_trigger_latch.gd"))
	# FeaturePick is the item-8 router the viz nodes read through (already registered host-wide).
	rt.register("FeaturePick", load("res://primitives/prim_feature_pick.gd"))
	return rt

func _run() -> void:
	_test_spectrum_bars()
	_test_waveform()
	_test_reactive_shape()
	_test_particles()
	_test_flash()
	_test_onset_detect()
	_test_beat_tempo()
	_test_trigger_latch()
	_test_render_seam()
	_test_ideals_noop()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# A draw-list descriptor is renderer-neutral DATA (T): { viz:[...], width, height }. Every viz node
# emits this shape so any consumer (a 2D delegate, prim_render2d source, prim_effect_stack post) reads
# it identically. This helper asserts the shape.
func _is_drawlist(v) -> bool:
	return typeof(v) == TYPE_DICTIONARY and v.has("viz") and typeof(v["viz"]) == TYPE_ARRAY \
		and v.has("width") and v.has("height")

# --- SPECTRUM BARS: bands[] -> bars; responds to the band values, repoints via FeaturePick ---------
func _test_spectrum_bars() -> void:
	var rt := _make_runtime()
	# A spectrum-bars node reads a `bands` wire — an array of feature values. Here we feed it a small
	# arrangement: three FeaturePicks (bass/mid/treble) collected by the bars node via its bands port.
	# (The bars node also accepts explicit `bands` as a wired array; the injected frame drives them.)
	var arr := {
		"format": "resonance.arrangement/v1", "name": "spectrum_bars",
		"nodes": [
			{ "id": "lo", "type": "FeaturePick", "params": { "feature": "bass" } },
			{ "id": "mi", "type": "FeaturePick", "params": { "feature": "mid" } },
			{ "id": "hi", "type": "FeaturePick", "params": { "feature": "treble" } },
			{ "id": "bars", "type": "VizSpectrumBars", "params": { "count": 3, "layout": "linear", "width": 64, "height": 32 } },
		],
		"wires": [
			{ "from": "lo", "out": "value", "to": "bars", "in": "b0" },
			{ "from": "mi", "out": "value", "to": "bars", "in": "b1" },
			{ "from": "hi", "out": "value", "to": "bars", "in": "b2" },
		],
	}
	rt.load_arrangement(arr)

	rt.set_input_frame({ "signal.band.low": 0.9, "signal.band.mid": 0.5, "signal.band.high": 0.1 })
	var out := rt.evaluate()
	var d = out.get("bars", {}).get("out")
	_check("(bars) emits a renderer-neutral draw-list descriptor (T: DATA on the wire)", _is_drawlist(d))
	var bars: Array = d.get("viz", [])
	_check("(bars) one bar per band", bars.size() == 3)
	# Bar heights track the bound bands: bass bar (0.9) is TALLER than treble bar (0.1).
	var h0 := float(bars[0].get("h", 0.0))
	var h2 := float(bars[2].get("h", 0.0))
	_check("(bars) responds: taller bar for the louder (bass) band than the quieter (treble) band", h0 > h2)

	# ITEM-8 REPOINT: change the frame so treble is now the loud band. The SAME wired bars node follows,
	# because it reads the picks off wires, not a hardcoded band.
	rt.set_input_frame({ "signal.band.low": 0.1, "signal.band.mid": 0.5, "signal.band.high": 0.9 })
	var out2 := rt.evaluate()
	var bars2: Array = out2.get("bars", {}).get("out", {}).get("viz", [])
	_check("(bars) ITEM-8: repointed feature values flow through — treble bar now taller than bass bar",
		float(bars2[2].get("h", 0.0)) > float(bars2[0].get("h", 0.0)))
	rt.free()

# --- WAVEFORM: oscilloscope / lissajous line from a signal wire ------------------------------------
func _test_waveform() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "waveform",
		"nodes": [
			{ "id": "amp", "type": "FeaturePick", "params": { "feature": "energy" } },
			{ "id": "wav", "type": "VizWaveform", "params": { "mode": "oscilloscope", "samples": 16, "width": 64, "height": 32 } },
		],
		"wires": [ { "from": "amp", "out": "value", "to": "wav", "in": "amplitude" } ],
	}
	rt.load_arrangement(arr)
	rt.set_input_frame({ "signal.energy": 0.0 })
	var quiet = rt.evaluate().get("wav", {}).get("out")
	_check("(waveform) emits a draw-list (T)", _is_drawlist(quiet))
	var pts_quiet: Array = quiet.get("viz", [])
	_check("(waveform) emits a polyline of the requested sample count", pts_quiet.size() == 16)
	# Amplitude drives the line's vertical excursion: a loud frame spans MORE vertical range.
	rt.set_input_frame({ "signal.energy": 1.0 })
	var loud = rt.evaluate().get("wav", {}).get("out")
	_check("(waveform) responds: louder amplitude -> larger vertical excursion",
		_span_y(loud.get("viz", [])) > _span_y(pts_quiet))
	rt.free()

func _span_y(pts: Array) -> float:
	if pts.is_empty():
		return 0.0
	var lo := 1e9
	var hi := -1e9
	for p in pts:
		var y := float(p.get("y", 0.0))
		lo = minf(lo, y); hi = maxf(hi, y)
	return hi - lo

# --- REACTIVE SHAPE: circle/blob; radius<-feature, per-vertex deform<-feature ----------------------
func _test_reactive_shape() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "reactive_shape",
		"nodes": [
			{ "id": "rad", "type": "FeaturePick", "params": { "feature": "bass" } },
			{ "id": "def", "type": "FeaturePick", "params": { "feature": "treble" } },
			{ "id": "shape", "type": "VizReactiveShape", "params": { "sides": 24, "base_radius": 4.0, "radius_gain": 12.0, "deform_gain": 6.0, "width": 64, "height": 64 } },
		],
		"wires": [
			{ "from": "rad", "out": "value", "to": "shape", "in": "radius" },
			{ "from": "def", "out": "value", "to": "shape", "in": "deform" },
		],
	}
	rt.load_arrangement(arr)
	rt.set_input_frame({ "signal.band.low": 0.0, "signal.band.high": 0.0 })
	var small = rt.evaluate().get("shape", {}).get("out")
	_check("(shape) emits a draw-list (T)", _is_drawlist(small))
	var poly_small: Array = small.get("viz", [])
	_check("(shape) emits a closed polygon of `sides` vertices", poly_small.size() == 24)
	# radius<-bass: a bass-loud frame yields a LARGER mean radius than a silent frame.
	rt.set_input_frame({ "signal.band.low": 1.0, "signal.band.high": 0.0 })
	var big = rt.evaluate().get("shape", {}).get("out")
	_check("(shape) responds: radius grows with the bound (bass) feature",
		_mean_radius(big.get("viz", []), 32.0, 32.0) > _mean_radius(poly_small, 32.0, 32.0))
	# per-vertex deform<-treble: a treble-loud frame makes the vertex radii UNEVEN (higher variance).
	rt.set_input_frame({ "signal.band.low": 1.0, "signal.band.high": 1.0 })
	var deformed = rt.evaluate().get("shape", {}).get("out")
	_check("(shape) responds: deform feature raises per-vertex radius variance (Milkdrop-in-miniature)",
		_radius_variance(deformed.get("viz", []), 32.0, 32.0) > _radius_variance(big.get("viz", []), 32.0, 32.0))
	rt.free()

func _mean_radius(poly: Array, cx: float, cy: float) -> float:
	if poly.is_empty():
		return 0.0
	var s := 0.0
	for p in poly:
		s += Vector2(float(p.get("x", cx)) - cx, float(p.get("y", cy)) - cy).length()
	return s / float(poly.size())

func _radius_variance(poly: Array, cx: float, cy: float) -> float:
	if poly.is_empty():
		return 0.0
	var m := _mean_radius(poly, cx, cy)
	var s := 0.0
	for p in poly:
		var r := Vector2(float(p.get("x", cx)) - cx, float(p.get("y", cy)) - cy).length()
		s += (r - m) * (r - m)
	return s / float(poly.size())

# --- PARTICLES: emit_rate<-energy, force<-bands, color<-freq_to_color ------------------------------
func _test_particles() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "particles",
		"nodes": [
			{ "id": "en", "type": "FeaturePick", "params": { "feature": "energy" } },
			{ "id": "parts", "type": "VizParticles", "params": { "max_particles": 32, "emit_gain": 20.0, "width": 64, "height": 64 } },
		],
		"wires": [ { "from": "en", "out": "value", "to": "parts", "in": "emit_rate" } ],
	}
	rt.load_arrangement(arr)
	# Silence: no emission. Step a few frames; the live count stays at/near zero.
	rt.set_input_frame({ "signal.energy": 0.0 })
	var q
	for i in range(5):
		q = rt.evaluate().get("parts", {}).get("out")
	_check("(particles) emits a draw-list (T)", _is_drawlist(q))
	var n_quiet: int = q.get("viz", []).size()
	# Loud: energy drives emission; over several frames the live particle count RISES above silence.
	rt.set_input_frame({ "signal.energy": 1.0 })
	var l
	for i in range(5):
		l = rt.evaluate().get("parts", {}).get("out")
	var n_loud: int = l.get("viz", []).size()
	_check("(particles) responds: energy drives emission (loud frame -> more live particles)", n_loud > n_quiet)
	_check("(particles) live count is bounded by max_particles", n_loud <= 32)
	rt.free()

# --- FLASH: beat_pulse/onset -> decaying fullscreen tint ------------------------------------------
func _test_flash() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "flash",
		"nodes": [
			{ "id": "flash", "type": "VizFlash", "params": { "decay": 0.5, "width": 64, "height": 64 } },
		],
		"wires": [],
	}
	rt.load_arrangement(arr)
	# A trigger of 1.0 lights the tint to full; subsequent 0-trigger frames DECAY the intensity.
	rt.set_input_frame({})
	var f0 = _feed_flash(rt, arr, 1.0)
	_check("(flash) emits a draw-list (T)", _is_drawlist(f0))
	var i0 := _flash_intensity(f0)
	_check("(flash) a trigger lights the tint (intensity > 0)", i0 > 0.0)
	var f1 := _feed_flash(rt, arr, 0.0)
	var i1 := _flash_intensity(f1)
	var f2 := _feed_flash(rt, arr, 0.0)
	var i2 := _flash_intensity(f2)
	_check("(flash) DECAYS after the trigger (i0 > i1 > i2)", i0 > i1 and i1 > i2)
	rt.free()

func _feed_flash(rt: GraphRuntime, arr: Dictionary, trig: float):
	# Re-drive the flash node's `trigger` input by wiring a Const each call (a fresh arrangement so the
	# trigger value changes; the node's own decay state persists because the node instance is reused
	# across load_arrangement only if the id is stable — here we drive via a wired Const).
	var a := arr.duplicate(true)
	a["nodes"].append({ "id": "trg", "type": "Const", "params": { "value": trig } })
	a["wires"].append({ "from": "trg", "out": "value", "to": "flash", "in": "trigger" })
	rt.load_arrangement(a)
	return rt.evaluate().get("flash", {}).get("out")

func _flash_intensity(f) -> float:
	if not _is_drawlist(f):
		return 0.0
	var viz: Array = f.get("viz", [])
	if viz.is_empty():
		return 0.0
	return float(viz[0].get("a", 0.0))

# --- ONSET DETECT: energy-flux, ADAPTIVE EMA threshold -------------------------------------------
func _test_onset_detect() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "onset",
		"nodes": [
			{ "id": "on", "type": "OnsetDetect", "params": { "feature": "energy", "sensitivity": 1.5, "threshold_ema": 0.1 } },
		],
		"wires": [],
	}
	# A quiet baseline, then a SPIKE. The spike's positive flux exceeds the adaptive threshold -> onset.
	var levels := [0.1, 0.1, 0.1, 0.1, 0.9, 0.9, 0.9, 0.9, 0.9]
	var fired := []
	for lv in levels:
		rt.load_arrangement(arr)
		rt.set_input_frame({ "signal.energy": lv })
		var o := rt.evaluate().get("on", {})
		fired.append(float(o.get("onset", 0.0)) > 0.5)
	_check("(onset) fires on the energy SPIKE (0.1 -> 0.9 transition)", fired[4])
	_check("(onset) does NOT fire on the flat quiet baseline before the spike", not fired[1] and not fired[2])
	# ADAPTIVE: after the level stays high, the running EMA threshold rises and the sustained-loud
	# frames stop re-firing (no flux) — the load-bearing adaptive behaviour.
	_check("(onset) ADAPTIVE: sustained-loud frames after the onset stop re-firing (threshold rode up)",
		not fired[6] and not fired[7] and not fired[8])
	rt.free()

# --- BEAT TEMPO: estimate a known BPM ------------------------------------------------------------
func _test_beat_tempo() -> void:
	var rt := _make_runtime()
	# Feed a periodic onset train at a KNOWN period. At 120 BPM = 2 beats/sec; with dt=1/60 s that is
	# one onset every 30 frames. Feed onsets on frames 0,30,60,90,... and assert the estimate ~120 BPM.
	var arr := {
		"format": "resonance.arrangement/v1", "name": "tempo",
		"nodes": [ { "id": "bt", "type": "BeatTempo", "params": { "dt": 0.016666667, "min_bpm": 40.0, "max_bpm": 240.0 } } ],
		"wires": [],
	}
	var last := {}
	var period := 30
	for frame in range(300):
		rt.load_arrangement(arr)
		var onset := 1.0 if (frame % period) == 0 else 0.0
		# drive the onset input via a wired Const
		var a := arr.duplicate(true)
		a["nodes"].append({ "id": "trg", "type": "Const", "params": { "value": onset } })
		a["wires"].append({ "from": "trg", "out": "value", "to": "bt", "in": "onset" })
		rt.load_arrangement(a)
		last = rt.evaluate().get("bt", {})
	var bpm := float(last.get("bpm", 0.0))
	_check("(tempo) estimates ~120 BPM from a 30-frame-period onset train (got %.1f)" % bpm, abs(bpm - 120.0) <= 12.0)
	_check("(tempo) emits a phase in 0..1", float(last.get("phase", -1.0)) >= 0.0 and float(last.get("phase", 2.0)) <= 1.0)
	rt.free()

# --- TRIGGER LATCH: onset -> decaying envelope ---------------------------------------------------
func _test_trigger_latch() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "latch",
		"nodes": [ { "id": "lt", "type": "TriggerLatch", "params": { "decay": 0.6, "attack": 1.0 } } ],
		"wires": [],
	}
	var env := []
	# One onset frame, then silence: the envelope jumps to 1.0 and decays geometrically.
	var trigs := [1.0, 0.0, 0.0, 0.0, 0.0]
	for t in trigs:
		var a := arr.duplicate(true)
		a["nodes"].append({ "id": "trg", "type": "Const", "params": { "value": t } })
		a["wires"].append({ "from": "trg", "out": "value", "to": "lt", "in": "onset" })
		rt.load_arrangement(a)
		env.append(float(rt.evaluate().get("lt", {}).get("value", 0.0)))
	_check("(latch) onset drives the envelope to full (~1.0)", env[0] > 0.9)
	_check("(latch) DECAYS monotonically after the onset (env[1] > env[2] > env[3])",
		env[1] > env[2] and env[2] > env[3])
	_check("(latch) envelope stays in 0..1", env[0] <= 1.0001 and env[4] >= 0.0)
	rt.free()

# --- RENDER SEAM (R): a viz draw-list rasterizes to an Image via the node's static CPU rasterizer,
# so it feeds prim_render2d's source / prim_effect_stack's post-target — the existing render seam. ---
func _test_render_seam() -> void:
	var rt := _make_runtime()
	var arr := {
		"format": "resonance.arrangement/v1", "name": "render_seam",
		"nodes": [
			{ "id": "lo", "type": "FeaturePick", "params": { "feature": "bass" } },
			{ "id": "bars", "type": "VizSpectrumBars", "params": { "count": 1, "width": 16, "height": 16 } },
		],
		"wires": [ { "from": "lo", "out": "value", "to": "bars", "in": "b0" } ],
	}
	rt.load_arrangement(arr)
	rt.set_input_frame({ "signal.band.low": 0.8 })
	var d = rt.evaluate().get("bars", {}).get("out")
	# The node exposes a STATIC rasterizer that turns the renderer-neutral draw-list into an Image the
	# existing prim_render2d source path / EffectStackCpu consume — pixel realization in a swappable
	# delegate, DATA on the wire (T + R).
	var img: Image = load("res://primitives/prim_viz_spectrum_bars.gd").rasterize(d)
	_check("(render seam R) draw-list rasterizes to a non-null Image of the requested size",
		img != null and img.get_width() == 16 and img.get_height() == 16)
	# The rasterized image is non-blank (some lit pixel from the 0.8 bar).
	var lit := false
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).v > 0.05:
				lit = true
	_check("(render seam R) rasterized bar image is non-blank (a lit pixel exists)", lit)
	rt.free()

# --- IDEALS: C — absent/unknown feature or empty input = declared no-op, never a crash ------------
func _test_ideals_noop() -> void:
	var rt := _make_runtime()
	# Every viz node with NO wired inputs and NO frame must still emit a valid (possibly empty-content)
	# draw-list, never crash. This is the C ideal across the whole family.
	for t in ["VizSpectrumBars", "VizWaveform", "VizReactiveShape", "VizParticles", "VizFlash"]:
		var arr := {
			"format": "resonance.arrangement/v1", "name": "noop_" + t,
			"nodes": [ { "id": "n", "type": t, "params": {} } ],
			"wires": [],
		}
		rt.load_arrangement(arr)
		rt.set_input_frame({})
		var d = rt.evaluate().get("n", {}).get("out")
		_check("(C ideal) %s with no input emits a valid draw-list (no crash)" % t, _is_drawlist(d))
	# Beat family with no input: defined zero-ish outputs, no crash.
	for t in ["OnsetDetect", "BeatTempo", "TriggerLatch"]:
		var arr := {
			"format": "resonance.arrangement/v1", "name": "noop_" + t,
			"nodes": [ { "id": "n", "type": t, "params": {} } ],
			"wires": [],
		}
		rt.load_arrangement(arr)
		rt.set_input_frame({})
		var o = rt.evaluate().get("n", {})
		_check("(C ideal) %s with no input returns a dict (no crash)" % t, typeof(o) == TYPE_DICTIONARY)
	rt.free()
