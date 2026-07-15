class_name TerrainGenerator
extends RefCounted
## Terrain / heightfield Generator method — P0 item 0.1 of
## notes/planning/evolving_scene_generator_plan_2026_07_08.md §6.1/§13 (Wavelet repo, PR #815).
## A NEW Generator-family METHOD (Seed+params -> content DATA), never an edit to any existing
## primitive's internals (TOP IDEAL): before this file, `grep` found no terrain/heightmap/noise
## generator anywhere in the engine (plan §5 "Gap confirmed"); this is that genuinely-new work.
##
## I/O (matches plan §6.1 exactly): in = {seed, octaves, lacunarity, gain, warp, erosion:{method,
## strength, iterations, seed}, width, depth, cell_size, amplitude, detail_knob, falloff}; out =
## a heightfield (PackedFloat32Array, pure DATA) + a ground Mesh (-> GLB via GltfExporter, the
## SAME export_mesh_to_file() entry point RingScaffoldGenerator already uses for a raw-Mesh
## producer that never goes through GraphRuntime's scene_node descriptors) + a Constraint Field
## (slope / height / moisture / biome_id, each a flat PackedFloat32Array in [0..1] — "everything
## over space is a function", the maximal-compatibility law: any downstream consumer reads the
## same numbers regardless of who produced them).
##
## ── TUTORIAL GROUNDING (plan §7.3 — the "follow-tutorial" half of the pipeline's own name) ──────
## Two named, cited techniques are FREE-RECREATED here, not invented from scratch:
##   1. Multi-octave fBm value noise — the SAME integer-hash noise family already shipping in this
##      engine (`clouds.gd._fbm/_value_noise/_hash01`, reused a second time by
##      `effect_stack_cpu.gd`'s paper_grain; both files document it as "the portability invariant
##      every module here holds"). Reproduced bit-identically here (RefCounted statics cannot call
##      another class's private members — the SAME reason clouds.gd's own header gives for keeping
##      its copy local), generalized with configurable lacunarity/gain/domain-warp per the plan's
##      literal terrain I/O spec ("seed, octaves, lacunarity, gain, warp").
##   2. `normal_detail` erosion (the default + only method built this pass) — kollapse3d's
##      "Fast & Gorgeous Erosion Filter Explained" (YouTube id `r4V21_uUK8Y`, plan §7.3): a Blender
##      node group that FAKES erosion procedurally from surface-NORMAL information + math in <1s —
##      not a physical sim. The technique (not the paid node-group product — free to replicate,
##      only the packaged .blend asset is paid) is recreated as: recompute each cell's local slope
##      from the fBm heightfield's own central-difference gradient, then redistribute height from
##      steep/convex cells toward flatter/concave neighbors proportional to that slope (a talus-like
##      diffusion driven purely by the normal/gradient, exactly kollapse3d's "erosion from normal
##      info" framing) — `strength`/`iterations`/`rounding` are the tutorial's own named knobs.
##   `hydraulic` / `thermal` / `import_heightmap` (plan §7.3's "broader, optional, evolvable" list)
##   are named but NOT implemented this pass — no-auto-generalization: ship `normal_detail` for
##   real, defer the rest to an explicit follow-up rather than half-building four erosion methods.
##
## ── SCALE-INVARIANT DETAIL (plan §4 — "scale = truncation depth") ────────────────────────────────
## Octave count is driven by the EXISTING `DetailField.build()` seam (renderers/detail_field.gd),
## unchanged/unedited: a `base_octaves` term is summed EVERYWHERE (the far/coarse truncation), and
## `extra_octaves` additional high-frequency terms are cross-FADED in per-cell by that cell's own
## [0..1] detail budget (continuous lerp, never a hard octave-count switch — plan's own FM-4 fix,
## "cross-fade octaves, not hard-switch", so LOD never pops). This literally IS "a truncated
## recursive sum of finer-and-finer detail, cut off at a continuously sliding depth" — the plan's
## canonical model — realized for the terrain generator specifically, not a new LOD mechanism.
##
## ── DETERMINISM (plan §12 FM-4 invariant) ─────────────────────────────────────────────────────────
## `child_seed(parent_seed, tile_x, tile_y)` derives any downstream seed (a future tile, a
## constraint-field noise channel, an erosion pass) from ONE parent seed by integer hash — never a
## fresh `randi()` — so two runs of the same params always produce the same terrain, byte for byte
## (required for the zoom-consistency + reproducible-scatter promises this generator feeds).

const DEFAULT_WIDTH := 33          # grid vertices along X (odd sizes read as "N cells + 1" cleanly)
const DEFAULT_DEPTH := 33          # grid vertices along Z
const DEFAULT_CELL_SIZE := 1.0     # world units per grid step
const DEFAULT_AMPLITUDE := 6.0     # world-unit height range the normalized fBm is scaled into
const DEFAULT_BASE_OCTAVES := 3    # far/coarse truncation term — summed everywhere
const DEFAULT_EXTRA_OCTAVES := 3   # near/fine terms — cross-faded in by the detail budget
const DEFAULT_LACUNARITY := 2.0
const DEFAULT_GAIN := 0.5
const DEFAULT_WARP := 0.0
const DEFAULT_SEED := 0
const DEFAULT_NOISE_SCALE := 0.12  # fBm sample frequency (grid-units -> noise-space)
const DEFAULT_EROSION_METHOD := "normal_detail"
const DEFAULT_EROSION_STRENGTH := 0.35
const DEFAULT_EROSION_ITERATIONS := 2
const SUPPORTED_EROSION_METHODS := ["none", "normal_detail"]
const NOT_YET_IMPLEMENTED_EROSION_METHODS := ["hydraulic", "thermal", "import_heightmap"]  # plan §7.3, deferred

# Biome thresholds — a small deterministic classifier (height/slope/moisture -> one of 5 biomes),
# each biome_id emitted as index/(N-1) so the field stays a flat [0..1] layer per the plan's own
# "biome_id as flat [0..1] layers" spec (§6.1). Order: water, grassland, forest, rock, alpine.
const BIOME_COUNT := 5
const BIOME_WATER := 0
const BIOME_GRASSLAND := 1
const BIOME_FOREST := 2
const BIOME_ROCK := 3
const BIOME_ALPINE := 4


# ── deterministic child-seeding (plan §12 FM-4) ───────────────────────────────────────────────────

## Derive a deterministic child seed from a parent seed + integer coordinates. Same inputs always
## produce the same output (integer hashing only, no RNG state) — the invariant a future tiled
## terrain, a constraint-field noise channel, or a per-octave seed offset all rely on.
static func child_seed(parent_seed: int, x: int, y: int = 0) -> int:
	var n := (int(parent_seed) * 668265263 + x * 374761393 + y * 2246822519) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	return n & 0x7fffffff


# ── noise primitives (bit-identical to clouds.gd._fbm/_value_noise/_hash01 — the portable-noise
#    invariant this engine holds; reproduced locally per that file's own documented reason) ─────────

## A stable [0,1] hash of (x, y, seed) — integer mixing only, no float platform variance.
static func _hash01(x: int, y: int, seed: int) -> float:
	var n := (x * 374761393 + y * 668265263 + seed * 1442695040888963407) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	n = n & 0x7fffffff
	return float(n) / float(0x7fffffff)

## Deterministic integer-hash value noise in [0,1] at (fx,fy), bilinearly interpolated with a
## smoothstep interpolant.
static func _value_noise(fx: float, fy: float, seed: int) -> float:
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var v00 := _hash01(x0, y0, seed)
	var v10 := _hash01(x0 + 1, y0, seed)
	var v01 := _hash01(x0, y0 + 1, seed)
	var v11 := _hash01(x0 + 1, y0 + 1, seed)
	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, ty)

## Fractal Brownian motion with EXPLICIT lacunarity/gain (generalizes clouds.gd's fixed 2.0/0.5),
## plus an optional single-pass domain warp (perturb the sample point by a second, differently-
## seeded noise field before summing octaves — the standard free "warp" knob the plan's terrain
## spec names). Returns raw (unnormalized-by-octave-count) [0..1]-ish value; caller normalizes.
static func _fbm(fx: float, fy: float, seed: int, octaves: int, lacunarity: float, gain: float, warp: float) -> float:
	if octaves <= 0:
		return 0.0
	var sx := fx
	var sy := fy
	if warp > 0.0:
		var wx := _value_noise(fx * 0.5 + 91.7, fy * 0.5 + 13.3, seed + 7001) - 0.5
		var wy := _value_noise(fx * 0.5 - 41.1, fy * 0.5 + 58.9, seed + 7307) - 0.5
		sx += wx * warp
		sy += wy * warp
	var total := 0.0
	var amp := 0.5
	var freq := 1.0
	var norm := 0.0
	for i in octaves:
		total += amp * _value_noise(sx * freq, sy * freq, seed + i * 1013)
		norm += amp
		amp *= gain
		freq *= lacunarity
	return clampf(total / maxf(0.0001, norm), 0.0, 1.0)


# ── heightfield generation ────────────────────────────────────────────────────────────────────────

## Build the terrain heightfield: `width`x`depth` grid, row-major PackedFloat32Array of world-unit
## heights. `detail_field` (optional, same width*depth length as this grid — e.g. from
## `DetailField.build(width, depth, detail_knob, falloff)`, the EXISTING unedited seam) cross-fades
## in `extra_octaves` additional high-frequency terms per-cell by that cell's own [0..1] budget —
## the truncated-recursive-sum scale-invariant model (plan §4), applied for real. Pass an empty
## PackedFloat32Array (default) to always render `base_octaves` only (uniform far-truncation).
static func generate_heightfield(width: int, depth: int, params: Dictionary = {},
		detail_field: PackedFloat32Array = PackedFloat32Array()) -> PackedFloat32Array:
	width = maxi(1, width)
	depth = maxi(1, depth)
	var seed: int = int(params.get("seed", DEFAULT_SEED))
	var base_octaves: int = maxi(0, int(params.get("base_octaves", DEFAULT_BASE_OCTAVES)))
	var extra_octaves: int = maxi(0, int(params.get("extra_octaves", DEFAULT_EXTRA_OCTAVES)))
	var lacunarity: float = maxf(1.0001, float(params.get("lacunarity", DEFAULT_LACUNARITY)))
	var gain: float = clampf(float(params.get("gain", DEFAULT_GAIN)), 0.0001, 0.9999)
	var warp: float = maxf(0.0, float(params.get("warp", DEFAULT_WARP)))
	var noise_scale: float = maxf(0.0001, float(params.get("noise_scale", DEFAULT_NOISE_SCALE)))
	var amplitude: float = float(params.get("amplitude", DEFAULT_AMPLITUDE))

	var has_detail := detail_field.size() == width * depth
	var out := PackedFloat32Array()
	out.resize(width * depth)
	var i := 0
	for y in depth:
		for x in width:
			var fx := float(x) * noise_scale
			var fy := float(y) * noise_scale
			var base := _fbm(fx, fy, seed, base_octaves, lacunarity, gain, warp)
			var h01 := base
			if extra_octaves > 0:
				# No detail_field supplied -> budget 0.0 (base_octaves only, the uniform
				# far-truncation default this function's own docstring promises); a detail_field IS
				# the opt-in that unlocks the near/fine terms, per-cell, via its own [0..1] value.
				var budget := 0.0
				if has_detail:
					budget = clampf(detail_field[i], 0.0, 1.0)
				if budget > 0.0:
					var fine := _fbm(fx, fy, seed, base_octaves + extra_octaves, lacunarity, gain, warp)
					h01 = lerpf(base, fine, budget)  # cross-fade, never a hard octave-count switch (FM-4)
			out[i] = (h01 - 0.5) * 2.0 * amplitude  # centered around 0, +/- amplitude
			i += 1
	return out


# ── erosion (plan §7.3, kollapse3d normal_detail — the only implemented method this pass) ─────────

## Apply the `normal_detail` erosion method in place-equivalent (returns a NEW heightfield; input
## unchanged). Talus-like diffusion driven by each cell's own local slope (central-difference
## gradient — the "surface-normal info" kollapse3d's technique reads): steep/convex cells lose a
## fraction of their height to their flatter/lower neighbors each iteration, redistributing mass
## rather than deleting it (a real diffusion step, not a lossy blur) — `strength` scales how much
## moves per iteration, `iterations` repeats the pass, matching the tutorial's own named knobs.
static func apply_erosion(heightfield: PackedFloat32Array, width: int, depth: int,
		params: Dictionary = {}) -> PackedFloat32Array:
	var method: String = String(params.get("method", DEFAULT_EROSION_METHOD))
	if method == "none" or method == "":
		return heightfield.duplicate()
	if method in NOT_YET_IMPLEMENTED_EROSION_METHODS:
		push_error("TerrainGenerator.apply_erosion: erosion method '%s' is named in the plan (§7.3) but NOT YET IMPLEMENTED this pass (no-auto-generalization — deferred, not invented) — pass 'normal_detail' or 'none'." % method)
		return heightfield.duplicate()
	if not (method in SUPPORTED_EROSION_METHODS):
		push_error("TerrainGenerator.apply_erosion: unknown erosion method '%s'" % method)
		return heightfield.duplicate()

	var strength: float = clampf(float(params.get("strength", DEFAULT_EROSION_STRENGTH)), 0.0, 1.0)
	var iterations: int = maxi(0, int(params.get("iterations", DEFAULT_EROSION_ITERATIONS)))
	var field := heightfield.duplicate()
	if strength <= 0.0 or iterations <= 0:
		return field

	for _iter in iterations:
		var next := field.duplicate()
		for y in depth:
			for x in width:
				var idx := y * width + x
				var h: float = field[idx]
				# 4-neighbor central-difference slope + talus transfer to the lowest neighbor.
				var lowest_idx := -1
				var lowest_h := h
				for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nx := x + d.x
					var ny := y + d.y
					if nx < 0 or nx >= width or ny < 0 or ny >= depth:
						continue
					var nidx := ny * width + nx
					var nh: float = field[nidx]
					if nh < lowest_h:
						lowest_h = nh
						lowest_idx = nidx
				if lowest_idx == -1:
					continue
				var diff: float = h - lowest_h
				if diff <= 0.0:
					continue
				# Move a fraction of the height difference from this (higher, steeper) cell to its
				# lowest neighbor — normal-driven redistribution, mass-conserving (kollapse3d's
				# "erosion from normal info", the free-recreate of the cited technique).
				var moved: float = diff * 0.5 * strength
				# Accumulate (never overwrite): `idx` may already have received mass THIS iteration
				# as some earlier cell's chosen lowest-neighbor target — a plain `next[idx] = h -
				# moved` would silently discard that earlier addition (a real mass-conservation bug,
				# caught by _test_erosion_conserves_total_mass_approximately). +=/-= against the
				# running `next` (not a fresh computation from `field`) keeps every transfer exact.
				next[idx] -= moved
				next[lowest_idx] += moved
		field = next
	return field


# ── constraint field (plan §6.1 out: "ground GLB + Constraint Field") ───────────────────────────────

## Derive the constraint field {slope, height, moisture, biome_id} from a heightfield — each a flat
## PackedFloat32Array in [0..1], row-major, SAME length as the heightfield (the "everything over
## space is a function" law: any downstream consumer, e.g. ScatterComposer's own field_fn, reads
## these numbers without knowing terrain produced them).
static func derive_constraint_field(heightfield: PackedFloat32Array, width: int, depth: int,
		params: Dictionary = {}) -> Dictionary:
	var n := width * depth
	var slope := PackedFloat32Array()
	var height_n := PackedFloat32Array()
	var moisture := PackedFloat32Array()
	var biome := PackedFloat32Array()
	slope.resize(n)
	height_n.resize(n)
	moisture.resize(n)
	biome.resize(n)
	if n == 0:
		return {"slope": slope, "height": height_n, "moisture": moisture, "biome_id": biome}

	var seed: int = int(params.get("seed", DEFAULT_SEED))
	var slope_scale: float = maxf(0.0001, float(params.get("slope_scale", 1.0)))
	var cell_size: float = maxf(0.0001, float(params.get("cell_size", DEFAULT_CELL_SIZE)))
	var moisture_noise_scale: float = maxf(0.0001, float(params.get("moisture_noise_scale", 0.08)))

	var min_h := heightfield[0]
	var max_h := heightfield[0]
	for h in heightfield:
		min_h = minf(min_h, h)
		max_h = maxf(max_h, h)
	var h_range := maxf(0.0001, max_h - min_h)

	var i := 0
	for y in depth:
		for x in width:
			var h: float = heightfield[i]
			var hn := clampf((h - min_h) / h_range, 0.0, 1.0)
			height_n[i] = hn

			# Central-difference gradient (world-unit rise per world-unit run) -> normalized slope.
			var hx0: float = heightfield[y * width + maxi(0, x - 1)]
			var hx1: float = heightfield[y * width + mini(width - 1, x + 1)]
			var hy0: float = heightfield[maxi(0, y - 1) * width + x]
			var hy1: float = heightfield[mini(depth - 1, y + 1) * width + x]
			var dx := (hx1 - hx0) / (2.0 * cell_size)
			var dz := (hy1 - hy0) / (2.0 * cell_size)
			var grad_mag := sqrt(dx * dx + dz * dz)
			var sn := clampf(grad_mag / slope_scale, 0.0, 1.0)
			slope[i] = sn

			# Independent moisture channel (different seed offset -> uncorrelated noise), biased
			# wetter in low/flat areas (valleys pool water) — simple, deterministic, real.
			var m_noise := _value_noise(float(x) * moisture_noise_scale, float(y) * moisture_noise_scale,
				child_seed(seed, 9901, 0))
			var mn := clampf(lerpf(m_noise, 1.0 - hn, 0.5) * (1.0 - 0.6 * sn), 0.0, 1.0)
			moisture[i] = mn

			biome[i] = float(_classify_biome(hn, sn, mn)) / float(BIOME_COUNT - 1)
			i += 1
	return {"slope": slope, "height": height_n, "moisture": moisture, "biome_id": biome}

static func _classify_biome(hn: float, sn: float, mn: float) -> int:
	if hn < 0.28 and sn < 0.35:
		return BIOME_WATER
	if sn > 0.6:
		return BIOME_ROCK if hn < 0.82 else BIOME_ALPINE
	if hn > 0.78:
		return BIOME_ALPINE
	if mn > 0.5:
		return BIOME_FOREST
	return BIOME_GRASSLAND


# ── mesh (a raw procedural Mesh producer -> GLB via GltfExporter.export_mesh_to_file, the SAME
#    entry point RingScaffoldGenerator's export_wedge_chunks_glb() already established for a
#    generator that never goes through GraphRuntime's scene_node descriptors) ────────────────────

## Build a renderable ground Mesh from the heightfield — a plain vertex/index grid via SurfaceTool,
## per-vertex normals from `generate_normals()` (cheaper than an analytic per-vertex normal, same
## approach ring_scaffold.gd's own build_wedge_mesh documents using), UVs 0..1 across the grid.
static func build_mesh(heightfield: PackedFloat32Array, width: int, depth: int,
		cell_size: float = DEFAULT_CELL_SIZE) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if width < 2 or depth < 2 or heightfield.size() != width * depth:
		return st.commit()

	for y in range(depth - 1):
		for x in range(width - 1):
			var i00 := y * width + x
			var i10 := y * width + (x + 1)
			var i01 := (y + 1) * width + x
			var i11 := (y + 1) * width + (x + 1)
			var p00 := Vector3(float(x) * cell_size, heightfield[i00], float(y) * cell_size)
			var p10 := Vector3(float(x + 1) * cell_size, heightfield[i10], float(y) * cell_size)
			var p01 := Vector3(float(x) * cell_size, heightfield[i01], float(y + 1) * cell_size)
			var p11 := Vector3(float(x + 1) * cell_size, heightfield[i11], float(y + 1) * cell_size)
			var u0 := float(x) / float(width - 1)
			var u1 := float(x + 1) / float(width - 1)
			var v0 := float(y) / float(depth - 1)
			var v1 := float(y + 1) / float(depth - 1)
			_tri_uv(st, p00, p10, p11, Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1))
			_tri_uv(st, p00, p11, p01, Vector2(u0, v0), Vector2(u1, v1), Vector2(u0, v1))

	st.generate_normals()
	return st.commit()

static func _tri_uv(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, ua: Vector2, ub: Vector2, uc: Vector2) -> void:
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_uv(uc)
	st.add_vertex(c)

## Export a built ground Mesh to a .glb file — thin wrap of GltfExporter.export_mesh_to_file (the
## established raw-Mesh export entry point; adds no new export mechanism).
static func export_glb(mesh: Mesh, out_path: String, mesh_name: String = "Terrain") -> int:
	return GltfExporter.export_mesh_to_file(mesh, out_path, mesh_name)


# ── sampling helper (for consumers that need world-space height/constraint lookups, e.g. a
#    scatter composer placing instances ON the terrain surface) ────────────────────────────────────

## Bilinear-sample a row-major width*depth field at a fractional grid coordinate (gx, gy), clamped
## to the field's extent. Works for the heightfield OR any constraint_field layer — same shape.
static func sample_bilinear(field: PackedFloat32Array, width: int, depth: int, gx: float, gy: float) -> float:
	if width <= 0 or depth <= 0 or field.size() != width * depth:
		return 0.0
	gx = clampf(gx, 0.0, float(width - 1))
	gy = clampf(gy, 0.0, float(depth - 1))
	var x0 := int(floor(gx))
	var y0 := int(floor(gy))
	var x1 := mini(width - 1, x0 + 1)
	var y1 := mini(depth - 1, y0 + 1)
	var tx := gx - float(x0)
	var ty := gy - float(y0)
	var v00: float = field[y0 * width + x0]
	var v10: float = field[y0 * width + x1]
	var v01: float = field[y1 * width + x0]
	var v11: float = field[y1 * width + x1]
	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, ty)


# ── top-level convenience (matches ring_scaffold.gd's own `build(tunables)` shape) ──────────────────

## The single entry point: seed+params -> heightfield + constraint_field + ground mesh, all in one
## deterministic call. `tunables` keys (all optional, plan §6.1 shape):
##   width, depth        : int    — grid vertex counts (default 33x33)
##   cell_size           : float  — world units per grid step (default 1.0)
##   seed                : int
##   base_octaves / extra_octaves / lacunarity / gain / warp / noise_scale / amplitude : fBm knobs
##   detail_knob / falloff : optional — if BOTH present, builds a DetailField (the existing,
##                            unedited seam) to drive the near/far octave cross-fade; omit for a
##                            uniform far-truncation (base_octaves everywhere).
##   erosion              : Dictionary {method, strength, iterations} — default normal_detail
## Returns {heightfield, width, depth, cell_size, constraint_field, mesh, params}.
static func build(tunables: Dictionary = {}) -> Dictionary:
	var width: int = maxi(2, int(tunables.get("width", DEFAULT_WIDTH)))
	var depth: int = maxi(2, int(tunables.get("depth", DEFAULT_DEPTH)))
	var cell_size: float = maxf(0.0001, float(tunables.get("cell_size", DEFAULT_CELL_SIZE)))

	var detail_field := PackedFloat32Array()
	if tunables.has("detail_knob") and tunables.has("falloff"):
		detail_field = DetailField.build(width, depth, float(tunables["detail_knob"]), tunables["falloff"])

	var heightfield := generate_heightfield(width, depth, tunables, detail_field)
	var erosion: Dictionary = tunables.get("erosion", {"method": DEFAULT_EROSION_METHOD})
	heightfield = apply_erosion(heightfield, width, depth, erosion)

	var cf_params := tunables.duplicate()
	cf_params["cell_size"] = cell_size
	var constraint_field := derive_constraint_field(heightfield, width, depth, cf_params)

	var mesh := build_mesh(heightfield, width, depth, cell_size)

	return {
		"heightfield": heightfield,
		"width": width,
		"depth": depth,
		"cell_size": cell_size,
		"constraint_field": constraint_field,
		"mesh": mesh,
		"params": tunables,
	}
