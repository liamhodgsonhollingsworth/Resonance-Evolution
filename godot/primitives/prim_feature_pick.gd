class_name PrimFeaturePick
extends Primitive
## The FEATURE ROUTER (visi-sonor Slice 1B, item 8) — the node that makes any effect/light REWIREABLE
## to any part of the music. It reads the per-frame band FRAME (the SAME set_input_frame seam PrimInput
## reads) and emits a SINGLE chosen feature float selected by params.feature. "Bind this bar to the
## bass" vs "…to the treble" vs "…to the beat" is a one-param change on THIS node — never an engine edit
## and never a rewire of the downstream effect. That is item-8's generality made concrete: the effect
## subscribes to a feature WIRE, and this node decides which feature that wire carries.
##
## It is a specialised, semantic sibling of PrimInput: where Input takes a raw abstract input_id, this
## takes a FEATURE NAME from the visi-sonor vocabulary and resolves it to the canonical frame key, so an
## arrangement author writes `bass` / `treble` / `beat` (stable names) rather than memorising the
## `signal.band.low` string layout. The feature->key table is DATA (FEATURE_KEYS below); a host that
## injects extra keys just adds a mapping — additive, node-not-edit.
##
## FEATURE VOCABULARY (the item-8 set): sub, bass, lowmid, mid, highmid, treble (the log bands);
##   energy (overall loudness), centroid (spectral brightness), flux (spectral change / onset drive),
##   beat (a 0/1 beat pulse), tempo_phase (0..1 phase within the beat). Absent/unknown = declared no-op.
##
## params:
##   feature      the feature name to route (default "energy"). If it is not in the vocabulary, the node
##                treats it as a RAW frame key (so a host's extra key works), then falls to default.
##   frame_key    OPTIONAL explicit override — read this literal frame key instead of the mapped one.
##   default      emitted when the frame lacks the resolved key (frame absent or key absent). Default 0.0.
##
## input:   (none required) — reads the runtime frame directly, like PrimInput. (An optional `frame`
##          wire is accepted for testability: if a `frame` dict is wired in, it is read INSTEAD of the
##          runtime frame, so a bare-node test can drive it without a mounted runtime — C/T friendly.)
## output:  value — the chosen feature as a plain float (T: plain DATA on the wire).

## The feature-name -> canonical frame-key table. DATA, not code branches — a new feature is a new row.
const FEATURE_KEYS := {
	"sub": "signal.band.sub",
	"bass": "signal.band.low",
	"lowmid": "signal.band.lowmid",
	"mid": "signal.band.mid",
	"highmid": "signal.band.highmid",
	"treble": "signal.band.high",
	"energy": "signal.energy",
	"centroid": "signal.centroid",
	"flux": "signal.flux",
	"beat": "signal.beat",
	"tempo_phase": "signal.tempo_phase",
}

func _init() -> void:
	prim_type = "FeaturePick"

func input_ports() -> Array:
	return [{ "name": "frame", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "value", "type": "number" }]

## Resolve a feature name to its frame key (STATIC so other nodes reuse the same mapping — R ideal).
## An explicit frame_key param wins; a known feature maps through the table; anything else is treated
## as a raw frame key (a host's extra key), so no name is ever a hard error.
static func resolve_key(feature: String, frame_key_override: String) -> String:
	if frame_key_override != "":
		return frame_key_override
	if FEATURE_KEYS.has(feature):
		return String(FEATURE_KEYS[feature])
	return feature   # treat an unknown name as a literal frame key

func evaluate(inputs: Dictionary) -> Dictionary:
	# str() (never String()) coerces a Variant param safely — String() throws on a non-string.
	var feature := str(params.get("feature", "energy"))
	var override := str(params.get("frame_key", ""))
	var key := resolve_key(feature, override)
	var fallback := params.get("default", 0.0)

	# A wired-in `frame` dict takes precedence (testability + composition: a synthetic frame producer
	# can feed this node without a mounted runtime). Otherwise read the runtime's per-frame frame.
	var frame = inputs.get("frame")
	if typeof(frame) != TYPE_DICTIONARY:
		var rt := get_parent()
		if rt != null and rt.has_method("get_input_frame"):
			frame = rt.call("get_input_frame")
	if typeof(frame) == TYPE_DICTIONARY and (frame as Dictionary).has(key):
		return { "value": as_num((frame as Dictionary)[key]) }
	return { "value": as_num(fallback) }

## Impure: depends on the runtime's per-frame frame, not just params. Same posture as PrimInput.
func is_cacheable() -> bool:
	return false
