class_name PrimSpectrum
extends Primitive
## The SPECTRUM node (visi-sonor arc, Slice 1A) — the middle of the analysis chain
## prim_audio_source -> prim_spectrum -> prim_spectrum_bands -> set_input_frame. It wraps Godot's
## BUILT-IN AudioEffectSpectrumAnalyzer on the source's bus and emits a fixed, small set of log-spaced,
## EMA-smoothed magnitude bands as a plain float array (T ideal: renderer-neutral DATA on a wire, so any
## downstream node subscribes). NO custom FFT/DSP is written — the engine's analyzer does the transform;
## this node only bins its per-range magnitudes and smooths them.
##
## WHY LOG-SPACED + BINNED + SMOOTHED (the load-bearing design, from the plan):
##   • LOG-spaced: musical energy is roughly log-distributed across frequency; a few log bands (8..32)
##     capture sub/bass/mid/treble structure far better than linear bins, and calling the analyzer a
##     small fixed number of times per frame is cheap (per-bin over thousands of Hz would be expensive).
##   • EMA-smoothed: raw analyzer magnitudes JITTER frame-to-frame (temporal aliasing of the FFT). An
##     exponential moving average per band (params.smoothing, 0=no smoothing .. ~0.9 heavy) gives a
##     stable value a light/effect can bind to without strobing. State is per-band, kept across frames.
##
## THE MAGNITUDE SEAM (headless-testable, no live audio device required):
##   The band values come from a magnitude PROVIDER: a Callable(from_hz, to_hz) -> float. In a live room
##   the provider reads the analyzer instance on the bus (get_bus_effect_instance(...).
##   get_magnitude_for_frequency_range). In a headless self-test the provider is a SYNTHETIC function
##   (a known spectrum) injected via set_magnitude_provider() — so every audio test runs with zero live
##   audio and zero hardware (item 9). When NO provider and NO live analyzer are available, the node
##   emits all-zero bands (a declared no-op, C ideal) rather than crashing.
##
## params:
##   bus            — the audio bus carrying the analyzer (matches prim_audio_source.bus). Default "VisiSonor".
##   effect_index   — the index of the AudioEffectSpectrumAnalyzer on that bus. Default 0.
##   n_bands        — number of log-spaced bands to emit. Clamped to [1, 64]. Default 16.
##   min_hz/max_hz  — the log range the bands span. Defaults 20 .. 20000 (human hearing).
##   smoothing      — EMA factor in [0,1): out = smoothing*prev + (1-smoothing)*raw. Default 0.6.
##   gain           — linear multiplier applied to each raw magnitude before smoothing. Default 1.0.
##   normalize      — clamp each smoothed band to [0,1] after gain. Default true (bands are 0..1 signals).
##
## outputs:
##   bands   — a PackedFloat32Array of length n_bands, low frequency first, each ~0..1 (T ideal DATA).
##   n_bands — the band count (so prim_spectrum_bands / a menu reads the shape off the wire).

# Per-band EMA state, kept across evaluate()s. Rebuilt when n_bands changes.
var _ema: PackedFloat32Array = PackedFloat32Array()
# An optional synthetic magnitude provider for headless tests: Callable(from_hz, to_hz) -> float.
# When null, evaluate() reads the live analyzer instance on the bus (or emits zeros if absent).
var _provider: Callable = Callable()

func _init() -> void:
	prim_type = "Spectrum"

func output_ports() -> Array:
	return [
		{ "name": "bands", "type": "any" },
		{ "name": "n_bands", "type": "number" },
	]

func _n_bands() -> int:
	return clampi(int(params.get("n_bands", 16)), 1, 64)

## Inject a synthetic magnitude provider for headless self-tests (item 9): a Callable(from_hz, to_hz)
## -> float returning the magnitude for that range. This is the node-wired seam that lets an audio test
## drive a KNOWN spectrum with zero live audio. Pass an invalid Callable to clear it (fall back to live).
func set_magnitude_provider(fn: Callable) -> void:
	_provider = fn

## The log-spaced band EDGES (n_bands+1 boundaries from min_hz..max_hz). Public so prim_spectrum_bands /
## a test can align its own binning with the exact ranges this node measured.
func band_edges() -> PackedFloat32Array:
	var n := _n_bands()
	var lo := maxf(1.0, float(params.get("min_hz", 20.0)))
	var hi := maxf(lo + 1.0, float(params.get("max_hz", 20000.0)))
	var log_lo := log(lo)
	var log_hi := log(hi)
	var edges := PackedFloat32Array()
	edges.resize(n + 1)
	for i in range(n + 1):
		var t := float(i) / float(n)
		edges[i] = exp(log_lo + t * (log_hi - log_lo))
	return edges

## Resolve the magnitude provider for this evaluate: the injected synthetic one if set, else a Callable
## reading the live AudioEffectSpectrumAnalyzerInstance on the bus, else an EMPTY Callable (=> zeros).
func _resolve_provider() -> Callable:
	if _provider.is_valid():
		return _provider
	var bus := str(params.get("bus", "VisiSonor"))
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return Callable()
	var inst := AudioServer.get_bus_effect_instance(idx, int(params.get("effect_index", 0)))
	if inst == null or not (inst is AudioEffectSpectrumAnalyzerInstance):
		return Callable()
	# Wrap the live instance's per-range query. AVERAGE mode (0) matches the smoothing we do on top.
	var analyzer := inst as AudioEffectSpectrumAnalyzerInstance
	return func(from_hz: float, to_hz: float) -> float:
		return analyzer.get_magnitude_for_frequency_range(
			from_hz, to_hz, AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_AVERAGE).length()

func evaluate(_inputs: Dictionary) -> Dictionary:
	var n := _n_bands()
	if _ema.size() != n:
		_ema = PackedFloat32Array()
		_ema.resize(n)   # zero-filled
	var provider := _resolve_provider()
	var edges := band_edges()
	var smoothing := clampf(float(params.get("smoothing", 0.6)), 0.0, 0.999)
	var gain := float(params.get("gain", 1.0))
	var normalize := bool(params.get("normalize", true))
	var out := PackedFloat32Array()
	out.resize(n)
	for i in range(n):
		var raw := 0.0
		if provider.is_valid():
			# The analyzer returns a small linear magnitude; scale by gain. A missing provider (no live
			# analyzer, no synthetic) leaves raw=0 -> the declared all-zero no-op (C ideal), never a crash.
			raw = maxf(0.0, provider.call(edges[i], edges[i + 1]) * gain)
		# EMA per band (smoothing*prev + (1-smoothing)*raw) — the jitter fix. prev is last frame's value.
		var v := smoothing * _ema[i] + (1.0 - smoothing) * raw
		if normalize:
			v = clampf(v, 0.0, 1.0)
		_ema[i] = v
		out[i] = v
	return { "bands": out, "n_bands": n }

## Impure: bands depend on the live/synthetic spectrum and on per-band EMA state that advances each
## frame — not a pure function of params. Never memoize (same reasoning as Input/Sensor/AudioSource).
func is_cacheable() -> bool:
	return false
