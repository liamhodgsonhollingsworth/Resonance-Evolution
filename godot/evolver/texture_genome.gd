class_name TextureGenome
extends RefCounted
## The PROCEDURAL-TEXTURE GENOME — the second genome KIND the general-purpose evolver breeds
## (the first is EffectGenome, the painterly post-process stack). A texture genome IS an ordered
## list of mathematical construction ops ({ "type", "params" }) — noise (value_noise/fbm + domain
## warping), sinusoidal interference (sine), geometric partitions (stripes/checker/radial/voronoi) —
## each colored by a PALETTE HANDLE and composited by a blend op. TextureSynthCpu.synthesize is the
## genome→image phenotype; nothing here touches pixels.
##
## It mirrors EffectGenome's contract EXACTLY (random / mutate / crossover / clone / to_stack /
## from_stack / is_valid / size), so EvolverGenome (the lineage wrapper), EvolverBreed, and the four
## evolver primitives drive it through the SAME loop with zero new plumbing — the evolver is
## genome-KIND-polymorphic, not forked. Pure DATA + pure functions over data: JSON-serializable,
## headless, deterministic given a seeded RNG.
##
## PER-GENE-TYPE OPERATORS: every op type's genes are declared in TextureSynthCpu.OP_TYPES with a
## machine-readable schema, and the operators are defined per gene TYPE:
##   - numeric genes ({min,max}, "int"/"float") → PERTURB re-samples in-range (ints rounded);
##   - handle genes  ({options}, e.g. palette / blend) → PERTURB re-samples from the options list
##     (the palette-by-handle gene mutates by RELINKING to another handle, never by editing raw RGB);
##   - the op LIST itself → REORDER (swap two ops), ADD (insert a random new op), DROP (remove one).
## CROSSOVER is a one-point splice of the two parents' op lists (prefix of A + suffix of B) — closed
## over the valid-op set, so every child `to_stack()` is a descriptor the synthesizer fully understands.

## The ordered op list. Each op: { "type": String, "params": Dictionary }. This array IS the genome;
## ops[0] paints first (order is genotype — later ops composite over earlier ones).
var ops: Array = []

func _init(initial_ops: Array = []) -> void:
	ops = _sanitize(initial_ops)

# ---------------------------------------------------------------------------------------------------
# construction
# ---------------------------------------------------------------------------------------------------

## A random valid genome of `n` ops, each a random known construction with params sampled in-range.
## Deterministic given `rng`. The FIRST op is forced to full-opacity replace/mix so a random tile is
## never a barely-touched gray canvas (every seed genome paints a real base coat).
static func random(n: int, rng: RandomNumberGenerator) -> TextureGenome:
	var names := _op_names()
	var ls := []
	for i in maxi(1, n):
		var t: String = names[rng.randi_range(0, names.size() - 1)]
		var p := _random_params(t, rng)
		if i == 0:
			p["blend"] = "replace"
		ls.append({ "type": t, "params": p })
	return TextureGenome.new(ls)

## Build a genome from a `texture_ops` descriptor ({ "texture_ops": [...] }) or a raw op array.
static func from_stack(desc) -> TextureGenome:
	if typeof(desc) == TYPE_DICTIONARY and desc.has("texture_ops"):
		return TextureGenome.new(desc["texture_ops"])
	if typeof(desc) == TYPE_ARRAY:
		return TextureGenome.new(desc)
	return TextureGenome.new([])

## The renderer-neutral descriptor this genome encodes — exactly what TextureSynthCpu.synthesize
## consumes. The key ("texture_ops" vs EffectGenome's "stack") is ALSO the genome-kind discriminator
## EvolverGenome.from_dict dispatches on. Always a VALID descriptor (closure invariant).
func to_stack() -> Dictionary:
	return { "texture_ops": _clone_ops(ops) }

func size() -> int:
	return ops.size()

func clone() -> TextureGenome:
	return TextureGenome.new(_clone_ops(ops))

# ---------------------------------------------------------------------------------------------------
# mutate — one local edit per call, returns a NEW genome (the source is untouched)
# ---------------------------------------------------------------------------------------------------

## One mutation from {perturb-gene, reorder, add-op, drop-op}, exactly EffectGenome's operator shape.
## Perturb dispatches PER GENE TYPE: numeric genes re-sample in-range; handle genes re-link from their
## options list. A seeded RNG fully determines the mutation (reproducible evolution).
##
## EFFECTIVE-MUTATION invariant: a mutation ALWAYS changes the genome DATA — reorder picks two
## DISTINCT slots (and falls through to add if the swapped ops happen to be identical), and perturb
## re-samples until the gene value actually changes (bounded retries, then falls back to add). With
## tiny supervised populations (2-8 candidates) a silent no-op mutation wastes a whole human-paced
## generation slot, so "did nothing" is never a valid mutation outcome.
func mutate(rng: RandomNumberGenerator) -> TextureGenome:
	var child := _clone_ops(ops)
	var op_choice: String = ["perturb", "reorder", "add", "drop"][rng.randi_range(0, 3)]
	match op_choice:
		"perturb":
			_mutate_perturb(child, rng)
		"reorder":
			if child.size() >= 2:
				var i := rng.randi_range(0, child.size() - 1)
				var j := (i + 1 + rng.randi_range(0, child.size() - 2)) % child.size()  # j != i always
				if JSON.stringify(child[i]) == JSON.stringify(child[j]):
					_mutate_add(child, rng)  # swapping identical ops would be a silent no-op
				else:
					var tmp = child[i]; child[i] = child[j]; child[j] = tmp
			else:
				_mutate_add(child, rng)
		"add":
			_mutate_add(child, rng)
		"drop":
			if child.size() >= 2:
				# Never drop to an EMPTY genome — a texture genome must always paint something.
				child.remove_at(rng.randi_range(0, child.size() - 1))
			else:
				_mutate_add(child, rng)
	return TextureGenome.new(child)

func _mutate_add(child: Array, rng: RandomNumberGenerator) -> void:
	var names := _op_names()
	var t: String = names[rng.randi_range(0, names.size() - 1)]
	var at := rng.randi_range(0, child.size())
	child.insert(at, { "type": t, "params": _random_params(t, rng) })

## Re-sample ONE gene of ONE op — the per-gene-type perturb (numeric range OR handle options).
func _mutate_perturb(child: Array, rng: RandomNumberGenerator) -> void:
	if child.is_empty():
		_mutate_add(child, rng)
		return
	var li := rng.randi_range(0, child.size() - 1)
	var layer: Dictionary = child[li]
	var t := String(layer.get("type", ""))
	var schema: Dictionary = _param_schema(t)
	var mutable := []
	for k in schema.keys():
		var spec: Dictionary = schema[k]
		if (spec.has("min") and spec.has("max")) or spec.has("options"):
			mutable.append(k)
	if mutable.is_empty():
		_mutate_add(child, rng)
		return
	var pk: String = mutable[rng.randi_range(0, mutable.size() - 1)]
	var p: Dictionary = (layer.get("params", {}) as Dictionary).duplicate(true)
	# Effective-mutation: re-sample until the gene ACTUALLY changes (bounded), else fall back to add.
	var old = p.get(pk)
	var changed := false
	for _try in 8:
		var nv = _sample_param(schema[pk], rng)
		if nv != old:
			p[pk] = nv
			changed = true
			break
	if not changed:
		_mutate_add(child, rng)
		return
	child[li] = { "type": t, "params": p }

# ---------------------------------------------------------------------------------------------------
# crossover — one-point splice of two op lists (closed over valid ops)
# ---------------------------------------------------------------------------------------------------

## Prefix of `a` + suffix of `b`, cut points drawn from `rng` — EffectGenome.crossover's exact shape.
## Both parents' ops are already valid, so the child is always valid. A doubly-empty splice degrades
## to a fresh single random op (a texture genome never goes empty through breeding).
static func crossover(a: TextureGenome, b: TextureGenome, rng: RandomNumberGenerator) -> TextureGenome:
	var la := a._clone_ops(a.ops)
	var lb := b._clone_ops(b.ops)
	var ca := rng.randi_range(0, la.size())
	var cb := rng.randi_range(0, lb.size())
	var child := []
	for i in ca:
		child.append(la[i])
	for i in range(cb, lb.size()):
		child.append(lb[i])
	if child.is_empty():
		var names := _op_names()
		var t: String = names[rng.randi_range(0, names.size() - 1)]
		child.append({ "type": t, "params": _random_params(t, rng) })
	return TextureGenome.new(child)

# ---------------------------------------------------------------------------------------------------
# validity / sanitation — the closure invariant: a genome only ever holds VALID ops
# ---------------------------------------------------------------------------------------------------

## Coerce an arbitrary op array into valid ops: drop non-dicts + unknown op types, clamp/round every
## declared numeric gene into its range, snap handle genes to a declared option (fall back to the
## default), drop undeclared params. After this, to_stack() is guaranteed synthesizer-valid.
static func _sanitize(raw: Array) -> Array:
	var out := []
	for layer in raw:
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var t := String(layer.get("type", ""))
		if not TextureSynthCpu.OP_TYPES.has(t):
			continue
		var schema: Dictionary = _param_schema(t)
		var raw_params: Dictionary = layer.get("params", {})
		var clean := {}
		for k in schema.keys():
			var spec: Dictionary = schema[k]
			if raw_params.has(k):
				clean[k] = _coerce_param(spec, raw_params[k])
			elif spec.has("default"):
				clean[k] = spec["default"]
		out.append({ "type": t, "params": clean })
	return out

## Whether to_stack() would be fully synthesizer-valid AND non-empty (a texture genome always paints).
func is_valid() -> bool:
	if ops.is_empty():
		return false
	for layer in ops:
		if typeof(layer) != TYPE_DICTIONARY:
			return false
		if not TextureSynthCpu.OP_TYPES.has(String(layer.get("type", ""))):
			return false
	return true

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

static func _op_names() -> Array:
	return TextureSynthCpu.OP_TYPES.keys()

static func _param_schema(op_type: String) -> Dictionary:
	var entry: Dictionary = TextureSynthCpu.OP_TYPES.get(op_type, {})
	return entry.get("params", {})

static func _random_params(op_type: String, rng: RandomNumberGenerator) -> Dictionary:
	var schema := _param_schema(op_type)
	var p := {}
	for k in schema.keys():
		p[k] = _sample_param(schema[k], rng)
	return p

## Sample one gene value PER ITS TYPE: handle genes pick uniformly from `options`; numeric genes
## sample uniformly in [min,max] ("int" rounded); otherwise the declared default.
static func _sample_param(spec: Dictionary, rng: RandomNumberGenerator) -> Variant:
	if spec.has("options"):
		var opts: Array = spec["options"]
		return opts[rng.randi_range(0, opts.size() - 1)]
	if spec.has("min") and spec.has("max"):
		var v := rng.randf_range(float(spec["min"]), float(spec["max"]))
		if String(spec.get("type", "float")) == "int":
			return int(round(v))
		return v
	return spec.get("default", 0)

## Clamp/round/snap an externally-supplied gene value into its schema (used by _sanitize).
static func _coerce_param(spec: Dictionary, value) -> Variant:
	if spec.has("options"):
		var opts: Array = spec["options"]
		return value if opts.has(value) else spec.get("default", opts[0] if opts.size() > 0 else "")
	if spec.has("min") and spec.has("max"):
		var v := clampf(float(value), float(spec["min"]), float(spec["max"]))
		if String(spec.get("type", "float")) == "int":
			return int(round(v))
		return v
	return value

## Deep-copy an op array (no shared sub-dicts between a parent genome and its children).
func _clone_ops(src: Array) -> Array:
	var out := []
	for layer in src:
		if typeof(layer) == TYPE_DICTIONARY:
			out.append({
				"type": String(layer.get("type", "")),
				"params": (layer.get("params", {}) as Dictionary).duplicate(true),
			})
	return out
