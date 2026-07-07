class_name PrimFreqToColor
extends Primitive
## FREQUENCY -> COLOUR (visi-sonor Slice 1B, item 6) — maps a band balance to an {r,g,b,addr} colour
## ready to ride the device.set_led `value` seam (DeviceActions._op_set_led reads exactly this shape).
## The spec ask verbatim: BASS -> WARM colours, TREBLE -> COOL colours, on a continuous ramp (not the
## binary warm/cool Select the slice5 arrangement uses). Brightness comes from amplitude, so a loud
## frame glows and a quiet frame dims.
##
## PALETTE BY HANDLE (system_criteria single-palette rule): the warm & cool endpoints are NOT hardcoded
## per-node — they are looked up from ONE relinkable palette table by params.palette (a handle string).
## Re-skin every freq->colour node in the show by pointing them at a different handle; the DEFAULT
## handle's endpoints match the existing visisonor_loop.json warm/cool constants so the demo is
## visually continuous. A host can register_palette(handle, warm, cool) additively (node-not-edit).
##
## Renderer-NEUTRAL DATA (T ideal): output is a plain {r,g,b,addr} dict of floats — no Godot Color, no
## fixture object — so it wires to device.set_led OR to a screen effect's colour port identically (item 8).
##
## modes:
##   "warm_cool_ramp" (default) — t = treble/(bass+treble) in 0..1 (0=all bass, 1=all treble); lerp the
##                    palette's warm endpoint (t=0) to its cool endpoint (t=1). value_from=amplitude
##                    scales brightness by the total band energy (bass+treble), clamped.
##   "pitch_class"    — an alternate: a hue derived from a 0..1 `pitch` input (a chromatic position),
##                    saturation/value from amplitude. The 12-tone colour-wheel alternate to the ramp.
##
## params:
##   mode        "warm_cool_ramp" | "pitch_class"     (default "warm_cool_ramp")
##   palette     the palette handle                    (default "default")
##   threshold   band level below which a channel is treated as silence when forming t (default 0.0)
##   ramp        exponent shaping the ramp position t  (default 1.0 = linear; >1 pushes toward warm)
##   saturation  0..1 colour saturation                (default 1.0)
##   value_from  "amplitude" | "fixed"                 (default "amplitude"); "fixed" => full brightness
##   addr        the LED index echoed into the colour  (default 0)
##
## inputs:
##   bass, treble — the two band energies (0..1) for warm_cool_ramp. (Unconnected = 0 -> defined color, C.)
##   pitch        — a 0..1 chromatic position for pitch_class mode.
##   amplitude    — optional explicit brightness 0..1; if unconnected, derived from bass+treble.
## output:
##   value — { r, g, b, addr } floats 0..1 (the device.set_led payload shape).

## ONE relinkable palette table: handle -> { warm:[r,g,b], cool:[r,g,b] }. DATA, additive via
## register_palette. The "default" endpoints match visisonor_loop.json (warm [1,0.2,0], cool [0,0.2,1]).
const PALETTES := {
	"default": { "warm": [1.0, 0.2, 0.0], "cool": [0.0, 0.2, 1.0] },
	"ember_ice": { "warm": [1.0, 0.35, 0.05], "cool": [0.1, 0.35, 1.0] },
	"sodium_neon": { "warm": [1.0, 0.55, 0.1], "cool": [0.2, 0.9, 1.0] },
}

# Per-instance palette overrides a host may register (node-not-edit; empty by default).
var _palettes: Dictionary = {}

func _init() -> void:
	prim_type = "FreqToColor"

func input_ports() -> Array:
	return [
		{ "name": "bass", "type": "number" },
		{ "name": "treble", "type": "number" },
		{ "name": "pitch", "type": "number" },
		{ "name": "amplitude", "type": "number" },
	]

func output_ports() -> Array:
	return [{ "name": "value", "type": "color" }]

## Register (or replace) a palette on THIS node — the whole extension surface (add a colour scheme = one
## call, never an engine edit). Symmetric with WorldActions/CompareDiff per-instance registries.
func register_palette(handle: String, warm: Array, cool: Array) -> void:
	if handle == "":
		return
	_palettes[handle] = { "warm": warm, "cool": cool }

## Resolve a palette handle -> { warm:[r,g,b], cool:[r,g,b] }. An unknown handle falls to "default"
## (a declared no-op-shaped fallback, never a crash — C ideal).
func _resolve_palette(handle: String) -> Dictionary:
	if _palettes.has(handle):
		return _palettes[handle]
	if PALETTES.has(handle):
		return PALETTES[handle]
	return PALETTES["default"]

func evaluate(inputs: Dictionary) -> Dictionary:
	var mode := str(params.get("mode", "warm_cool_ramp"))
	var pal := _resolve_palette(str(params.get("palette", "default")))
	var sat: float = clamp(float(params.get("saturation", 1.0)), 0.0, 1.0)
	var addr := int(as_num(params.get("addr", 0)))
	var value_from := str(params.get("value_from", "amplitude"))

	if mode == "pitch_class":
		return { "value": _pitch_class(inputs, sat, addr, value_from) }
	return { "value": _warm_cool_ramp(inputs, pal, sat, addr, value_from) }

# warm_cool_ramp: t = treble share of (bass+treble); lerp warm->cool; brightness from amplitude.
func _warm_cool_ramp(inputs: Dictionary, pal: Dictionary, sat: float, addr: int, value_from: String) -> Dictionary:
	var bass := as_num(inputs.get("bass"))
	var treble := as_num(inputs.get("treble"))
	var thr := float(params.get("threshold", 0.0))
	# Apply the silence threshold: sub-threshold band energy does not pull the ramp.
	var b := max(0.0, bass - thr)
	var t := max(0.0, treble - thr)
	var total := b + t
	var pos := 0.5   # a balanced (no-signal) frame sits mid-ramp rather than snapping to an endpoint
	if total > 0.0:
		pos = t / total
	# ramp exponent shapes the position (>1 biases toward warm / the low end).
	var ramp := float(params.get("ramp", 1.0))
	if ramp <= 0.0:
		ramp = 1.0
	pos = pow(clamp(pos, 0.0, 1.0), ramp)

	var warm: Array = pal.get("warm", [1.0, 0.2, 0.0])
	var cool: Array = pal.get("cool", [0.0, 0.2, 1.0])
	var r := lerp(float(warm[0]), float(cool[0]), pos)
	var g := lerp(float(warm[1]), float(cool[1]), pos)
	var bl := lerp(float(warm[2]), float(cool[2]), pos)

	# Saturation: desaturate toward the channel-average grey.
	if sat < 1.0:
		var grey := (r + g + bl) / 3.0
		r = lerp(grey, r, sat); g = lerp(grey, g, sat); bl = lerp(grey, bl, sat)

	# Brightness: value_from=amplitude scales by total band energy (louder = brighter). "fixed" = full.
	var bright := 1.0
	if value_from == "amplitude":
		var amp = inputs.get("amplitude")
		bright = clamp(as_num(amp) if amp != null else clamp(bass + treble, 0.0, 1.0), 0.0, 1.0)
	r *= bright; g *= bright; bl *= bright
	return { "r": r, "g": g, "b": bl, "addr": addr }

# pitch_class: hue from a 0..1 chromatic position; sat/value from amplitude. The colour-wheel alternate.
func _pitch_class(inputs: Dictionary, sat: float, addr: int, value_from: String) -> Dictionary:
	var pitch: float = clamp(as_num(inputs.get("pitch")), 0.0, 1.0)
	var bright := 1.0
	if value_from == "amplitude":
		var amp = inputs.get("amplitude")
		bright = clamp(as_num(amp) if amp != null else 1.0, 0.0, 1.0)
	var col := Color.from_hsv(pitch, sat, bright)
	return { "r": col.r, "g": col.g, "b": col.b, "addr": addr }

## Pure: colour is a deterministic function of inputs + params, no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
