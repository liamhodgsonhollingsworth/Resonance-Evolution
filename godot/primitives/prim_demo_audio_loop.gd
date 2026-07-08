class_name PrimDemoAudioLoop
extends Primitive
## The DEMO-LOOP synthetic audio source (visi-sonor light-show Slice 2B, item 7) — AND the headless
## self-test fixture (item 9). One node, two mandates: it emits a KNOWN synthetic spectrum (a canned kick
## drum on the beat + a slow frequency sweep) into the SAME frame-key seam the live analyzer fills
## (signal.band.low/mid/high + signal.energy), so every effects-menu tile can preview a reaction with
## ZERO live audio and zero hardware — the "demo loop" the menu plays when there is no song, and the
## deterministic fixture every audio/effect test drives.
##
## WHY SYNTHETIC-INTO-THE-SAME-SEAM: the live path is prim_audio_source -> prim_spectrum ->
## prim_spectrum_bands -> set_input_frame({signal.band.*}). This node produces the SAME frame dict directly
## from a closed-form function of time, so a demo tile and a live tile are the SAME downstream graph — only
## the frame SOURCE differs (that switch is prim_audio_route_switch). No un-specced source is wired; this is
## a self-contained generator (T ideal: plain float DATA on the wire; C ideal: always defined).
##
## THE SYNTHETIC SPECTRUM (deterministic in t, values in [0,1]):
##   • KICK: a 4-on-the-floor kick at params.bpm. Each beat fires a transient that DECAYS exponentially,
##     dumping energy into the LOW band (a real kick is low-frequency). On the beat the low band is strong;
##     between beats it has decayed. This gives the pulsing "bass on the beat" every visualizer wants.
##   • SWEEP: a slow sinusoidal sweep moves a band of energy up and down the spectrum over params.sweep_secs,
##     so the MID and HIGH bands rise and fall over time (the "frequency content changes" a bars/waveform
##     effect visualizes). The sweep is what makes a static demo tile look alive.
##   • ENERGY: overall loudness = a blend of the kick + sweep magnitudes.
##
## params:
##   bpm         beat tempo (default 120 => a beat every 0.5 s). The kick fires once per beat.
##   sweep_secs  the sweep period in seconds (default 8) — how long the sweep takes to traverse the spectrum.
##   kick_decay  the kick transient's exponential decay time-constant in seconds (default 0.12) — how fast
##               the low-band pulse falls between beats.
##   loop_secs   OPTIONAL loop length; when > 0 the time is wrapped (t mod loop_secs) so the demo repeats.
##
## inputs:
##   t   the current time in seconds (a wired clock, e.g. a Tick, or the test drives it directly). Absent =>
##       read the runtime's frame time if available, else 0.0 (a defined no-op frame — C ideal).
##
## outputs:
##   frame   the synthetic frame dict on the seam keys { signal.band.low/mid/high, signal.energy } — the
##           SAME shape set_input_frame takes, so it drops straight into the live seam (T ideal).
##   low / mid / high   the three convenience scalars, also on their own ports (mirror the frame).

const DEFAULT_BPM := 120.0
const DEFAULT_SWEEP_SECS := 8.0
const DEFAULT_KICK_DECAY := 0.12

func _init() -> void:
	prim_type = "DemoAudioLoop"

func input_ports() -> Array:
	return [ { "name": "t", "type": "number" } ]

func output_ports() -> Array:
	return [
		{ "name": "frame", "type": "any" },
		{ "name": "low", "type": "number" },
		{ "name": "mid", "type": "number" },
		{ "name": "high", "type": "number" },
	]

func evaluate(inputs: Dictionary) -> Dictionary:
	var t := _time(inputs)

	var bpm := maxf(1.0, float(params.get("bpm", DEFAULT_BPM)))
	var beat_secs := 60.0 / bpm
	var sweep_secs := maxf(0.1, float(params.get("sweep_secs", DEFAULT_SWEEP_SECS)))
	var kick_decay := maxf(0.001, float(params.get("kick_decay", DEFAULT_KICK_DECAY)))
	var loop_secs := float(params.get("loop_secs", 0.0))
	if loop_secs > 0.0:
		t = fposmod(t, loop_secs)

	# --- KICK: exponential-decay transient once per beat, dumped into the LOW band. --------------------
	# Time since the most recent beat onset. On the beat (phase 0) the transient is 1.0; it decays with
	# time-constant kick_decay so between beats it falls toward 0 — the pulsing bass a visualizer reads.
	var time_since_beat := fposmod(t, beat_secs)
	var kick := exp(-time_since_beat / kick_decay)   # 1.0 on the beat, ~0 between beats

	# --- SWEEP: a band of energy travels up/down the spectrum over sweep_secs. ------------------------
	# sweep_pos in [0,1] is the spectral position of the sweep's peak (0 = low, 1 = high). A raised-cosine
	# window over sweep_pos gives each band its share as the sweep passes through it.
	var sweep_pos := 0.5 + 0.5 * sin(TAU * t / sweep_secs)   # 0..1, smooth
	# Each named band's spectral center (low≈0.1, mid≈0.5, high≈0.9) — how close the sweep peak is to it.
	var sweep_low := _sweep_gain(sweep_pos, 0.12)
	var sweep_mid := _sweep_gain(sweep_pos, 0.5)
	var sweep_high := _sweep_gain(sweep_pos, 0.9)

	# --- BAND MIX: the kick is a LOW-band event; the sweep colours all three. -------------------------
	# low = the kick pulse (dominant) plus the sweep's low share. mid/high = the sweep only. Clamp to [0,1].
	var low := clampf(0.85 * kick + 0.25 * sweep_low, 0.0, 1.0)
	var mid := clampf(0.15 * kick + 0.75 * sweep_mid, 0.0, 1.0)
	var high := clampf(0.85 * sweep_high, 0.0, 1.0)
	var energy := clampf(0.5 * low + 0.3 * mid + 0.2 * high, 0.0, 1.0)

	var frame := {
		"signal.band.low": low,
		"signal.band.mid": mid,
		"signal.band.high": high,
		"signal.energy": energy,
	}
	return { "frame": frame, "low": low, "mid": mid, "high": high }

# --- helpers ---------------------------------------------------------------------------------------

## The current time in seconds: a wired `t` wins; else the runtime's frame time if the parent exposes one;
## else 0.0 (a defined no-op — C ideal, never a crash on a missing clock).
func _time(inputs: Dictionary) -> float:
	var tv = inputs.get("t")
	if tv != null:
		return as_num(tv)
	var rt := get_parent()
	if rt != null and rt.has_method("get_input_frame"):
		var f = rt.call("get_input_frame")
		if f is Dictionary and (f as Dictionary).has("time.seconds"):
			return as_num((f as Dictionary)["time.seconds"])
	return 0.0

## A raised-cosine gain in [0,1]: how much a band at spectral position `center` gets when the sweep peak is
## at `sweep_pos`. Width 0.35 so adjacent bands overlap smoothly (the sweep "passes through" each band).
func _sweep_gain(sweep_pos: float, center: float) -> float:
	var d := absf(sweep_pos - center)
	var width := 0.35
	if d >= width:
		return 0.0
	# raised cosine: 1 at d=0, 0 at d=width.
	return 0.5 * (1.0 + cos(PI * d / width))

## Impure: the output depends on the wired time (and optionally the runtime clock), not just params.
func is_cacheable() -> bool:
	return false
