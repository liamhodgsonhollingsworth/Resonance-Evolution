class_name PrimSpectrumBands
extends Primitive
## The NAMED-BANDS node (visi-sonor arc, Slice 1A) — the tail of the analysis chain
## prim_audio_source -> prim_spectrum -> prim_spectrum_bands -> set_input_frame. It reads the raw
## log-spaced `bands` array (from prim_spectrum) and folds it into NAMED musical bands
## (sub/bass/lowmid/mid/highmid/treble), each 0..1, plus the low/mid/high convenience triple the
## visi-sonor arrangements + the set_input_frame seam already speak (visisonor_loop.json reads
## "signal.band.high"; demo_interactions.gd injects signal.band.low/mid/high). It emits a plain DICT of
## named scalars on a wire (T ideal) — a downstream Input/Sensor(frame) / freq_to_color / device.set_led
## reads whichever named band it wants; nothing is hardwired.
##
## THE BINNING (from the plan): params.band_edges_hz = [20,60,250,2000,6000,20000] defines the six edges
## that carve the raw spectrum into the six named bands. Each named band's value is the MEAN of the raw
## `bands[]` entries whose center frequency falls in that named band's [lo,hi) range (using the same
## log-spaced edges prim_spectrum measured, read off its n_bands + our band_edges). A band with no raw
## entries falls back to a linear interpolation of the nearest raw samples, so a small n_bands still
## yields a defined value for every name (C ideal: always defined, never a divide-by-zero crash).
##
## THE low/mid/high TRIPLE (the seam contract): the existing arrangements use exactly three keys —
## signal.band.low / .mid / .high. We derive them from the six named bands so the SAME injector lights up
## every existing Input/Sensor/BRAIN/device.set_led wired to those keys:
##   low  = max(sub, bass)         — the "is there low-end energy" the LED warm-tint reads.
##   mid  = max(lowmid, mid)       — the mid presence.
##   high = max(highmid, treble)   — the treble/high presence visisonor_loop.json thresholds on.
## (max, not mean, so a strong single sub-band still reads as "low present" — the demo wants presence.)
##
## params:
##   band_edges_hz — the ascending edge list carving the named bands. Default [20,60,250,2000,6000,20000]
##                   (6 edges => the 6 canonical names). If a different-length list is given, the names are
##                   generated positionally (band0..bandN) so the node stays defined for any edge count.
##   min_hz/max_hz — the log range the incoming raw `bands` spans (must match prim_spectrum). Defaults
##                   20 .. 20000. Used to compute each raw band's center frequency for assignment.
##
## inputs:
##   bands   — the raw PackedFloat32Array (or Array) from prim_spectrum. Absent/empty => all named bands
##             0.0 (a declared no-op, C ideal), never a crash.
##   n_bands — (optional) the raw band count. Falls back to bands.size() when unconnected.
##
## outputs:
##   named   — a Dictionary { sub, bass, lowmid, mid, highmid, treble, low, mid, high } of 0..1 scalars.
##   low / mid / high — the three convenience scalars, ALSO surfaced as their own ports so an arrangement
##                      can wire a single named band without unpacking the dict.

const DEFAULT_EDGES := [20.0, 60.0, 250.0, 2000.0, 6000.0, 20000.0]
# The canonical names for the 6-edge default. A non-default edge count generates band0..bandN instead.
const DEFAULT_NAMES := ["sub", "bass", "lowmid", "mid", "highmid", "treble"]

func _init() -> void:
	prim_type = "SpectrumBands"

func input_ports() -> Array:
	return [
		{ "name": "bands", "type": "any" },
		{ "name": "n_bands", "type": "number" },
	]

func output_ports() -> Array:
	return [
		{ "name": "named", "type": "any" },
		{ "name": "low", "type": "number" },
		{ "name": "mid", "type": "number" },
		{ "name": "high", "type": "number" },
	]

## The named-band edge list, coerced to floats. A malformed / too-short list falls back to the default.
func _edges() -> Array:
	var raw = params.get("band_edges_hz", DEFAULT_EDGES)
	if not (raw is Array) or (raw as Array).size() < 2:
		return DEFAULT_EDGES.duplicate()
	var out: Array = []
	for v in raw:
		out.append(float(v))
	return out

## Positional names for the carved bands: the canonical 6 when the default 6-edge list is used, else
## generated band0..bandN so a custom edge count still yields a defined, named dict (C ideal).
func _names_for(count: int) -> Array:
	if count == DEFAULT_NAMES.size():
		return DEFAULT_NAMES.duplicate()
	var out: Array = []
	for i in range(count):
		out.append("band%d" % i)
	return out

func evaluate(inputs: Dictionary) -> Dictionary:
	var bands := _to_floats(inputs.get("bands"))
	var n := bands.size()
	var edges := _edges()
	var name_count := edges.size() - 1
	var names := _names_for(name_count)

	# The log range the raw bands span (must match prim_spectrum's min/max). Each raw band i has a center
	# frequency at the geometric mean of its own log-spaced sub-range — computed the SAME way prim_spectrum
	# lays out its edges, so a raw band lands in exactly one named band.
	var lo := maxf(1.0, float(params.get("min_hz", 20.0)))
	var hi := maxf(lo + 1.0, float(params.get("max_hz", 20000.0)))

	var named := {}
	for k in range(name_count):
		var e_lo := edges[k]
		var e_hi := edges[k + 1]
		named[names[k]] = _mean_in_range(bands, n, lo, hi, e_lo, e_hi)

	# The low/mid/high convenience triple derived from the named bands (see the docstring). Uses max so a
	# strong single band still registers as "present". Falls back gracefully for non-default name sets.
	var low := _presence(named, ["sub", "bass"], bands, n, name_count, 0)
	var mid := _presence(named, ["lowmid", "mid"], bands, n, name_count, 1)
	var high := _presence(named, ["highmid", "treble"], bands, n, name_count, 2)
	named["low"] = low
	named["mid"] = mid
	named["high"] = high

	return { "named": named, "low": low, "mid": mid, "high": high }

# --- helpers -------------------------------------------------------------------------------------

## Coerce the incoming `bands` (a PackedFloat32Array, a plain Array, or null) to a PackedFloat32Array.
## Absent/empty => an empty array (=> every named band 0.0, the declared no-op — C ideal).
func _to_floats(v) -> PackedFloat32Array:
	if v == null:
		return PackedFloat32Array()
	if v is PackedFloat32Array:
		return v
	if v is Array:
		var out := PackedFloat32Array()
		for x in v:
			out.append(float(x))
		return out
	return PackedFloat32Array()

## The center frequency of raw band index i (0..n-1) under the SAME log layout prim_spectrum uses:
## the geometric mean of band i's [edge_i, edge_{i+1}) sub-range over [lo,hi].
func _center_hz(i: int, n: int, lo: float, hi: float) -> float:
	if n <= 0:
		return lo
	var log_lo := log(lo)
	var log_hi := log(hi)
	var t0 := float(i) / float(n)
	var t1 := float(i + 1) / float(n)
	return exp(log_lo + 0.5 * (t0 + t1) * (log_hi - log_lo))

## Mean of the raw bands whose center falls in [e_lo, e_hi). Empty range => interpolate the nearest raw
## sample at the range's geometric-mean center, so a coarse n_bands still gives a defined value (never a
## divide-by-zero — C ideal). Empty input array => 0.0.
func _mean_in_range(bands: PackedFloat32Array, n: int, lo: float, hi: float, e_lo: float, e_hi: float) -> float:
	if n <= 0:
		return 0.0
	var sum := 0.0
	var count := 0
	for i in range(n):
		var c := _center_hz(i, n, lo, hi)
		if c >= e_lo and c < e_hi:
			sum += bands[i]
			count += 1
	if count > 0:
		return clampf(sum / float(count), 0.0, 1.0)
	# no raw band centered in this named range (coarse spectrum): sample the nearest raw band to the
	# named range's own center frequency — a defined fallback, never empty.
	var target := sqrt(e_lo * e_hi)
	var best_i := 0
	var best_d := INF
	for i in range(n):
		var d := absf(_center_hz(i, n, lo, hi) - target)
		if d < best_d:
			best_d = d
			best_i = i
	return clampf(bands[best_i], 0.0, 1.0)

## Presence of a low/mid/high group = max over its member named bands (see the docstring). If the named
## bands were generated positionally (custom edges), fall back to the raw band at `pos_frac` of the array
## so low/mid/high are always defined for any edge set (C ideal).
func _presence(named: Dictionary, members: Array, bands: PackedFloat32Array, n: int, name_count: int, group: int) -> float:
	var v := 0.0
	var found := false
	for m in members:
		if named.has(m):
			v = maxf(v, float(named[m]))
			found = true
	if found:
		return clampf(v, 0.0, 1.0)
	# positional fallback: split the raw array into three thirds; group 0/1/2 = low/mid/high.
	if n <= 0:
		return 0.0
	var start := (group * n) / 3
	var stop := ((group + 1) * n) / 3
	if stop <= start:
		stop = start + 1
	var mx := 0.0
	for i in range(start, mini(stop, n)):
		mx = maxf(mx, bands[i])
	return clampf(mx, 0.0, 1.0)

## Impure: outputs depend on the wired `bands` input which advances with the live spectrum. The
## per-evaluate mapping itself is pure, but the input is time-varying, so opting out of memoization
## keeps it consistent with the rest of the analysis chain (and avoids a stale cached band dict).
func is_cacheable() -> bool:
	return false
