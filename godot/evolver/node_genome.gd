class_name NodeGenome
extends RefCounted
## The NODE GENOME — the third genome KIND the general-purpose evolver breeds (after EffectGenome
## and TextureGenome). An artifact is a COLLECTION OF NODES in which CONNECTIONS BETWEEN NODES ARE
## THEMSELVES NODES (a connection-node carries `from`/`to` endpoint refs AND its own params — a
## wire has genes too). Each node is flagged FIXED or VARIABLE:
##   - FIXED nodes are never touched by evolution (params byte-stable, never dropped/rewired).
##   - VARIABLE nodes evolve: every scalar/enum param is drawn from a per-param CONCENTRATING
##     ADAPTIVE DISTRIBUTION (evolver/param_dist.gd) whose state rides ON the genome as data, and
##     the node set itself reshuffles (add / drop / rewire / swap) at a configured rate.
##
## EVOLVING = GENOMIC RESHUFFLING of the variable parts:
##   - `mutate(rng)`     : one evolution step — every variable param's distribution CONCENTRATES
##     around the parent's realized value, matching CONVERGENCE-HELPER NODES transform it further,
##     then the child's value is REDRAWN. More evolution ⇒ smaller typical change; the fixed-weight
##     heavy tail keeps dramatic outward moves possible FOREVER. Plus an occasional structural op.
##   - `recombine(parents, rng)` : COMBINATIONAL reshuffling across MULTIPLE evolutions of a
##     generation (multi-parent): per-param donor choice among every parent carrying the same node,
##     plus structural splice of nodes unique to non-base parents. `crossover(a, b)` (the 2-parent
##     contract the breed algebra calls) is recombine([a, b]).
##
## CONVERGENCE-HELPER NODES (evolver/node_genome_helpers.gd): a node whose schema type declares
## `is_helper: true` IS a per-parameter evolution method wired as DATA — its `when` condition
## selects which params it applies to, its params are the method's hyperparameters. Reusable,
## additive, and (if flagged variable) itself evolvable.
##
## The node VOCABULARY is a SCHEMA carried as data on the genome (DEFAULT_SCHEMA is a small
## generic demo domain; real domains — texture ops, effect stacks, canvas pages — wire their own
## schema in, no code change). Mirrors the EffectGenome/TextureGenome contract EXACTLY
## (random / mutate / crossover / clone / to_stack / from_stack / is_valid / size), so
## EvolverGenome, EvolverBreed, and the four evolver primitives drive it through the SAME loop
## (meta_genome.genome_kind = "node"); kinds never interbreed. Pure DATA + pure functions over
## data: JSON-serializable, headless, deterministic given a seeded RNG. The serialized
## discriminator is the payload key "node_graph". Design note:
## notes/design/node_genome_evolver_2026-07-03.md.

## A small generic demo vocabulary (signal-flow flavored) proving the model. Domain schemas are
## DATA — pass your own to random()/from_stack(); nothing below is hardcoded to this one.
const DEFAULT_SCHEMA := {
	"types": {
		"source": { "params": {
			"level": { "min": 0.0, "max": 1.0, "type": "float", "default": 0.5 },
			"rate":  { "min": 0.1, "max": 10.0, "type": "float", "default": 1.0 },
			"mode":  { "options": ["pulse", "steady", "burst"], "default": "steady" },
		} },
		"transform": { "params": {
			"gain":  { "min": -2.0, "max": 2.0, "type": "float", "default": 1.0 },
			"bias":  { "min": -1.0, "max": 1.0, "type": "float", "default": 0.0 },
			"curve": { "options": ["linear", "ease", "step"], "default": "linear" },
		} },
		"sink": { "params": {
			"mix": { "min": 0.0, "max": 1.0, "type": "float", "default": 1.0 },
		} },
		# The connection-as-node: a wire with genes (weight/gate) and endpoint refs from/to.
		"link": { "is_connection": true, "params": {
			"weight": { "min": -1.0, "max": 1.0, "type": "float", "default": 1.0 },
			"gate":   { "options": ["open", "half", "closed"], "default": "open" },
		} },
		# The shipped convergence-helper node (see NodeGenomeHelpers._momentum).
		"helper_momentum": { "is_helper": true, "params": {
			"beta": { "min": 0.0, "max": 0.9, "type": "float", "default": 0.5 },
			"gain": { "min": 0.0, "max": 2.0, "type": "float", "default": 1.0 },
		} },
	},
}

## Evolution knobs beyond the ParamDist config — all DATA on `config`, all optional.
const DEFAULT_EVOLVE_CONFIG := {
	"p_structural": 0.15,  # per-mutate probability of one structural reshuffle op
	"splice_p": 0.3,       # per-node probability a non-base parent's unique node joins a recombine
}

## The node collection. Each node: { "id", "type", "fixed", "params": {..}, "dist": {..} }
## + "from"/"to" on connection-nodes + "when" on helper-nodes. This array IS the genome.
var nodes: Array = []
## Distribution + evolution config overrides (ParamDist.DEFAULT_CONFIG + DEFAULT_EVOLVE_CONFIG
## fill anything absent). Serialized with the genome — resolution/granularity is data.
var config: Dictionary = {}
## The node vocabulary this genome is expressed in. Serialized with the genome.
var schema: Dictionary = {}

func _init(p_nodes: Array = [], p_schema: Dictionary = {}, p_config: Dictionary = {}) -> void:
	schema = (p_schema if not p_schema.is_empty() else DEFAULT_SCHEMA).duplicate(true)
	config = p_config.duplicate(true)
	nodes = _sanitize(p_nodes)

# ---------------------------------------------------------------------------------------------------
# construction
# ---------------------------------------------------------------------------------------------------

## A random valid genome: `n` payload nodes chained by connection-nodes, every node VARIABLE,
## every param drawn uniform with a fresh wide distribution centered on the drawn value (the
## configured starting shape). Deterministic given `rng`.
static func random(n: int, rng: RandomNumberGenerator, p_schema: Dictionary = DEFAULT_SCHEMA,
		p_config: Dictionary = {}) -> NodeGenome:
	var types: Dictionary = p_schema.get("types", {})
	var payload_types := []
	var conn_types := []
	for t in types.keys():
		var spec: Dictionary = types[t]
		if bool(spec.get("is_connection", false)):
			conn_types.append(t)
		elif not bool(spec.get("is_helper", false)):
			payload_types.append(t)
	if payload_types.is_empty():
		return NodeGenome.new([], p_schema, p_config)
	var ls := []
	var count := maxi(1, n)
	for i in count:
		var t: String = payload_types[rng.randi_range(0, payload_types.size() - 1)]
		ls.append(_make_random_node("p%d" % i, t, types, p_config, rng))
	if not conn_types.is_empty():
		for i in count - 1:
			var ct: String = conn_types[rng.randi_range(0, conn_types.size() - 1)]
			var cn := _make_random_node("c%d" % i, ct, types, p_config, rng)
			cn["from"] = "p%d" % i
			cn["to"] = "p%d" % (i + 1)
			ls.append(cn)
	return NodeGenome.new(ls, p_schema, p_config)

## Build from a { "node_graph": {...} } descriptor (the serialized form), the inner dict, or a
## raw node array. Everything is sanitized on the way in.
static func from_stack(desc) -> NodeGenome:
	if typeof(desc) == TYPE_DICTIONARY and desc.has("node_graph"):
		var g: Dictionary = desc["node_graph"]
		return NodeGenome.new(g.get("nodes", []), g.get("schema", {}), g.get("config", {}))
	if typeof(desc) == TYPE_DICTIONARY and desc.has("nodes"):
		return NodeGenome.new(desc.get("nodes", []), desc.get("schema", {}), desc.get("config", {}))
	if typeof(desc) == TYPE_ARRAY:
		return NodeGenome.new(desc)
	return NodeGenome.new([])

## The renderer-neutral descriptor. "node_graph" is ALSO the genome-kind discriminator
## EvolverGenome.from_dict dispatches on ("stack" → effect, "texture_ops" → texture).
func to_stack() -> Dictionary:
	return { "node_graph": {
		"nodes": _clone_nodes(nodes),
		"schema": schema.duplicate(true),
		"config": config.duplicate(true),
	} }

func size() -> int:
	return nodes.size()

func clone() -> NodeGenome:
	return NodeGenome.new(_clone_nodes(nodes), schema, config)

## A copy with node `id` re-flagged fixed/variable (construction helper; genomes stay immutable).
func with_fixed(id: String, fixed: bool) -> NodeGenome:
	var copy := _clone_nodes(nodes)
	for nd in copy:
		if String(nd.get("id", "")) == id:
			nd["fixed"] = fixed
	return NodeGenome.new(copy, schema, config)

func find_node(id: String) -> Variant:
	for nd in nodes:
		if String(nd.get("id", "")) == id:
			return nd
	return null

# ---------------------------------------------------------------------------------------------------
# mutate — ONE evolution step; returns a NEW genome (the source is untouched)
# ---------------------------------------------------------------------------------------------------

## Concentrate → helper-transform → redraw every variable param; occasionally one structural
## reshuffle. Fixed nodes pass through byte-identical. Deterministic given `rng`.
func mutate(rng: RandomNumberGenerator) -> NodeGenome:
	var child := _clone_nodes(nodes)
	var helpers := []
	for nd in child:
		if _is_helper(String(nd.get("type", ""))):
			helpers.append(nd)
	for nd in child:
		if bool(nd.get("fixed", false)):
			continue
		var t := String(nd.get("type", ""))
		var params: Dictionary = nd.get("params", {})
		var dists: Dictionary = nd.get("dist", {})
		for pk in dists.keys():
			var state: Dictionary = dists[pk]
			var realized = params.get(pk)
			var prev_center = state.get("mu", realized)
			# 1. The concentration transform: the child's distribution centers on the parent's
			#    realized value and its core shrinks (never below the variance floor).
			var s2 := ParamDist.concentrate(state, realized, config)
			# 2. Matching convergence-helper NODES transform the distribution further (the
			#    per-parameter evolution-method-as-node seam).
			var ctx := {
				"param": pk, "node_type": t, "depth": int(s2.get("depth", 0)),
				"realized": realized, "prev_center": prev_center,
			}
			for h in helpers:
				if NodeGenomeHelpers.matches(h.get("when", {}), ctx):
					s2 = NodeGenomeHelpers.apply(h, s2, ctx)
			# 3. Redraw the child's value from the transformed distribution.
			params[pk] = ParamDist.draw(s2, config, rng)
			dists[pk] = s2
	if rng.randf() < float(config.get("p_structural", DEFAULT_EVOLVE_CONFIG["p_structural"])):
		_structural_op(child, rng)
	return NodeGenome.new(child, schema, config)

# ---------------------------------------------------------------------------------------------------
# recombine — COMBINATIONAL reshuffling across multiple evolutions (multi-parent)
# ---------------------------------------------------------------------------------------------------

## Recombine ANY number of parents from one generation: a base parent donates the structure;
## every variable node's params take a per-param donor among ALL parents carrying that node
## (same id + type) — value AND distribution state travel together, so a donated gene keeps its
## concentration history. Nodes unique to non-base parents splice in with probability splice_p
## (dangling connection-nodes are dropped by sanitation). Deterministic given `rng`.
static func recombine(parents: Array, rng: RandomNumberGenerator) -> NodeGenome:
	var ps := []
	for p in parents:
		if p is NodeGenome:
			ps.append(p)
	if ps.is_empty():
		return NodeGenome.new([])
	if ps.size() == 1:
		return (ps[0] as NodeGenome).clone()
	var base: NodeGenome = ps[rng.randi_range(0, ps.size() - 1)]
	var child := base._clone_nodes(base.nodes)
	for nd in child:
		if bool(nd.get("fixed", false)):
			continue
		var donors := []
		for p in ps:
			var other = (p as NodeGenome).find_node(String(nd.get("id", "")))
			if other != null and String((other as Dictionary).get("type", "")) == String(nd.get("type", "")):
				donors.append(other)
		if donors.size() <= 1:
			continue
		var params: Dictionary = nd.get("params", {})
		var dists: Dictionary = nd.get("dist", {})
		for pk in params.keys():
			var donor: Dictionary = donors[rng.randi_range(0, donors.size() - 1)]
			var dparams: Dictionary = donor.get("params", {})
			if dparams.has(pk):
				params[pk] = dparams[pk]
				var ddist: Dictionary = donor.get("dist", {})
				if ddist.has(pk):
					dists[pk] = (ddist[pk] as Dictionary).duplicate(true)
	var have_ids := {}
	for nd in child:
		have_ids[String(nd.get("id", ""))] = true
	var splice_p := float(base.config.get("splice_p", DEFAULT_EVOLVE_CONFIG["splice_p"]))
	for p in ps:
		if p == base:
			continue
		for nd2 in (p as NodeGenome).nodes:
			var nid := String((nd2 as Dictionary).get("id", ""))
			if not have_ids.has(nid) and rng.randf() < splice_p:
				child.append((nd2 as Dictionary).duplicate(true))
				have_ids[nid] = true
	return NodeGenome.new(child, base.schema, base.config)

## The 2-parent contract EvolverBreed/EvolverGenome call — a recombine of exactly two.
static func crossover(a: NodeGenome, b: NodeGenome, rng: RandomNumberGenerator) -> NodeGenome:
	return recombine([a, b], rng)

# ---------------------------------------------------------------------------------------------------
# distance — the convergence metric (normalized mean gene distance; structure mismatch = 1/gene)
# ---------------------------------------------------------------------------------------------------

## Normalized distance in [0, ~1]: matched nodes (by id + type) compare per-param (scalar:
## |a-b|/range; enum: 0/1); unmatched nodes on either side cost 1 each. Drives the convergence
## harness and the canvas UI's evolve-toward-target mode.
static func distance(a: NodeGenome, b: NodeGenome) -> float:
	var acc := 0.0
	var count := 0
	var types: Dictionary = a.schema.get("types", {})
	var matched_b := {}
	for nd in a.nodes:
		var nid := String(nd.get("id", ""))
		var other = b.find_node(nid)
		if other == null or String((other as Dictionary).get("type", "")) != String(nd.get("type", "")):
			acc += 1.0
			count += 1
			continue
		matched_b[nid] = true
		var pschema: Dictionary = (types.get(String(nd.get("type", "")), {}) as Dictionary).get("params", {})
		var pa: Dictionary = nd.get("params", {})
		var pb: Dictionary = (other as Dictionary).get("params", {})
		for pk in pschema.keys():
			var spec: Dictionary = pschema[pk]
			count += 1
			if spec.has("options"):
				acc += 0.0 if pa.get(pk) == pb.get(pk) else 1.0
			elif spec.has("min") and spec.has("max"):
				var range_w := maxf(float(spec["max"]) - float(spec["min"]), 1e-9)
				acc += absf(float(pa.get(pk, 0.0)) - float(pb.get(pk, 0.0))) / range_w
	for nd in b.nodes:
		if not matched_b.has(String(nd.get("id", ""))):
			acc += 1.0
			count += 1
	return acc / float(maxi(count, 1))

# ---------------------------------------------------------------------------------------------------
# structural reshuffle ops — VARIABLE nodes only; fixed nodes are untouchable
# ---------------------------------------------------------------------------------------------------

func _structural_op(child: Array, rng: RandomNumberGenerator) -> void:
	var op: String = ["add", "drop", "rewire", "swap"][rng.randi_range(0, 3)]
	var done := false
	match op:
		"add":
			done = _op_add(child, rng)
		"drop":
			done = _op_drop(child, rng)
		"rewire":
			done = _op_rewire(child, rng)
		"swap":
			done = _op_swap(child, rng)
	if not done:
		_op_add(child, rng)  # add is always possible — a structural op never silently no-ops

## Insert a random VARIABLE payload node + a connection-node linking it into the graph.
func _op_add(child: Array, rng: RandomNumberGenerator) -> bool:
	var types: Dictionary = schema.get("types", {})
	var payload_types := []
	var conn_types := []
	for t in types.keys():
		var spec: Dictionary = types[t]
		if bool(spec.get("is_connection", false)):
			conn_types.append(t)
		elif not bool(spec.get("is_helper", false)):
			payload_types.append(t)
	if payload_types.is_empty():
		return false
	var t: String = payload_types[rng.randi_range(0, payload_types.size() - 1)]
	var nid := _fresh_id(child, rng)
	child.append(_make_random_node(nid, t, types, config, rng))
	# Wire it in: one connection-node to a random existing payload node (direction random).
	var anchors := _payload_ids(child)
	anchors.erase(nid)
	if not conn_types.is_empty() and not anchors.is_empty():
		var ct: String = conn_types[rng.randi_range(0, conn_types.size() - 1)]
		var cn := _make_random_node(_fresh_id(child, rng), ct, types, config, rng)
		var anchor: String = anchors[rng.randi_range(0, anchors.size() - 1)]
		if rng.randf() < 0.5:
			cn["from"] = nid
			cn["to"] = anchor
		else:
			cn["from"] = anchor
			cn["to"] = nid
		child.append(cn)
	return true

## Drop a VARIABLE payload node (never the last one; never one a FIXED connection-node needs)
## plus every connection-node referencing it.
func _op_drop(child: Array, rng: RandomNumberGenerator) -> bool:
	var payload_total := _payload_ids(child).size()
	if payload_total <= 1:
		return false
	var pinned := {}  # ids a FIXED connection-node references — undropable
	for nd in child:
		if _is_connection(String(nd.get("type", ""))) and bool(nd.get("fixed", false)):
			pinned[String(nd.get("from", ""))] = true
			pinned[String(nd.get("to", ""))] = true
	var candidates := []
	for nd in child:
		var t := String(nd.get("type", ""))
		if _is_connection(t) or _is_helper(t):
			continue
		if bool(nd.get("fixed", false)) or pinned.has(String(nd.get("id", ""))):
			continue
		candidates.append(String(nd.get("id", "")))
	if candidates.is_empty():
		return false
	var victim: String = candidates[rng.randi_range(0, candidates.size() - 1)]
	for i in range(child.size() - 1, -1, -1):
		var nd: Dictionary = child[i]
		var t := String(nd.get("type", ""))
		if String(nd.get("id", "")) == victim:
			child.remove_at(i)
		elif _is_connection(t) and not bool(nd.get("fixed", false)) \
				and (String(nd.get("from", "")) == victim or String(nd.get("to", "")) == victim):
			child.remove_at(i)
	return true

## Retarget one endpoint of a VARIABLE connection-node to a different payload node.
func _op_rewire(child: Array, rng: RandomNumberGenerator) -> bool:
	var conns := []
	for nd in child:
		if _is_connection(String(nd.get("type", ""))) and not bool(nd.get("fixed", false)):
			conns.append(nd)
	var anchors := _payload_ids(child)
	if conns.is_empty() or anchors.size() < 2:
		return false
	var cn: Dictionary = conns[rng.randi_range(0, conns.size() - 1)]
	var side := "to" if rng.randf() < 0.5 else "from"
	var other_side := "from" if side == "to" else "to"
	var options := []
	for a in anchors:
		if a != String(cn.get(side, "")) and a != String(cn.get(other_side, "")):
			options.append(a)
	if options.is_empty():
		return false
	cn[side] = options[rng.randi_range(0, options.size() - 1)]
	return true

## Swap the list positions of two VARIABLE nodes (order is genotype).
func _op_swap(child: Array, rng: RandomNumberGenerator) -> bool:
	var idx := []
	for i in child.size():
		if not bool((child[i] as Dictionary).get("fixed", false)):
			idx.append(i)
	if idx.size() < 2:
		return false
	var i: int = idx[rng.randi_range(0, idx.size() - 1)]
	var j: int = idx[rng.randi_range(0, idx.size() - 1)]
	if i == j:
		j = idx[(idx.find(i) + 1) % idx.size()]
	if i == j:
		return false
	var tmp = child[i]
	child[i] = child[j]
	child[j] = tmp
	return true

# ---------------------------------------------------------------------------------------------------
# validity / sanitation — a genome only ever holds schema-valid nodes + resolvable connections
# ---------------------------------------------------------------------------------------------------

## Non-empty payload, every type known, every connection endpoint resolvable.
func is_valid() -> bool:
	var types: Dictionary = schema.get("types", {})
	if _payload_ids(nodes).is_empty():
		return false
	var ids := {}
	for nd in nodes:
		if typeof(nd) != TYPE_DICTIONARY or not types.has(String(nd.get("type", ""))):
			return false
		ids[String(nd.get("id", ""))] = true
	for nd in nodes:
		if _is_connection(String(nd.get("type", ""))):
			if not ids.has(String(nd.get("from", ""))) or not ids.has(String(nd.get("to", ""))):
				return false
	return true

## Coerce an arbitrary node array into valid nodes: drop unknown types, clamp/snap every declared
## param, keep provided dist states (init fresh ones for variable params missing state, centered
## on the coerced value), preserve fixed flags + endpoint refs + helper conditions, then drop
## connection-nodes with dangling endpoints (iterated to a fixpoint — a connection may reference
## another connection).
func _sanitize(raw: Array) -> Array:
	var types: Dictionary = schema.get("types", {})
	var out := []
	var auto_i := 0
	for nd in raw:
		if typeof(nd) != TYPE_DICTIONARY:
			continue
		var t := String(nd.get("type", ""))
		if not types.has(t):
			continue
		var spec: Dictionary = types[t]
		var pschema: Dictionary = spec.get("params", {})
		var nid := String(nd.get("id", ""))
		if nid == "":
			nid = "n_auto_%d" % auto_i
			auto_i += 1
		var fixed := bool(nd.get("fixed", false))
		var clean := { "id": nid, "type": t, "fixed": fixed, "params": {}, "dist": {} }
		var raw_p: Dictionary = nd.get("params", {})
		var raw_d: Dictionary = nd.get("dist", {})
		var cp: Dictionary = clean["params"]
		var cd: Dictionary = clean["dist"]
		for pk in pschema.keys():
			var ps: Dictionary = pschema[pk]
			cp[pk] = _coerce_param(ps, raw_p.get(pk, ps.get("default", null)))
			if raw_d.has(pk) and typeof(raw_d[pk]) == TYPE_DICTIONARY and (raw_d[pk] as Dictionary).has("kind"):
				cd[pk] = _coerce_dist_state(raw_d[pk])
			elif not fixed:
				cd[pk] = _init_dist(ps, cp[pk], config)
		if bool(spec.get("is_connection", false)):
			clean["from"] = String(nd.get("from", ""))
			clean["to"] = String(nd.get("to", ""))
		if nd.has("when") and typeof(nd["when"]) == TYPE_DICTIONARY:
			clean["when"] = (nd["when"] as Dictionary).duplicate(true)
		out.append(clean)
	# Fixpoint: drop connections whose endpoints are gone (dropping one may dangle another).
	var changed := true
	while changed:
		changed = false
		var ids := {}
		for nd in out:
			ids[String(nd.get("id", ""))] = true
		for i in range(out.size() - 1, -1, -1):
			var nd: Dictionary = out[i]
			if _is_connection(String(nd.get("type", ""))):
				if not ids.has(String(nd.get("from", ""))) or not ids.has(String(nd.get("to", ""))):
					out.remove_at(i)
					changed = true
	return out

# ---------------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------------

func _is_connection(t: String) -> bool:
	return bool(((schema.get("types", {}) as Dictionary).get(t, {}) as Dictionary).get("is_connection", false))

func _is_helper(t: String) -> bool:
	return bool(((schema.get("types", {}) as Dictionary).get(t, {}) as Dictionary).get("is_helper", false))

## Ids of payload (non-connection, non-helper) nodes in `list`.
func _payload_ids(list: Array) -> Array:
	var out := []
	for nd in list:
		var t := String((nd as Dictionary).get("type", ""))
		if not _is_connection(t) and not _is_helper(t):
			out.append(String((nd as Dictionary).get("id", "")))
	return out

func _fresh_id(list: Array, rng: RandomNumberGenerator) -> String:
	var ids := {}
	for nd in list:
		ids[String((nd as Dictionary).get("id", ""))] = true
	var nid := "n%08x" % rng.randi()
	while ids.has(nid):
		nid = "n%08x" % rng.randi()
	return nid

## A fresh VARIABLE node of type `t`: params sampled uniform, distributions initialized wide and
## centered on the sampled values (the configured starting shape).
static func _make_random_node(nid: String, t: String, types: Dictionary, cfg: Dictionary,
		rng: RandomNumberGenerator) -> Dictionary:
	var pschema: Dictionary = (types.get(t, {}) as Dictionary).get("params", {})
	var nd := { "id": nid, "type": t, "fixed": false, "params": {}, "dist": {} }
	var cp: Dictionary = nd["params"]
	var cd: Dictionary = nd["dist"]
	for pk in pschema.keys():
		var ps: Dictionary = pschema[pk]
		var v: Variant
		if ps.has("options"):
			var opts: Array = ps["options"]
			v = opts[rng.randi_range(0, opts.size() - 1)]
		elif ps.has("min") and ps.has("max"):
			var f := rng.randf_range(float(ps["min"]), float(ps["max"]))
			v = int(round(f)) if String(ps.get("type", "float")) == "int" else f
		else:
			v = ps.get("default", 0)
		cp[pk] = v
		cd[pk] = _init_dist(ps, v, cfg)
	return nd

static func _init_dist(ps: Dictionary, v: Variant, cfg: Dictionary) -> Dictionary:
	if ps.has("options"):
		return ParamDist.init_categorical(ps["options"], String(v), cfg)
	if ps.has("min") and ps.has("max"):
		return ParamDist.init_scalar(float(ps["min"]), float(ps["max"]), float(v),
			String(ps.get("type", "float")), cfg)
	return {}

## Re-type a distribution state after a JSON round-trip (JSON turns every number into a float;
## `depth` must stay int and the numeric fields float so serialization is byte-stable).
static func _coerce_dist_state(raw: Dictionary) -> Dictionary:
	var d := raw.duplicate(true)
	if d.has("depth"):
		d["depth"] = int(d["depth"])
	for k in ["lo", "hi", "mu", "sigma", "vel"]:
		if d.has(k):
			d[k] = float(d[k])
	if d.has("weights"):
		var w: Array = d["weights"]
		for i in w.size():
			w[i] = float(w[i])
	return d

static func _coerce_param(spec: Dictionary, value) -> Variant:
	if spec.has("options"):
		var opts: Array = spec["options"]
		if value != null and opts.has(value):
			return value
		return spec.get("default", opts[0] if opts.size() > 0 else "")
	if spec.has("min") and spec.has("max"):
		var v := clampf(float(value if value != null else spec.get("default", spec["min"])),
			float(spec["min"]), float(spec["max"]))
		if String(spec.get("type", "float")) == "int":
			return int(round(v))
		return v
	return value

## Deep-copy a node array (no shared sub-dicts between a parent genome and its children).
func _clone_nodes(src: Array) -> Array:
	var out := []
	for nd in src:
		if typeof(nd) == TYPE_DICTIONARY:
			out.append((nd as Dictionary).duplicate(true))
	return out
