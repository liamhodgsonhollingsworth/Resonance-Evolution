class_name PrimSizeSortBind
extends Primitive
## SIZE -> FREQUENCY auto-binder (visi-sonor Slice 1B, item 6) — assigns each fixture to a frequency
## band BY ITS SIZE, monotonically: the BIG fixtures (a floor lamp, a large panel) take the LOW bands
## (bass — the body you feel), the SMALL fixtures (LED pixels, accent strips) take the HIGH bands
## (treble — the sparkle). It emits a table of {fixture -> band} bindings as DATA; the actual drive is
## the downstream arrangement (each binding's band_key feeds a FeaturePick/Input -> ParamBind ->
## device.set_led), so this node just DECIDES the mapping — it holds no fixtures and drives no hardware.
##
## The mapping is a monotone rank match: sort fixtures by size, sort the bands low->high, and pair rank
## for rank. So it stays correct for any fixture count vs band count (spreads fixtures across the bands
## by quantised rank). ascending=true (default) is the spec's big->low; ascending=false flips it (big->high)
## — a one-param inversion, the "swap which fixture binds to which band" knob the demo exposes (item 8).
##
## params:
##   sizes       Array of fixture sizes (floats). May also arrive on the `sizes` input wire (wire wins).
##   band_keys   Array of frame keys low->high (default the 6 log bands sub..high). The bands to bind to.
##   ascending   bool — true => BIG fixture -> LOW band (bass); false => big -> high band. (default true)
##
## input:   sizes — OPTIONAL Array of fixture sizes; if wired, overrides params.sizes (a live size feed).
## output:  bindings — Array of { index, size, band, band_key } (one per fixture), where `band` is the
##                     integer band index (0=lowest) and `band_key` is that band's frame key. Plain DATA (T).

## The default log-spaced band keys, low -> high (matches the audio pipeline's named bands).
const DEFAULT_BAND_KEYS := [
	"signal.band.sub", "signal.band.low", "signal.band.lowmid",
	"signal.band.mid", "signal.band.highmid", "signal.band.high",
]

func _init() -> void:
	prim_type = "SizeSortBind"

func input_ports() -> Array:
	return [{ "name": "sizes", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "bindings", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	# Sizes: a wired-in array wins (live feed), else params.sizes. Absent/empty -> no bindings (C: a
	# defined empty result, never a crash).
	var sizes_in = inputs.get("sizes")
	var sizes: Array = []
	if sizes_in is Array:
		sizes = (sizes_in as Array).duplicate()
	elif params.get("sizes") is Array:
		sizes = (params.get("sizes") as Array).duplicate()
	if sizes.is_empty():
		return { "bindings": [] }

	var band_keys: Array = params.get("band_keys", DEFAULT_BAND_KEYS)
	if not (band_keys is Array) or (band_keys as Array).is_empty():
		band_keys = DEFAULT_BAND_KEYS
	var n_bands := band_keys.size()
	var ascending := bool(params.get("ascending", true))

	# Rank the fixtures by size, LARGEST first (rank 0 = biggest). Keep the original index so the caller
	# can wire binding[i] back to fixture i. A stable sort on (size desc, index asc) is deterministic.
	var order := []
	for i in range(sizes.size()):
		order.append({ "index": i, "size": float(sizes[i]) })
	order.sort_custom(func(a, b):
		if a["size"] == b["size"]:
			return int(a["index"]) < int(b["index"])
		return float(a["size"]) > float(b["size"]))

	# Map rank -> band index. rank 0 (biggest) -> band 0 (lowest) when ascending. Quantise rank across
	# the available bands so any fixture-count vs band-count spreads monotonically.
	var bindings := []
	var n_fix := order.size()
	for rank in range(n_fix):
		var band := 0
		if n_fix == 1:
			band = 0
		else:
			# even spread of ranks across bands: rank 0 -> band 0, last rank -> band n_bands-1.
			band = int(round(float(rank) * float(n_bands - 1) / float(n_fix - 1)))
		band = clamp(band, 0, n_bands - 1)
		if not ascending:
			band = (n_bands - 1) - band   # flip: biggest -> highest band
		var entry: Dictionary = order[rank]
		bindings.append({
			"index": int(entry["index"]),
			"size": float(entry["size"]),
			"band": band,
			"band_key": str(band_keys[band]),
		})
	# Emit in original fixture-index order for a stable, wire-friendly table.
	bindings.sort_custom(func(a, b): return int(a["index"]) < int(b["index"]))
	return { "bindings": bindings }

## Pure: bindings are a deterministic function of (sizes, band_keys, ascending). Safe to memoize.
func is_cacheable() -> bool:
	return true
