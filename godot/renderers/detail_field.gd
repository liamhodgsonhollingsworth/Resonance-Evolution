class_name DetailField
extends RefCounted
## The GENERIC DETAIL FIELD — a per-region "how much detail here?" scalar, driven by ONE knob and a
## generic FALLOFF CURVE, as renderer-neutral DATA. This is the concrete first cut of Liam's spec
## (project-generic-detail-falloff-2026-07-01) and the seam the Truncate node + foveation + LOD all
## consume: a single `detail_knob` sets the field's overall budget, a `falloff` curve says how that
## budget varies across the frame, and the produced field is a plain [0..1] scalar every downstream
## algorithm reads — the field is ALGORITHM-AGNOSTIC (it only tells each region its budget; the
## painterly applier, an LOD selector, a procgen density, all consume the same numbers).
##
## THE SPEC, made explicit:
##   detail(x, y) = clampf(detail_knob * falloff(x, y), 0, 1)
## where `detail_knob` ∈ [0..1] is the single slider, and `falloff(x, y)` ∈ [0..1] is a generic curve
## chosen by DATA (not a hardcoded disc). Provided falloff curves (each a `{type, ...params}` dict):
##   "uniform"    — falloff ≡ 1 everywhere (the field is just the knob; detail is flat over the frame).
##   "radial"     — 1 at a center point, falling to `edge` at radius `radius` (normalized 0..1 of the
##                  half-diagonal), by `curve` (the exponent; 1 = linear, 2 = quadratic ...). The
##                  foveation fovea generalized: center is DATA, so the high-detail region can be
##                  anywhere (later wired to gaze). params: center:[cx,cy] (0..1 UV, default [0.5,0.5]),
##                  radius:float (default 0.9), edge:float (the floor at/after radius, default 0.15),
##                  curve:float (default 2.0).
##   "vertical"   — a top-to-bottom ramp: `top` at y=0 to `bottom` at y=1 (or vice-versa), by `curve`.
##                  params: top:float (default 1.0), bottom:float (default 0.15), curve:float (default 1.0).
##   "horizontal" — a left-to-right ramp: `left` at x=0 to `right` at x=1, by `curve`. Same param shape
##                  as vertical with left/right.
## Unknown / missing `type` degrades to "uniform" (never a crash) — a field authored against a richer
## curve set still produces a valid flat field here.
##
## It is pure DATA in (knob + curve descriptor + size) → pure numbers out (a flat PackedFloat32Array,
## row-major w*h, values in [0..1]); no Image, no shader, no Godot node on the wire — so the same field
## drives the CPU painterly applier here, a GPU delegate later, or a three.js consumer, unchanged
## (the portability invariant every module in this engine holds).

## Build the detail field for a `width`×`height` frame from a single `detail_knob` and a `falloff`
## curve descriptor. Returns a row-major PackedFloat32Array of length width*height, each value the
## clamped [0..1] detail budget for that pixel. The one function the whole spec reduces to.
static func build(width: int, height: int, detail_knob: float, falloff: Dictionary) -> PackedFloat32Array:
	width = maxi(1, width)
	height = maxi(1, height)
	var knob := clampf(detail_knob, 0.0, 1.0)
	var out := PackedFloat32Array()
	out.resize(width * height)
	var i := 0
	for y in height:
		# Normalized 0..1 vertical coordinate (0 = top row, 1 = bottom row).
		var v := float(y) / float(maxi(1, height - 1))
		for x in width:
			var u := float(x) / float(maxi(1, width - 1))
			out[i] = clampf(knob * _falloff_at(u, v, falloff), 0.0, 1.0)
			i += 1
	return out

## The generic falloff curve evaluated at UV (u,v) ∈ [0..1]², returning a [0..1] weight. This is the
## single point new curves are added (each a new branch) — the field/applier never change, exactly the
## no-auto-generalization seam the effect registry holds: a new curve teaches the whole system at once.
static func _falloff_at(u: float, v: float, falloff: Dictionary) -> float:
	match String(falloff.get("type", "uniform")):
		"uniform":
			return 1.0
		"radial":
			return _radial(u, v, falloff)
		"vertical":
			return _ramp(v, float(falloff.get("top", 1.0)), float(falloff.get("bottom", 0.15)),
				float(falloff.get("curve", 1.0)))
		"horizontal":
			return _ramp(u, float(falloff.get("left", 1.0)), float(falloff.get("right", 0.15)),
				float(falloff.get("curve", 1.0)))
		_:
			# Unknown curve → uniform (a field authored against a richer set still produces a valid frame).
			return 1.0

## Radial falloff: 1 at `center`, decaying to `edge` at `radius` (a fraction of the half-diagonal), by
## an exponent `curve`. Distances beyond `radius` clamp to `edge` (a flat periphery, the fovea floor).
static func _radial(u: float, v: float, p: Dictionary) -> float:
	var center = p.get("center", [0.5, 0.5])
	var cx := 0.5
	var cy := 0.5
	if typeof(center) == TYPE_ARRAY and center.size() >= 2:
		cx = float(center[0])
		cy = float(center[1])
	var radius: float = max(0.0001, float(p.get("radius", 0.9)))
	var edge := clampf(float(p.get("edge", 0.15)), 0.0, 1.0)
	var curve: float = max(0.0001, float(p.get("curve", 2.0)))
	# Distance in UV space normalized by the half-diagonal so radius is resolution-independent.
	var dx := u - cx
	var dy := v - cy
	var dist := sqrt(dx * dx + dy * dy) / 0.70710678  # /sqrt(0.5) == the UV half-diagonal
	var t := clampf(dist / radius, 0.0, 1.0)          # 0 at center, 1 at/after radius
	# Ease from 1 (center) toward `edge` (periphery) by the curve exponent.
	return lerpf(1.0, edge, pow(t, curve))

## A directional ramp from `a` (at coord 0) to `b` (at coord 1), eased by an exponent `curve`.
static func _ramp(coord: float, a: float, b: float, curve: float) -> float:
	var t := clampf(coord, 0.0, 1.0)
	curve = max(0.0001, curve)
	return lerpf(clampf(a, 0.0, 1.0), clampf(b, 0.0, 1.0), pow(t, curve))

## Convenience: the field as a grayscale Image (detail as luminance) — a DEBUG/visualization view of
## the budget map, so a proof shot can show the falloff itself beside the painted frame. Not on any
## data path (the field is the PackedFloat32Array); this is only for human-facing proof imagery.
static func to_debug_image(field: PackedFloat32Array, width: int, height: int) -> Image:
	var img := Image.create(maxi(1, width), maxi(1, height), false, Image.FORMAT_RGBAF)
	var i := 0
	for y in height:
		for x in width:
			var d := field[i] if i < field.size() else 0.0
			img.set_pixel(x, y, Color(d, d, d, 1.0))
			i += 1
	return img


## ---------------------------------------------------------------------------------------------
## TRUNCATE/LOD UNIFICATION (GZ-RENDER.5, Wave 1 item 1.2 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5). ADDITIVE to the field above — the
## `build()`/`_falloff_at()` seam is unchanged; this is the "Truncate node + LOD" consumer the file's
## own header comment names as sharing the field.
##
## A camera-distance-driven near/far swap: NEAR = real instanced geometry (the caller's
## MultiMeshInstance3D tier), FAR = a baked static texture/impostor. The swap is wired through the
## SAME [0..1] detail budget `build()` produces: a high-detail region (fovea center, or any region a
## scene's falloff curve prioritizes) keeps its real geometry out to a LONGER camera distance than a
## low-detail/periphery region, which swaps to the cheap impostor sooner — one knob, one curve,
## budgets BOTH the painterly detail (existing) and the geometry LOD tier (new).
##
## Threshold + hysteresis are both tunables, per the spec text. Hysteresis matters because a
## distance-only cutoff pops (an item oscillating around the boundary swaps every frame); it is
## applied as a dead-zone fraction on the "swap away from the current tier" side only, so
## `lod_tier_for` is a proper state machine (it takes the item's CURRENT tier as an input), not a
## stateless distance→tier map. Pure DATA in, pure DATA out — no Image, no shader, no scene-tree
## dependency — same portability invariant as the rest of this file (this is a DECISION the caller
## acts on by instancing/freeing its own MultiMeshInstance3D / impostor node; it never touches one).

const LOD_NEAR := 0  # real instanced geometry tier
const LOD_FAR := 1   # baked static texture/impostor tier

## Decide the LOD tier for ONE item this frame.
##   distance      — camera-to-item distance (world units, clamped >= 0).
##   detail        — the [0..1] detail budget for this item's region (read from a `build()` field at
##                    the item's screen/world position, or pass 1.0 for plain distance-only LOD with
##                    no field wired in).
##   current_tier  — the tier this item rendered as last frame (LOD_NEAR or LOD_FAR); pass LOD_FAR
##                    for a never-seen item (first appearance starts far — the cheap default).
##   near_distance — the near/far threshold AT full detail budget (detail == 1.0): closer than this
##                    swaps to NEAR. Clamped to a small positive minimum.
##   hysteresis    — a fraction (0..1, clamped) of the effective boundary added as a one-sided dead
##                    zone: swapping NEAR→FAR requires being that much FARTHER out than swapping
##                    FAR→NEAR requires being close in, so an item sitting near the boundary does not
##                    thrash every frame.
## Returns LOD_NEAR or LOD_FAR.
static func lod_tier_for(distance: float, detail: float, current_tier: int,
		near_distance: float, hysteresis: float = 0.15) -> int:
	distance = maxf(0.0, distance)
	var d := clampf(detail, 0.0, 1.0)
	near_distance = maxf(0.0001, near_distance)
	hysteresis = clampf(hysteresis, 0.0, 1.0)
	# Higher detail budget -> the effective boundary sits FARTHER out (a high-priority/fovea-center
	# item keeps real geometry longer); detail == 0 collapses the boundary toward 0 (near-immediate
	# swap to the impostor); detail == 1 uses the full near_distance.
	var boundary := near_distance * maxf(0.0001, d)
	var margin := boundary * hysteresis
	if current_tier == LOD_NEAR:
		return LOD_FAR if distance > boundary + margin else LOD_NEAR
	return LOD_NEAR if distance < boundary - margin else LOD_FAR


## Per-item LOD tracker: wraps `lod_tier_for()` with PERSISTENT per-item tier state across frames, so
## a renderer calls `update(item_id, ...)` once per item per frame and gets back its current tier plus
## whether THIS call is a swap — the caller's cue to actually instantiate the near-tier geometry / free
## it in favor of the far-tier impostor, rather than doing that work every frame. Keyed the same way
## ChunkLifecycleManager (this engine's sibling Wave-1 shared primitive) keys chunks — a plain
## Dictionary, any hashable Variant as the item id, no scene-tree dependency.
class DetailLODTracker:
	var _tier: Dictionary = {}  # item_id -> LOD_NEAR/LOD_FAR, current tier

	## Decide (and commit) `item_id`'s tier for the current frame. Returns a Dictionary:
	##   {"tier": int, "swapped": bool, "previous_tier": int}
	## `swapped` is true exactly on the frame the tier changes.
	func update(item_id, distance: float, detail: float, near_distance: float,
			hysteresis: float = 0.15) -> Dictionary:
		var prev: int = _tier.get(item_id, DetailField.LOD_FAR)  # unseen -> FAR (cheap default)
		var tier: int = DetailField.lod_tier_for(distance, detail, prev, near_distance, hysteresis)
		_tier[item_id] = tier
		return {"tier": tier, "swapped": tier != prev, "previous_tier": prev}

	## The tier currently recorded for `item_id` (LOD_FAR if never seen — the safe/cheap default).
	func tier_of(item_id) -> int:
		return _tier.get(item_id, DetailField.LOD_FAR)

	## Forget an item (e.g. it despawned via ChunkLifecycleManager) so it starts FAR again if it
	## reappears, rather than resuming stale hysteresis state from its previous lifetime.
	func forget(item_id) -> void:
		_tier.erase(item_id)
