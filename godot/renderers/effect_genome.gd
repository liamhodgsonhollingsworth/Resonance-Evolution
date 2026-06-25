class_name EffectGenome
extends RefCounted
## The EVOLVER GENOME over an effect-stack — "evolving shaders" in its simplest real form. A genome IS
## the ordered list of effect layers ({ "type", "params" }) that PrimEffectStack carries and
## EffectStackCpu applies; nothing else. Evolving the look = evolving this list:
##   - mutate   → perturb one layer's param, reorder two layers, or add/drop a layer (one local edit).
##   - crossover→ mix two genomes into a valid new ordered stack (a one-point splice of the two lists).
## Every operation is closed over the VALID-stack set: the produced genome's layers are always known
## effect types (from EffectStackCpu.EFFECT_TYPES) with in-range params, so `to_stack()` is always a
## descriptor the CPU oracle (and every later delegate) applies unchanged. This is the 2D-effect
## analogue of the scene_node genome `window.Evolve` already evolves for 3D arrangements (PROGRESS.md):
## same mutate+crossover shape, here over the painterly effect-layer list instead of a mesh tree.
##
## It is pure DATA + pure functions over data — no Image, no shader, no GPU — so the whole evolve/mix
## path runs HEADLESS and is deterministic given an RNG seed (reproducibility = an evolvable invariant).
##
## The vocabulary + per-param ranges come from EffectStackCpu.EFFECT_TYPES, so adding a new effect to
## the applier automatically extends what the evolver can generate/mutate — one edit, no drift.

## The ordered effect-layer list. Each layer: { "type": String, "params": Dictionary }. This array IS
## the genome; `layers[0]` runs first (order is part of the genotype — reordering is a real mutation).
var layers: Array = []

func _init(initial_layers: Array = []) -> void:
	layers = _sanitize(initial_layers)

# ---------------------------------------------------------------------------------------------------
# construction
# ---------------------------------------------------------------------------------------------------

## A random valid genome of `n` layers, each a random known effect with params sampled in-range.
## Deterministic given `rng` (seed the RNG for reproducible evolution).
static func random(n: int, rng: RandomNumberGenerator) -> EffectGenome:
	var names := _effect_names()
	var ls := []
	for _i in maxi(0, n):
		var t: String = names[rng.randi_range(0, names.size() - 1)]
		ls.append({ "type": t, "params": _random_params(t, rng) })
	return EffectGenome.new(ls)

## Build a genome from an existing effect_stack descriptor ({ "stack": [...] }) or a raw layer array.
static func from_stack(desc) -> EffectGenome:
	if typeof(desc) == TYPE_DICTIONARY and desc.has("stack"):
		return EffectGenome.new(desc["stack"])
	if typeof(desc) == TYPE_ARRAY:
		return EffectGenome.new(desc)
	return EffectGenome.new([])

## The renderer-neutral effect_stack descriptor this genome encodes — exactly what PrimEffectStack
## emits and EffectStackCpu.apply consumes. Always a VALID stack (closure invariant).
func to_stack() -> Dictionary:
	return { "stack": _clone_layers(layers) }

func size() -> int:
	return layers.size()

func clone() -> EffectGenome:
	return EffectGenome.new(_clone_layers(layers))

# ---------------------------------------------------------------------------------------------------
# mutate — one local edit, returns a NEW genome (immutable evolution; the source is untouched)
# ---------------------------------------------------------------------------------------------------

## One mutation, chosen at random from {perturb-param, reorder, add-layer, drop-layer}. Returns a NEW
## genome (this one is left unchanged — evolution is non-destructive, the append-only invariant at the
## genome level). The choice + every random value is drawn from `rng`, so a seeded RNG fully determines
## the mutation (reproducible evolution).
func mutate(rng: RandomNumberGenerator) -> EffectGenome:
	var child := _clone_layers(layers)
	# Pick an applicable operation. Reorder needs >=2 layers; drop needs >=1; perturb needs a numeric
	# param on some layer. Add is always applicable. Fall back to add if the chosen op can't apply.
	var ops := ["perturb", "reorder", "add", "drop"]
	var op: String = ops[rng.randi_range(0, ops.size() - 1)]
	match op:
		"perturb":
			_mutate_perturb(child, rng)
		"reorder":
			if child.size() >= 2:
				var i := rng.randi_range(0, child.size() - 1)
				var j := rng.randi_range(0, child.size() - 1)
				var tmp = child[i]; child[i] = child[j]; child[j] = tmp
			else:
				_mutate_add(child, rng)
		"add":
			_mutate_add(child, rng)
		"drop":
			if child.size() >= 1:
				child.remove_at(rng.randi_range(0, child.size() - 1))
			else:
				_mutate_add(child, rng)
	return EffectGenome.new(child)

func _mutate_add(child: Array, rng: RandomNumberGenerator) -> void:
	var names := _effect_names()
	var t: String = names[rng.randi_range(0, names.size() - 1)]
	var at := rng.randi_range(0, child.size())  # insert anywhere, incl. end
	child.insert(at, { "type": t, "params": _random_params(t, rng) })

func _mutate_perturb(child: Array, rng: RandomNumberGenerator) -> void:
	if child.is_empty():
		_mutate_add(child, rng)
		return
	var li := rng.randi_range(0, child.size() - 1)
	var layer: Dictionary = child[li]
	var t := String(layer.get("type", ""))
	var schema: Dictionary = _param_schema(t)
	var keys := schema.keys()
	# Only numeric, range-bearing params are perturbable (no auto-generalization onto undeclared knobs).
	var numeric := []
	for k in keys:
		var spec: Dictionary = schema[k]
		if spec.has("min") and spec.has("max"):
			numeric.append(k)
	if numeric.is_empty():
		# This effect has no perturbable knob (e.g. passthrough) → fall back to an add so the mutation
		# is never a silent no-op.
		_mutate_add(child, rng)
		return
	var pk: String = numeric[rng.randi_range(0, numeric.size() - 1)]
	var spec: Dictionary = schema[pk]
	var p: Dictionary = (layer.get("params", {}) as Dictionary).duplicate(true)
	p[pk] = _sample_param(spec, rng)
	child[li] = { "type": t, "params": p }

# ---------------------------------------------------------------------------------------------------
# crossover — MIX two genomes into a valid new ordered stack
# ---------------------------------------------------------------------------------------------------

## One-point crossover: take a prefix of `a` and a suffix of `b` and splice them into a new ordered
## stack. The result is ALWAYS a valid genome (both parents' layers are already valid; concatenation
## of valid layers is valid). Deterministic given `rng`. This is the "mixing of two genomes = a valid
## new effect stack" the spec names — the painterly look of one parent's early passes followed by the
## other parent's later passes. Static so it reads symmetrically as `EffectGenome.crossover(a, b, rng)`.
static func crossover(a: EffectGenome, b: EffectGenome, rng: RandomNumberGenerator) -> EffectGenome:
	var la := a._clone_layers(a.layers)
	var lb := b._clone_layers(b.layers)
	# Cut point in each parent: prefix [0, ca) of A, suffix [cb, len) of B. With empty parents this
	# degrades gracefully to whichever parent has layers.
	var ca := rng.randi_range(0, la.size())
	var cb := rng.randi_range(0, lb.size())
	var child := []
	for i in ca:
		child.append(la[i])
	for i in range(cb, lb.size()):
		child.append(lb[i])
	return EffectGenome.new(child)

## Uniform crossover variant: walk both lists position-by-position and pick each layer from A or B by a
## coin flip (the shorter list runs out → the rest comes from the longer one). A different mixing than
## one-point; still closed over valid stacks. Offered so the evolver can choose a mix operator.
static func crossover_uniform(a: EffectGenome, b: EffectGenome, rng: RandomNumberGenerator) -> EffectGenome:
	var la := a._clone_layers(a.layers)
	var lb := b._clone_layers(b.layers)
	var n := maxi(la.size(), lb.size())
	var child := []
	for i in n:
		var from_a := rng.randf() < 0.5
		if from_a and i < la.size():
			child.append(la[i])
		elif (not from_a) and i < lb.size():
			child.append(lb[i])
		elif i < la.size():
			child.append(la[i])
		elif i < lb.size():
			child.append(lb[i])
	return EffectGenome.new(child)

# ---------------------------------------------------------------------------------------------------
# validity / sanitation — the closure invariant: a genome only ever holds VALID layers
# ---------------------------------------------------------------------------------------------------

## Coerce an arbitrary layer array into valid layers: drop non-dicts, default unknown effect types to
## "passthrough", clamp/round every declared numeric param into its schema range, and drop undeclared
## params. After this, `to_stack()` is guaranteed to be a descriptor the applier fully understands.
static func _sanitize(raw: Array) -> Array:
	var out := []
	for layer in raw:
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var t := String(layer.get("type", "passthrough"))
		if not EffectStackCpu.EFFECT_TYPES.has(t):
			t = "passthrough"
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

## Whether `to_stack()` would be a fully-valid effect_stack (every layer a known type). Always true for
## a genome built through this class — exposed so a test can assert the closure invariant directly.
func is_valid() -> bool:
	for layer in layers:
		if typeof(layer) != TYPE_DICTIONARY:
			return false
		if not EffectStackCpu.EFFECT_TYPES.has(String(layer.get("type", ""))):
			return false
	return true

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

static func _effect_names() -> Array:
	return EffectStackCpu.EFFECT_TYPES.keys()

static func _param_schema(effect_type: String) -> Dictionary:
	var entry: Dictionary = EffectStackCpu.EFFECT_TYPES.get(effect_type, {})
	return entry.get("params", {})

static func _random_params(effect_type: String, rng: RandomNumberGenerator) -> Dictionary:
	var schema := _param_schema(effect_type)
	var p := {}
	for k in schema.keys():
		p[k] = _sample_param(schema[k], rng)
	return p

## Sample one param value uniformly in its declared range; "int" params are rounded to an int.
static func _sample_param(spec: Dictionary, rng: RandomNumberGenerator) -> Variant:
	if not (spec.has("min") and spec.has("max")):
		return spec.get("default", 0)
	var lo := float(spec["min"])
	var hi := float(spec["max"])
	var v := rng.randf_range(lo, hi)
	if String(spec.get("type", "float")) == "int":
		return int(round(v))
	return v

## Clamp/round an externally-supplied param value into its schema range (used by _sanitize).
static func _coerce_param(spec: Dictionary, value) -> Variant:
	if not (spec.has("min") and spec.has("max")):
		return value
	var lo := float(spec["min"])
	var hi := float(spec["max"])
	var v := clampf(float(value), lo, hi)
	if String(spec.get("type", "float")) == "int":
		return int(round(v))
	return v

## Deep-copy a layer array (no shared sub-dicts between a parent genome and its children).
func _clone_layers(src: Array) -> Array:
	var out := []
	for layer in src:
		if typeof(layer) == TYPE_DICTIONARY:
			out.append({
				"type": String(layer.get("type", "passthrough")),
				"params": (layer.get("params", {}) as Dictionary).duplicate(true),
			})
	return out
