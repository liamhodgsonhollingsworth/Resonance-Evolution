class_name PrimVizParticles
extends Primitive
## PARTICLES (visi-sonor light-show Slice 2A, items 7+8) — an audio-reactive particle burst: the
## EMIT RATE is driven by energy (loud = spray more), a FORCE (gravity / wind) driven by bands pushes
## them, and each particle's COLOR comes from the freq balance. The staple "particles pop on the beat"
## music-video effect.
##
## RENDERER-NEUTRAL DATA (T): emits the live particle set as {kind:"point", x,y, r,g,b} items in a
## draw-list dict (the shared PrimVizSpectrumBars.rasterize plots each as a lit pixel — R).
##
## ITEM-8 REWIREABLE: emit_rate / force_x / force_y / color arrive on WIRES (prim_feature_pick), so
## which feature drives spray vs push vs hue is a re-param, never an engine edit.
##
## STATEFUL simulation (so NOT cacheable): particles persist across frames. Each evaluate() advances
## the sim one step — emit (Poisson-ish: emit_rate*emit_gain particles/frame, fractional accumulator),
## integrate position by velocity + force, age out particles past their lifetime, cap the live set at
## max_particles. Deterministic RNG (a seeded generator) so the headless test is reproducible.
##
## params:
##   max_particles  hard cap on the live set (default 128).
##   emit_gain      particles emitted per frame = emit_rate * emit_gain (default 8).
##   lifetime       frames a particle lives (default 40).
##   width,height   canvas size (default 128x128). Emitter at the bottom centre.
##   gravity        baseline downward force added to force_y (default 0.0; screen y grows down).
##   speed          initial upward launch speed (default 2.0 px/frame).
##   spread         horizontal launch spread px/frame (default 1.5).
##   seed           RNG seed for reproducibility (default 12345).
##   palette        freq_to_color palette handle for particle color (default "default").
##
## inputs:  emit_rate — 0..1 emission driver (energy). Unconnected = 0 -> no emission (C).
##          force_x, force_y — per-frame acceleration from bands (default 0).
##          bass, treble — optional, tint the particle color warm/cool (default clean white-ish).
## output:  out — the draw-list of live particles.

const FreqToColorRef := preload("res://primitives/prim_freq_to_color.gd")

# Each particle: {pos:Vector2, vel:Vector2, life:int, col:[r,g,b]}. Live set carried across frames.
var _particles: Array = []
var _emit_accum: float = 0.0
var _rng := RandomNumberGenerator.new()
var _seeded := false

func _init() -> void:
	prim_type = "VizParticles"

func input_ports() -> Array:
	return [
		{ "name": "emit_rate", "type": "number" },
		{ "name": "force_x", "type": "number" },
		{ "name": "force_y", "type": "number" },
		{ "name": "bass", "type": "number" },
		{ "name": "treble", "type": "number" },
	]

func output_ports() -> Array:
	return [{ "name": "out", "type": "image" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var w := int(params.get("width", 128))
	var h := int(params.get("height", 128))
	var cap := maxi(1, int(params.get("max_particles", 128)))
	var emit_gain := float(params.get("emit_gain", 8.0))
	var lifetime := maxi(1, int(params.get("lifetime", 40)))
	var gravity := float(params.get("gravity", 0.0))
	var speed := float(params.get("speed", 2.0))
	var spread := float(params.get("spread", 1.5))

	if not _seeded:
		_rng.seed = int(params.get("seed", 12345))
		_seeded = true

	var emit_rate: float = clampf(as_num(inputs.get("emit_rate")), 0.0, 1.0)
	var fx := as_num(inputs.get("force_x"))
	var fy := as_num(inputs.get("force_y")) + gravity
	var col := _particle_color(inputs)

	# EMIT: accumulate fractional emission; spawn whole particles from the emitter (bottom centre).
	_emit_accum += emit_rate * emit_gain
	while _emit_accum >= 1.0 and _particles.size() < cap:
		_emit_accum -= 1.0
		_particles.append({
			"pos": Vector2(float(w) * 0.5 + _rng.randf_range(-spread, spread) * 2.0, float(h) - 1.0),
			"vel": Vector2(_rng.randf_range(-spread, spread), -speed - _rng.randf_range(0.0, speed * 0.5)),
			"life": lifetime,
			"col": col,
		})
	if _emit_accum > float(cap):
		_emit_accum = float(cap)

	# INTEGRATE + AGE: advance each particle; drop dead / off-canvas ones.
	var survivors: Array = []
	for p in _particles:
		var vel: Vector2 = p["vel"] + Vector2(fx, fy)
		var pos: Vector2 = p["pos"] + vel
		var life: int = int(p["life"]) - 1
		if life > 0 and pos.y >= -2.0 and pos.y <= float(h) + 2.0 and pos.x >= -2.0 and pos.x <= float(w) + 2.0:
			survivors.append({ "pos": pos, "vel": vel, "life": life, "col": p["col"] })
	_particles = survivors

	# Emit the live set as draw-list points; fade alpha by remaining life.
	var viz: Array = []
	for p in _particles:
		var pos: Vector2 = p["pos"]
		var c: Array = p["col"]
		var a: float = clampf(float(p["life"]) / float(lifetime), 0.0, 1.0)
		viz.append({ "kind": "point", "x": pos.x, "y": pos.y, "r": float(c[0]) * a, "g": float(c[1]) * a, "b": float(c[2]) * a, "a": a })

	return { "out": {
		"kind": "particles",
		"viz": viz,
		"width": w,
		"height": h,
	} }

# Particle color from the band balance via freq_to_color's palette (bass=warm, treble=cool). Absent
# bands -> the warm endpoint (a defined default, C).
func _particle_color(inputs: Dictionary) -> Array:
	var pal: Dictionary = FreqToColorRef.PALETTES.get(str(params.get("palette", "default")), FreqToColorRef.PALETTES["default"])
	var bass: float = clampf(as_num(inputs.get("bass")), 0.0, 1.0)
	var treble: float = clampf(as_num(inputs.get("treble")), 0.0, 1.0)
	var total := bass + treble
	var t := 0.5 if total <= 0.0 else treble / total
	var warm: Array = pal.get("warm", [1.0, 0.2, 0.0])
	var cool: Array = pal.get("cool", [0.0, 0.2, 1.0])
	return [lerpf(float(warm[0]), float(cool[0]), t), lerpf(float(warm[1]), float(cool[1]), t), lerpf(float(warm[2]), float(cool[2]), t)]

func reset_state() -> void:
	_particles.clear()
	_emit_accum = 0.0
	_seeded = false

## Impure: carries the live particle set across frames. Never memoize.
func is_cacheable() -> bool:
	return false
