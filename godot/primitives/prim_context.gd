class_name PrimContext
extends PrimChip
## A Context is the runtime realization of "communication is a module" (see
## COMMUNICATION-ARCHITECTURE.md). Like a Chip, it scopes a sub-arrangement; UNLIKE a Chip, it
## also supplies the *handler* that interprets HOW the modules inside it communicate. The SAME
## inner modules behave differently depending on the active Context — with zero change to the
## modules. Scenes, menus, simulations, and procedural generation are all Context handlers.
##
## This lives entirely in a MODULE, not the foundation: GraphRuntime gains nothing but a registry
## entry. The default handler reproduces a plain Chip exactly, so every existing arrangement is
## unaffected, and new disciplines are new handlers (new data), never foundation edits.
##
## params shape (extends Chip's { arrangement, ports }):
##   "handler":    "dataflow"|"gate"|"modulate"|"abstract"|"proximity"|"observer"|"tick"|"sim"|"event"|"wfc"|"connector"  (default "dataflow")
##   "modulation": { "<inner node id>": { "<param>": <value>, ... }, ... }   (handler "modulate")
##   "radius":     <float>   (handler "proximity": the static interaction range; default 1.0)
##   "lod_radius": <float>   (handler "observer": the static near/far LOD distance; default 1.0)
##   "steps":      <int>     (handlers "tick"/"sim"/"event": ticks to advance when it fires; default 1)
##   "wfc":        { width, height, tiles, adjacency }   (handler "wfc": the static generation ruleset — see the wfc section)
##   "channel":    "in_world"|"dev_console"|"external_bridge"  (handler "connector": which comm channel — see the connector section)
##   "routing"/"identity"/"interaction_pattern":  static envelope fields (handler "connector"; §2.4)
##   "live_dir":   <string>  (handler "connector", channel "external_bridge": the bridge file dir to reuse)
##
## Handlers:
##   dataflow  — synchronous pull, topo-ordered. Identical to a Chip. (The identity case.)
##   gate      — the "powered scope" (Dreams microchip power): the WHOLE scope only propagates
##               while the implicit boolean input port "enabled" is truthy; otherwise every output
##               is null (the scene/menu/sim is dormant). "act differently depending on context."
##   modulate  — overlays per-inner-node param overrides before evaluating, so the same inner
##               modules COMPUTE DIFFERENT VALUES under different Contexts. "different properties
##               depending on what is going on." Never mutates the source arrangement.
##   abstract  — "a primitive is a node you chose not to open": compute the (pure) scope ONCE and
##               shortcut to a content-addressed cache forever after. (See the section below.)
##   proximity — the SPATIAL gate: two modules communicate only when near. The scope propagates only
##               while the two implicit "vector" input ports "pos_a" and "pos_b" are within "radius"
##               of each other; otherwise the scope is dormant (every output null), exactly like a
##               disabled gate. This is the per-pair "use X on Y" 3D interaction — the SAME scope is
##               live or dormant purely as a function of where its endpoints are. It is the first
##               handler to realize the locked direction "the observer/spatial state is just an INPUT
##               a handler reads" (the later observer-driven abstract/LOD handler reads camera
##               distance the SAME way): position is dynamic → an input port; range is static → a param.
##   observer  — the OBSERVER-DRIVEN abstract / LOD gate: the spatial dual of `proximity`, but instead
##               of going DORMANT when far it COLLAPSES to its abstract content-addressed summary. The
##               handler reads two implicit "vector" inputs — the observer/camera position "observer_pos"
##               and the scope's own representative position "pos" — and a static "lod_radius" param.
##               WITHIN lod_radius (observer is close, you can see the detail) it runs the FULL live
##               dataflow scope; OUTSIDE it (observer is far, the detail isn't worth simulating) it
##               SHORTCUTS to the same compute-once content-addressed cache the `abstract` handler uses —
##               "a primitive is a node you chose not to open", now opened only when the observer is near
##               enough to care. This is the §2.5 deferred "observer/distance trigger (camera-driven LOD
##               abstraction)": the SAME scope is a live, re-simulatable arrangement up close and one
##               cached primitive at a distance, purely as a function of where the observer is (the locked
##               direction "the observer/spatial state is just an INPUT a handler reads"). Like `abstract`
##               it is SOUND only for a pure scope: an impure scope can't be cached, so it degrades to
##               running live every time at every distance (it never silently freezes a side effect).
##               Fail-safe: a missing observer or scope position (null) means "no LOD signal" → run live
##               (never collapse a scope we can't place — the conservative, detail-preserving default).
##   tick / sim — time-stepped propagation: advance the scope "steps" ticks, where each tick evaluates
##               the scope (State nodes supply their held values — the cycle-breaking sources) and then
##               commits each State's "next" input as its new held value. The two are the SAME stepping
##               core under two SEMANTICS, selectable per context (both ship — you pick by handler):
##                 tick — CONTINUOUS / living: State persists across outer evaluations, so the sim keeps
##                        evolving frame to frame (walk away and it kept running). Real-time worlds.
##                 sim  — REPRODUCIBLE / fresh: State is re-init to params.init before each outer
##                        evaluation, so the run is a PURE function (init, inputs, steps) → output, hence
##                        content-addressable — the substrate for precompute/bake + the abstract handler.
##   event     — PUSH, not pull: the scope re-propagates ONLY when a module FIRES this evaluation,
##               signalled by the implicit boolean input port "fire"; otherwise it is QUIESCENT and
##               re-emits its last pushed outputs without recomputing. This is the discipline of menus,
##               input, click-to-use, and triggers (a click event pushes downstream; nothing recomputes
##               between clicks), the dual of dataflow's "recompute on every read". It reuses the SAME
##               tick stepping core (a fire advances the scope `steps` ticks, committing State, exactly
##               like a CONTINUOUS `tick` — State persists across evaluations, so a push permanently
##               moves downstream state), but ONLY when fire is truthy: a quiescent evaluation runs zero
##               ticks and zero inner evaluations, so a downstream Log fires once PER event, never on the
##               idle frames between events. fire falsy/missing/unwired → quiescent (the rest state), so
##               an event scope idles until something actually fires it.
##   connector — COMMUNICATION WITH THE OUTSIDE WORLD (§2.4): an in-game chat seam whose far endpoint
##               is selected by the `channel` PARAM (DATA, not three hardcoded code paths). ONE handler,
##               three SELECTABLE modes — `in_world` (an in-scene Message inbox: messages flow between
##               Message nodes inside the running scene), `dev_console` (stdout + a console log: the dev
##               typing chat into the engine), `external_bridge` (an external Connector to a Claude Code
##               session, REUSING the existing bridge/ arrangement-file mechanism). It is a DUMB DELEGATE
##               over CommChannel (runtime/comm_channel.gd) + the Message envelope: it reads a Message
##               record from its implicit "message" input, sends it across the chosen channel as the
##               canonical §2.4 envelope {identity, routing, payload, interaction_pattern}, and emits the
##               sent/received envelope on its declared output ports. The SAME wired Message arrangement
##               routes differently purely by the channel param — "the same modules behave differently per
##               channel" — with ZERO change to the Message nodes. Negotiate-and-fail-loudly (§2.4, the ROS
##               QoS lesson): an unconfigured/unknown channel emits a SURFACED diagnostic envelope, never a
##               silent no-op. Adding a medium is one CommChannel arm, never a foundation edit.
##   wfc       — PROCEDURAL GENERATION (wave-function-collapse): the first GENERATOR handler. Unlike the
##               handlers above it has NO inner arrangement; it collapses a grid against a static tile-
##               adjacency ruleset (params.wfc) seeded by the implicit "seed" input and emits the
##               collapsed grid to its declared output ports. "Procedural generation is a Context handler"
##               made concrete — same locked posture as proximity/observer (the seed is a dynamic INPUT,
##               the ruleset a static PARAM), and a pure function of (ruleset, seed) → grid, so the SAME
##               seed always reproduces the SAME structure. The "tag a generated structure's rules
##               local/global" and "convert a generated structure to a single unitary node on manual
##               review" steps are SUPERVISED GUI work, surfaced separately, not built into the handler.

# Process-wide memoization store for the `abstract` handler, keyed by a hermetic content-hash of
# (effective arrangement + handler + canonical inputs). Process-wide (not per-instance) so two
# Contexts wrapping the SAME pure arrangement share one computed result — the cross-instance reuse
# that makes abstraction pay off at scale (a garden's many identical plants compute once). The
# in-memory Dictionary is the MVP; a content-addressed on-disk store is its drop-in successor behind
# the same key. NON-DESTRUCTIVE: a summary is a derived cache entry beside the retained
# params.arrangement, never a replacement — the openable graph is always preserved (append-only).
static var _summaries: Dictionary = {}
# Count of REAL super.evaluate() runs through the abstract path — test observability for
# compute-once-then-shortcut (and a coarse cache-effectiveness signal). Not load-bearing.
static var _evals: int = 0

# The `event` handler's last PUSHED outputs (per instance). A quiescent (un-fired) evaluation re-emits
# this instead of recomputing — the "nothing re-propagates between events" rest state. Null until the
# first fire, so an event scope that has never fired emits all-null outputs (the menu/trigger has not
# fired yet → no downstream value). Instance state lives in the MODULE, never the floor — same posture
# as State._held and PrimChip._sub.
var _last_event_outputs: Variant = null

func _init() -> void:
	prim_type = "Context"

func _handler() -> String:
	return String(params.get("handler", "dataflow"))

## "gate" adds an implicit boolean "enabled" input beyond the Chip's mapped ports; "proximity" adds
## the two implicit "vector" inputs "pos_a"/"pos_b"; "observer" adds the two implicit "vector" inputs
## "observer_pos"/"pos"; other handlers expose exactly the Chip's ports. These handler-implicit names
## ("enabled", "pos_a", "pos_b", "observer_pos", "pos", "fire") are RESERVED: if a scope also maps an
## inner port of the same name, both appear here (the handler reads its own; the mapped one still
## feeds its inner site). Whether handler-implicit ports should live in a separate namespace from
## mapped ports is a cross-cutting decision deferred across the whole handler family, not settled here.
func input_ports() -> Array:
	var ports: Array = super.input_ports()
	match _handler():
		"gate":
			ports = ports.duplicate()
			ports.append({ "name": "enabled", "type": "bool" })
		"proximity":
			ports = ports.duplicate()
			ports.append({ "name": "pos_a", "type": "vector" })
			ports.append({ "name": "pos_b", "type": "vector" })
		"observer":
			ports = ports.duplicate()
			ports.append({ "name": "observer_pos", "type": "vector" })
			ports.append({ "name": "pos", "type": "vector" })
		"event":
			ports = ports.duplicate()
			ports.append({ "name": "fire", "type": "bool" })
		"wfc":
			# The implicit "seed" input is the DYNAMIC part of a deterministic generator (position-like:
			# dynamic -> an input, exactly as proximity reads positions; the ruleset -- tiles + adjacency +
			# dimensions -- is STATIC -> a param). A missing/unwired seed defaults to 0 (a stable scene), so
			# an unwired WFC Context still generates deterministically rather than failing.
			ports = ports.duplicate()
			ports.append({ "name": "seed", "type": "number" })
		"connector":
			# The implicit "message" input carries the DYNAMIC payload to send across the seam — a Message
			# record (the Message primitive's "reply" output is exactly this), wired in like any port. The
			# channel + routing + interaction_pattern are STATIC params (same posture as wfc's ruleset). A
			# missing message means "receive only" (the handler reads from the channel instead of sending).
			ports = ports.duplicate()
			ports.append({ "name": "message", "type": "message" })
	return ports

func evaluate(inputs: Dictionary) -> Dictionary:
	match _handler():
		"gate":
			if not _truthy(inputs.get("enabled")):
				return _outputs_null()
			return super.evaluate(inputs)
		"proximity":
			if not _within_proximity(inputs):
				return _outputs_null()
			return super.evaluate(inputs)
		"observer":
			return _evaluate_observer(inputs)
		"tick":
			return _evaluate_sim(inputs, true)
		"sim":
			return _evaluate_sim(inputs, false)
		"event":
			return _evaluate_event(inputs)
		"modulate":
			return _evaluate_modulated(inputs)
		"abstract":
			return _evaluate_abstract(inputs)
		"wfc":
			return _evaluate_wfc(inputs)
		"connector":
			return _evaluate_connector(inputs)
		_:
			# "dataflow" and any unknown handler degrade to a plain Chip (forward-compatible:
			# an unrecognized future handler still runs as ordinary dataflow rather than failing).
			return super.evaluate(inputs)

# --- gate ------------------------------------------------------------------------------------

## Every declared output port -> null. The scope is dormant; nothing inside propagates.
func _outputs_null() -> Dictionary:
	var out := {}
	for p in (params.get("ports", {}) as Dictionary).get("outputs", []):
		out[String(p.get("name"))] = null
	return out

func _truthy(v) -> bool:
	if v == null:
		return false
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return v != 0
		TYPE_STRING:
			return v != "" and v != "false" and v != "0"
	return true

# --- proximity (the spatial gate: "use X on Y" only when near) -------------------------------

## True iff the two implicit position inputs are within `radius` of each other. The condition is
## computed entirely from INPUTS (the dynamic spatial state) and one static param (the range), so the
## SAME scope is live or dormant purely as a function of where its endpoints are — the per-pair 3D
## interaction. Fail-safe: a missing / unconnected position (null) means "not near" → dormant, so an
## unwired endpoint never spuriously fires an interaction. Distance is compared SQUARED against the
## squared radius (no sqrt — exact for the <= test and avoids a needless float op). Radius is clamped
## to >= 0 so a stray negative range degrades to "coincident only", never to its absolute value.
func _within_proximity(inputs: Dictionary) -> bool:
	var a := _as_vec(inputs.get("pos_a"))
	var b := _as_vec(inputs.get("pos_b"))
	if a.is_empty() or b.is_empty():
		return false
	# Treat an explicit null radius the same as a missing one (→ the 1.0 default), matching gate's
	# explicit-null handling — float(null) would otherwise silently become 0.0 (coincident-only).
	var rv = params.get("radius")
	var r: float = 1.0 if rv == null else maxf(0.0, Primitive.as_num(rv))
	return _vec_sq_distance(a, b) <= r * r

## Coerce a wire value to an Array of floats (the renderer-neutral position form — Phase 2.5 says
## everything over a port is serializable data, so positions are plain number arrays). A native Godot
## Vector2/3/4 (should a 3D-scene node emit one) is also accepted and flattened. null / anything else
## → [] (treated by the caller as "no position" → not near).
func _as_vec(v) -> Array:
	match typeof(v):
		TYPE_ARRAY:
			var out: Array = []
			for e in (v as Array):
				out.append(Primitive.as_num(e))
			return out
		TYPE_VECTOR2:
			return [v.x, v.y]
		TYPE_VECTOR3:
			return [v.x, v.y, v.z]
		TYPE_VECTOR4:
			return [v.x, v.y, v.z, v.w]
	return []

## Squared Euclidean distance over the MAX of the two dimensions — a lower-dim point is embedded in
## the higher-dim space with the missing components at 0 (a 2D point is a 3D point at z=0), the
## least-surprising rule, rather than silently dropping a dimension.
func _vec_sq_distance(a: Array, b: Array) -> float:
	var n: int = maxi(a.size(), b.size())
	var sum := 0.0
	for i in n:
		var ai: float = a[i] if i < a.size() else 0.0
		var bi: float = b[i] if i < b.size() else 0.0
		var d := ai - bi
		sum += d * d
	return sum

# --- observer (observer-driven abstract / LOD: live up close, cached at a distance) ----------

## The OBSERVER-DRIVEN abstract/LOD gate. The spatial dual of `proximity` (it reads positions as
## INPUTS the SAME way) but, instead of going dormant when far, it COLLAPSES the scope to its
## content-addressed summary:
##   observer WITHIN lod_radius  → run the FULL live dataflow scope (you're close → render the detail);
##   observer OUTSIDE lod_radius → SHORTCUT to the compute-once cache (you're far → consume the
##                                 abstracted primitive instead of re-simulating).
## This is "a primitive is a node you chose not to open", opened only when the observer is near enough
## to care — the §2.5 deferred "observer/distance trigger (camera-driven LOD abstraction)". The cache
## is the SAME process-wide store + purity gate the `abstract` handler uses, so the two share the
## compute-once-then-shortcut machinery (a distant scope is computed once, then every later distant
## evaluation hits the cache). Soundness inherits from `abstract`: an impure scope can't be cached →
## it degrades to running LIVE at every distance (never silently freezes a side effect). The LOD
## decision is computed entirely from INPUTS (observer + scope position) + one static param
## (lod_radius), exactly like proximity — position is dynamic, range is static.
func _evaluate_observer(inputs: Dictionary) -> Dictionary:
	# Near (or no LOD signal) → run the full live scope. A missing observer/scope position is the
	# fail-safe "we can't place this scope" case → DON'T collapse it (the detail-preserving default).
	if _observer_is_near(inputs):
		return super.evaluate(inputs)
	# Far → consume the abstracted primitive. Same purity gate as `abstract`: a non-pure scope can't be
	# memoized, so it falls through to a live run rather than caching a side effect.
	if not _scope_is_cacheable():
		return super.evaluate(inputs)
	var key := _observer_cache_key(inputs)
	if _summaries.has(key):
		# Private copy: the process-wide cache holds references, so hand out a duplicate (same posture
		# as the abstract handler) — a downstream read-then-write can't corrupt other sharers of the key.
		return (_summaries[key] as Dictionary).duplicate(true)
	_evals += 1
	var fresh: Dictionary = super.evaluate(inputs)
	_summaries[key] = fresh.duplicate(true)
	return fresh

## True iff the observer is within `lod_radius` of the scope's representative position — OR either
## position is missing (the fail-safe "no LOD signal → stay live" case, so an unplaced scope is never
## wrongly collapsed). Mirrors `_within_proximity` exactly (squared distance, no sqrt; lod_radius
## clamped >= 0; explicit-null radius → the 1.0 default), differing only in the missing-position
## branch: proximity treats "no position" as DORMANT, observer treats it as STAY-LIVE — the opposite
## fail-safe, because here "can't tell" must preserve detail, not discard it.
func _observer_is_near(inputs: Dictionary) -> bool:
	var o := _as_vec(inputs.get("observer_pos"))
	var p := _as_vec(inputs.get("pos"))
	if o.is_empty() or p.is_empty():
		return true   # no LOD signal → run live (never collapse a scope we can't place)
	var rv = params.get("lod_radius")
	var r: float = 1.0 if rv == null else maxf(0.0, Primitive.as_num(rv))
	return _vec_sq_distance(o, p) <= r * r

## Hermetic content-address for the OBSERVER cache. Identical construction to `_cache_key` (arrangement
## + ports + canonical inputs hashes) but with an "observer:" tag so observer and abstract entries NEVER
## collide in the shared `_summaries` store — and so this handler's precondition (the abstract key's
## "reached solely from the abstract arm" note) stays honest. The observer/scope POSITIONS and lod_radius
## are deliberately OMITTED from the key: they decide near-vs-far, NOT the cached OUTPUT (the
## handler-reserved "observer_pos"/"pos" feed the LOD test, not any inner mapped site), so two distant
## evaluations of the same pure scope under different far-away observer positions correctly share ONE
## summary — the same reasoning that excludes proximity's positions/radius from the abstract key. Only
## the scope's MAPPED inputs (the ones PrimChip actually feeds inner sites) enter the key, so the cache
## stays exact (no wrong hit) without fragmenting on the observer's whereabouts.
func _observer_cache_key(inputs: Dictionary) -> String:
	var arr_hash := JSON.stringify(params.get("arrangement", {})).sha256_text()
	var ports_hash := JSON.stringify(params.get("ports", {})).sha256_text()
	var mapped := inputs.duplicate()
	mapped.erase("observer_pos")   # handler-reserved LOD inputs — not part of the cached output
	mapped.erase("pos")
	var in_hash := _canonical_inputs(mapped).sha256_text()
	return "observer:%s:%s:%s" % [arr_hash, ports_hash, in_hash]

# --- tick / sim (time-stepped propagation; State is the cross-tick memory) --------------------

## Advance the scope `steps` ticks and return its mapped outputs. Reuses the inherited PERSISTENT
## inner runtime (PrimChip._sub), so State nodes keep their held values across ticks — and, for
## `tick` (persist == true), across outer evaluations too (a living sim). `sim` (persist == false)
## re-inits every State to params.init first, making each run a pure, content-addressable function.
## Each tick: evaluate the scope (State outputs are the cycle-breaking sources) → commit each State's
## "next". Outputs are then read WITHOUT a re-evaluate (State ports via current(), derived ports from
## the final tick's outputs), so an inner side-effecting node fires exactly `steps` times, never +1.
func _evaluate_sim(inputs: Dictionary, persist: bool) -> Dictionary:
	var arr: Dictionary = params.get("arrangement", {})
	# Load a DAG with the State feedback wires REMOVED so every State node is an unambiguous SOURCE
	# (indegree 0) — the inner topo-sort then always evaluates a State before its consumers, regardless
	# of node declaration order. The original feedback wires drive the separate commit step. This keeps
	# the floor's generic topo-sort untouched (no special-casing of State in GraphRuntime).
	var dag := _strip_state_feedback(arr)
	if _sub == null:
		_sub = GraphRuntime.new()
		add_child(_sub)
	var pr := get_parent()
	_sub.depth = ((pr as GraphRuntime).depth if pr is GraphRuntime else 0) + 1
	# Diff-hotload keeps existing State instances (and their held values) across calls — load never
	# resets _held — so continuity survives a reload; reproducibility is an explicit reset, not a rebuild.
	_sub.load_arrangement(dag)
	if not persist:
		_reset_states()
	# Map the scope's incoming ports to their inner sites; held constant for the whole step run.
	var ports: Dictionary = params.get("ports", {})
	var ext := {}
	for p in ports.get("inputs", []):
		var nid := String(p.get("node"))
		if not ext.has(nid):
			ext[nid] = {}
		ext[nid][String(p.get("port"))] = inputs.get(String(p.get("name")))
	_sub.set_external_inputs(ext)
	var steps: int = maxi(0, int(Primitive.as_num(params.get("steps", 1))))
	# Advance `steps` ticks. There is deliberately NO post-loop observational evaluate — that would
	# re-run the whole DAG and re-fire any inner side-effecting node, so an inner Log would log steps+1
	# times. Instead, post-step state is read directly below. (steps == 0 → no tick runs: State outputs
	# resolve to their init via current(); a derived output stays null until at least one tick runs.)
	var outs := {}
	for _i in steps:
		outs = _sub.evaluate()
		_commit_states(arr, outs)
	# Read outputs WITHOUT re-running the DAG: a State output port reports its COMMITTED held value
	# (current(), side-effect-free); any other (derived) port reflects the final tick's computed value.
	var result := {}
	for p in ports.get("outputs", []):
		var node_id := String(p.get("node"))
		var prim = _sub.nodes.get(node_id)
		if prim != null and prim.has_method("current"):
			result[String(p.get("name"))] = prim.current()
		else:
			var src: Dictionary = outs.get(node_id, {})
			result[String(p.get("name"))] = src.get(String(p.get("port")))
	return result

## A deep copy of `arr` with every wire feeding a State node's "next" port dropped, so State nodes are
## pure sources in the inner DAG. Pure data → data; never mutates the source arrangement.
func _strip_state_feedback(arr: Dictionary) -> Dictionary:
	var state_ids := {}
	for n in arr.get("nodes", []):
		if String(n.get("type")) == "State":
			state_ids[String(n.get("id"))] = true
	var out: Dictionary = arr.duplicate(true)
	var kept := []
	for w in out.get("wires", []):
		if state_ids.has(String(w.get("to"))) and String(w.get("in")) == "next":
			continue
		kept.append(w)
	out["wires"] = kept
	return out

## At a tick boundary, hand each State node the value arriving at its "next" input THIS tick (read
## from the just-computed outputs via the scope's ORIGINAL wires, feedback included). A State with no
## "next" wire holds constant. Only nodes exposing commit() (State) are touched — others are pure.
func _commit_states(arr: Dictionary, outs: Dictionary) -> void:
	var wires: Array = arr.get("wires", [])
	for node_id in _sub.nodes:
		var prim = _sub.nodes[node_id]
		if not prim.has_method("commit"):
			continue
		for w in wires:
			if String(w.get("to")) == node_id and String(w.get("in")) == "next":
				var from_id := String(w.get("from"))
				if not outs.has(from_id):
					# Broken feedback wire (the "next" source node is absent from the scope). Don't
					# silently corrupt the held value with null — warn and preserve it. A source that
					# IS present but legitimately yields null still commits below.
					push_warning("PrimContext[sim]: State '%s' next-source '%s' missing — commit skipped" % [node_id, from_id])
					break
				prim.commit((outs.get(from_id, {}) as Dictionary).get(String(w.get("out"))))
				break

## Restore every State node to params.init (the reproducible `sim` handler calls this before stepping).
func _reset_states() -> void:
	for node_id in _sub.nodes:
		var prim = _sub.nodes[node_id]
		if prim.has_method("reset_state"):
			prim.reset_state()

# --- event (PUSH: re-propagate only when a module fires) -------------------------------------

## PUSH propagation. The scope re-propagates ONLY when the implicit boolean "fire" input is truthy
## THIS evaluation; otherwise it is QUIESCENT and re-emits its last pushed outputs without recomputing.
##   fire truthy  → a module fired: advance the scope by the CONTINUOUS tick core (persist == true), so
##                  the push commits State and permanently moves downstream state, exactly like one
##                  `tick`. The freshly-computed outputs are cached as the new "last pushed" and returned.
##   fire falsy   → no event this frame: run ZERO inner evaluations (so a downstream Log fires once PER
##                  event, never on the idle frames between) and re-emit the last pushed outputs. Before
##                  the first fire there is no history → all-declared-outputs null (the menu/trigger has
##                  not fired yet). This is the rest state that makes "only downstream re-propagates when
##                  something fires" true: between events nothing recomputes.
## Reusing the tick stepping core (not a parallel propagator) is the whole point — `event` is `tick`
## conditioned on a fire signal, so State-as-memory and the no-observational-re-evaluate discipline are
## inherited unchanged; the ONLY addition is the fire gate + the quiescent re-emit.
func _evaluate_event(inputs: Dictionary) -> Dictionary:
	if not _truthy(inputs.get("fire")):
		# Quiescent: re-emit the last pushed outputs (a private copy if a dict, so a downstream
		# read-then-write caller can't corrupt the retained snapshot), or all-null before the first fire.
		if _last_event_outputs == null:
			return _outputs_null()
		if typeof(_last_event_outputs) == TYPE_DICTIONARY:
			return (_last_event_outputs as Dictionary).duplicate(true)
		return _last_event_outputs
	# Fired: push one continuous-tick advance through the scope and remember the result.
	var fired: Dictionary = _evaluate_sim(inputs, true)
	_last_event_outputs = fired.duplicate(true)
	return fired

# --- modulate --------------------------------------------------------------------------------

## Evaluate the inner arrangement with per-node param overrides overlaid. Builds a deep COPY of
## the arrangement so the shared source spec is never mutated, swaps it in only for the duration
## of the super-eval, then restores it.
func _evaluate_modulated(inputs: Dictionary) -> Dictionary:
	var modulation: Dictionary = params.get("modulation", {})
	if modulation.is_empty():
		return super.evaluate(inputs)
	var base_arr: Dictionary = params.get("arrangement", {})
	var mod_arr := _overlay_params(base_arr, modulation)
	var saved = params.get("arrangement")
	params["arrangement"] = mod_arr
	var result: Dictionary = super.evaluate(inputs)
	params["arrangement"] = saved
	return result

## A deep copy of `arr` where each node whose id is a key in `modulation` has those params overlaid
## over its own. Pure data -> data; never touches `arr`.
func _overlay_params(arr: Dictionary, modulation: Dictionary) -> Dictionary:
	var out: Dictionary = arr.duplicate(true)
	for n in out.get("nodes", []):
		var nid := String(n.get("id"))
		if modulation.has(nid):
			var p = n.get("params", {})
			if not (p is Dictionary):
				p = {}
			for k in (modulation[nid] as Dictionary):
				p[k] = modulation[nid][k]
			n["params"] = p
	return out

# --- abstract ("a primitive is a node you chose not to open") --------------------------------

## Treat this scope as a PRIMITIVE with cached, content-addressed properties instead of re-running
## it. The first evaluation for a given content-address runs the real recursive dataflow once and
## stores the result; every later evaluation with the same key SHORTCUTS to the stored result
## (compute-once-then-shortcut). This is the runtime form of scale-independent abstraction: the
## stored result IS the scope's behavior summary, so a node built from interacting sub-nodes is
## consumed at larger scale as one coherent primitive.
##
## SOUND ONLY for a pure scope: if ANY inner node is not is_cacheable(), this DEGRADES to a plain
## Chip (runs live every time) — so abstraction never silently freezes a side effect or orphans a
## renderer-bound live instance. Re-expansion in the MVP is just "clear the cache".
func _evaluate_abstract(inputs: Dictionary) -> Dictionary:
	if not _scope_is_cacheable():
		return super.evaluate(inputs)
	var key := _cache_key(inputs)
	if _summaries.has(key):
		# Return a PRIVATE copy. The cache is process-wide and GDScript dicts are references, so
		# handing the cached dict out directly would let any future read-then-write caller corrupt
		# every other node sharing the key. Outputs are plain serializable data → the copy is cheap.
		return (_summaries[key] as Dictionary).duplicate(true)
	_evals += 1
	var fresh: Dictionary = super.evaluate(inputs)
	_summaries[key] = fresh.duplicate(true)
	return fresh

## True iff EVERY node in the scope opts in to memoization (Primitive.is_cacheable()). A throwaway
## runtime resolves each node's type to its declared cacheability — so the rule respects each
## primitive's own contract and extends automatically as new cacheable primitives are added. (An
## unknown / unresolvable type is treated as non-cacheable: fail safe.)
func _scope_is_cacheable() -> bool:
	var arr: Dictionary = params.get("arrangement", {})
	var nodes_list: Array = arr.get("nodes", [])
	if nodes_list.is_empty():
		return false
	var probe := GraphRuntime.new()
	var ok := true
	for n in nodes_list:
		var prim: Primitive = probe._instance(String(n.get("type")))
		var cacheable := prim != null and prim.is_cacheable()
		if prim != null:
			prim.free()
		if not cacheable:
			ok = false
			break
	probe.free()
	return ok

## Hermetic content-address: EVERY input that affects the output is in the key — the inner
## arrangement, the PORTS map (PrimChip.evaluate feeds inputs to inner sites and reads outputs FROM
## inner sites via params.ports, so two scopes with the same arrangement but a different port map
## compute different outputs and must NOT share a key), the "abstract:" tag (so keys never cross
## handlers), and the canonicalized inputs (so equal inputs hash equal). Reuses the same
## String.sha256_text() idiom as live_host.gd / chip_ops.gd. NOTE: this handler ignores
## params.modulation — `abstract` and `modulate` are separate match arms and must not be composed
## until the key folds in the overlay; the worst case of the JSON-stringify key (insertion-order
## sensitivity) is a missed hit, never a wrong hit. PRECONDITION (handler exclusivity): the key omits
## the handler name and handler-specific params (proximity's "radius", modulate's "modulation") — sound
## ONLY because a Context picks exactly ONE handler via _handler(), so this cache is reached solely from
## the abstract arm. If handler composition is ever added, fold handler identity + its params in here.
func _cache_key(inputs: Dictionary) -> String:
	var arr_hash := JSON.stringify(params.get("arrangement", {})).sha256_text()
	var ports_hash := JSON.stringify(params.get("ports", {})).sha256_text()
	var in_hash := _canonical_inputs(inputs).sha256_text()
	return "abstract:%s:%s:%s" % [arr_hash, ports_hash, in_hash]

## A stable string for an inputs dict: keys sorted so two equal-valued dicts produce equal strings.
func _canonical_inputs(inputs: Dictionary) -> String:
	var keys: Array = inputs.keys()
	keys.sort()
	var parts := []
	for k in keys:
		parts.append("%s=%s" % [String(k), JSON.stringify(inputs[k])])
	return "|".join(PackedStringArray(parts))

# --- connector (in-game chat seam: 3 selectable channels over the §2.4 envelope) -------------------

## The CONNECTOR handler — communication with the outside world (COMMUNICATION-ARCHITECTURE.md §2.4),
## as an in-game chat seam with a SELECTABLE `channel` mode. This is a DUMB DELEGATE over CommChannel
## (runtime/comm_channel.gd) + the Message envelope: the THREE modes (in_world / dev_console /
## external_bridge) are ONE module reading the `channel` PARAM (DATA), never three hardcoded foundation
## code paths. The SAME wired Message arrangement routes differently purely by the channel value — "the
## same modules behave differently per channel" — with ZERO change to the Message nodes feeding it.
##
## DATA in -> DATA out: the dynamic payload is the implicit "message" input (a Message record — exactly
## the Message primitive's "reply" output); the channel + routing + identity + interaction_pattern are
## STATIC params. The handler SENDS the message across the chosen channel as the canonical §2.4 envelope
## {identity, routing, payload, interaction_pattern} and publishes the result to the scope's DECLARED
## output ports by name:
##   "sent"      -> the envelope that crossed the seam (so a downstream node sees exactly what was sent);
##   "received"  -> the latest envelope read back FROM the channel (the receive verb — how a reply
##                  returns, e.g. the far Claude-Code endpoint's Message over external_bridge);
##   "envelope"  -> alias of "sent" (a single-port convenience for a one-way send-only seam).
## With NO "message" input wired, the seam is RECEIVE-ONLY: it reads from the channel and publishes
## "received" (a console/inbox/bridge poll). A declared port outside {sent, received, envelope} gets null.
##
## NEGOTIATE-AND-FAIL-LOUDLY (§2.4, the ROS QoS lesson): an unconfigured / unknown / closed channel makes
## CommChannel return a SURFACED diagnostic envelope ({ok:false, error, diagnostic}); that diagnostic is
## published on the output ports verbatim, so a downstream Log shows exactly what refused and why — NEVER
## a silent no-op. The channel-specific runtime config (the in-world inbox Array, the console log Array,
## the external bridge live_dir) is read from params so the handler holds no foundation state.
func _evaluate_connector(inputs: Dictionary) -> Dictionary:
	var channel := String(params.get("channel", ""))
	var config := _connector_config()
	# The dynamic payload: a Message record arriving on the implicit "message" input. Null/unwired ->
	# receive-only (read from the channel instead of sending).
	var message = inputs.get("message")
	var sent_env
	var recv_env
	if message != null:
		sent_env = CommChannel.send(channel, message, config)
		# A request_reply / round-trip seam also reads the reply back; one_way leaves received null.
		if String(params.get("interaction_pattern", "one_way")) != "one_way":
			recv_env = CommChannel.receive(channel, config)
	else:
		recv_env = CommChannel.receive(channel, config)
	# Publish to the DECLARED output ports by name (same enumeration as _outputs_null / _evaluate_wfc).
	var out := {}
	for p in (params.get("ports", {}) as Dictionary).get("outputs", []):
		var nm := String(p.get("name"))
		match nm:
			"sent", "envelope":
				out[nm] = sent_env
			"received":
				out[nm] = recv_env
			_:
				out[nm] = null
	return out

## Assemble the channel config dict CommChannel reads: the static envelope fields (routing/identity/
## interaction_pattern) plus the channel-specific runtime config (the in-world inbox, the console log,
## the external bridge live_dir) — all carried in params so the handler holds no foundation state. The
## inbox / console_log are passed BY REFERENCE (GDScript Arrays are references), so send/receive mutate
## the same in-scene buffer the rest of the arrangement shares — the in-world chat surface.
func _connector_config() -> Dictionary:
	var config := {
		"routing": params.get("routing", ""),
		"identity": params.get("identity", ""),
		"interaction_pattern": params.get("interaction_pattern", "one_way"),
		"live_dir": params.get("live_dir", ""),
	}
	if params.get("inbox") is Array:
		config["inbox"] = params.get("inbox")
	if params.get("console_log") is Array:
		config["console_log"] = params.get("console_log")
	return config

# --- wfc (wave-function-collapse procedural generation: a deterministic generator handler) ---------

## The WFC (wave-function-collapse) generator. Unlike the dataflow-derived handlers above (which run
## or memoize an inner ARRANGEMENT), `wfc` is a pure GENERATOR: it collapses a grid of cells against a
## tile-adjacency ruleset and emits the collapsed grid as data, with NO inner arrangement required. It
## is "procedural generation is a Context handler" (COMMUNICATION-ARCHITECTURE.md, the procedural row)
## made concrete -- the same locked posture as proximity/observer ("the dynamic state is just an INPUT a
## handler reads"): the seed is dynamic so it is the implicit "seed" INPUT; the ruleset (tiles + adjacency
## + dimensions) is static so it is a PARAM. The result is a pure function of (ruleset, seed) -> grid, so
## the SAME seed always collapses to the SAME grid (content-addressable, headless-reproducible, the
## substrate for the "convert a generated structure to a single unitary node" review step -- which is a
## SUPERVISED GUI step, not built here). Determinism is total: a seeded RNG (RandomNumberGenerator) + a
## fixed cell scan order + lexicographic tie-breaks, so no run-to-run wobble.
##
## params.wfc shape (all under params["wfc"]):
##   "width":   <int>     grid columns (default 4; clamped >= 1)
##   "height":  <int>     grid rows    (default 4; clamped >= 1)
##   "tiles":   [ { "name": <string>, "weight": <number?> }, ... ]   the alphabet (weight default 1.0)
##              OR the shorthand [ "<name>", ... ] (each weight 1.0).
##   "adjacency": { "<dir>": { "<tileA>": ["<tileB>", ...], ... }, ... }
##              per-direction allow-lists: tileB may sit in direction <dir> of tileA. Directions are the
##              4-neighbourhood "right"/"left"/"down"/"up". An omitted direction is auto-completed as the
##              OPPOSITE of its partner (right<->left, down<->up) so a ruleset need only state half of each
##              pair; an omitted pair entirely means "no constraint in that axis" (everything allowed),
##              the least-surprising open default.
##
## Outputs: the Context's DECLARED output ports (params.ports.outputs) receive the result by NAME --
##   "grid"          -> the collapsed grid as a row-major Array of rows, each row an Array of tile-name
##                      strings (the canonical generated structure).
##   "contradiction" -> bool: true iff propagation wiped a cell's whole domain (an over-constrained
##                      ruleset). A contradiction is REPORTED, never thrown -- the grid is still emitted
##                      with the contradicted cell(s) left empty ("") so a caller sees exactly where it
##                      failed (fail-soft, detail-preserving, like every other handler's fail-safe).
##   "collapses"     -> int: how many cells the generator explicitly OBSERVED/collapsed (1..width*height).
##                      Constraint propagation then decides further cells for free, so on a constrained
##                      ruleset this is BELOW width*height (a strongly-constrained ruleset fills the whole
##                      grid from a few observations) -- a coarse "how much was forced vs chosen" signal,
##                      mirroring the abstract handler's `_evals`. The grid is still fully filled.
## Any declared port not in {grid, contradiction, collapses} receives null. If a scope declares NO
## outputs, the result is still computed and the empty outputs dict returned, exactly like a no-output Chip.
func _evaluate_wfc(inputs: Dictionary) -> Dictionary:
	var cfg: Dictionary = params.get("wfc", {})
	var w: int = maxi(1, int(Primitive.as_num(cfg.get("width", 4))))
	var h: int = maxi(1, int(Primitive.as_num(cfg.get("height", 4))))
	var tiles := _wfc_tiles(cfg)
	var adjacency := _wfc_adjacency(cfg, tiles)
	# seed: dynamic input. Missing/null -> 0 (a stable default scene). Coerced to a stable int so floats
	# that are equal-as-numbers (1.0 vs 1) seed identically.
	var seed := int(Primitive.as_num(inputs.get("seed", 0)))
	var res := _wfc_collapse(w, h, tiles, adjacency, seed)
	# Emit to the DECLARED output ports by name (same enumeration as _outputs_null). A port whose name is
	# not a known WFC field gets null -- the result is published only through ports the scope asked for.
	var out := {}
	for p in (params.get("ports", {}) as Dictionary).get("outputs", []):
		var nm := String(p.get("name"))
		match nm:
			"grid":
				out[nm] = res.get("grid")
			"contradiction":
				out[nm] = res.get("contradiction")
			"collapses":
				out[nm] = res.get("collapses")
			_:
				out[nm] = null
	return out

## Normalize params.wfc.tiles to an ordered Array of { name, weight }. Accepts both the object form
## ([{name, weight}]) and the string shorthand (["a", "b"]). Order is preserved (it is the deterministic
## tie-break order). A tile with a non-positive / missing weight gets weight 1.0 (a tile in the alphabet
## is at least minimally pickable -- a 0-weight tile would be in the domain but never chosen, a footgun).
## Empty/absent tiles -> a single inert "" tile, so the grid is well-formed (all empty), not a crash.
func _wfc_tiles(cfg: Dictionary) -> Array:
	var raw: Array = cfg.get("tiles", [])
	var tiles := []
	for t in raw:
		if t is Dictionary:
			var nm := String(t.get("name", ""))
			var wv = t.get("weight")
			var wt: float = 1.0 if wv == null else maxf(0.000001, Primitive.as_num(wv))
			tiles.append({ "name": nm, "weight": wt })
		else:
			tiles.append({ "name": String(t), "weight": 1.0 })
	if tiles.is_empty():
		tiles.append({ "name": "", "weight": 1.0 })
	return tiles

## Build the per-direction adjacency allow-set as { dir: { tileName: { allowedTileName: true } } } over the
## 4-neighbourhood. Auto-completes the opposite direction of each stated pair (right<->left, down<->up): if
## B is allowed to the right of A then A is allowed to the left of B, so a ruleset states each constraint
## once. A direction with NO stated rules at all is left fully permissive (every tile may neighbour every
## tile) -- the open default, so a partial ruleset constrains only what it names. The allow-sets are
## symmetric-completed but NOT made reflexive: same-tile adjacency is allowed only if the ruleset says so.
func _wfc_adjacency(cfg: Dictionary, tiles: Array) -> Dictionary:
	var names := []
	for t in tiles:
		names.append(String(t.get("name")))
	var opposite := { "right": "left", "left": "right", "down": "up", "up": "down" }
	var allow := {}
	for d in ["right", "left", "down", "up"]:
		allow[d] = {}
	var raw: Dictionary = cfg.get("adjacency", {})
	# Pass 1: ingest stated rules + mirror into the opposite direction.
	for d in raw.keys():
		var ds := String(d)
		if not allow.has(ds):
			continue
		var per_tile: Dictionary = raw[d]
		for a in per_tile.keys():
			var an := String(a)
			for b in per_tile[a]:
				var bn := String(b)
				_wfc_allow(allow, ds, an, bn)
				_wfc_allow(allow, String(opposite[ds]), bn, an)
	# Pass 2: any direction with zero stated rules is fully permissive (no constraint). A direction that
	# got ANY rule stays exactly as constrained as stated (a tile absent from its allow-set neighbours
	# nothing in that direction -- an explicit, intended constraint).
	for d in ["right", "left", "down", "up"]:
		if (allow[d] as Dictionary).is_empty():
			for an in names:
				allow[d][an] = {}
				for bn in names:
					allow[d][an][bn] = true
	return allow

func _wfc_allow(allow: Dictionary, d: String, a: String, b: String) -> void:
	if not (allow[d] as Dictionary).has(a):
		allow[d][a] = {}
	allow[d][a][b] = true

## The collapse loop. Returns { grid, contradiction, collapses }. Algorithm (classic observe/propagate):
##   - every cell starts with the FULL tile domain (superposition);
##   - OBSERVE: pick the undecided cell of MINIMUM domain size (min-entropy), ties broken by lowest
##     row-major index (deterministic), and collapse it to ONE tile chosen by a seeded weighted draw;
##   - PROPAGATE: AC-3-style -- a neighbour may keep only tiles that some surviving tile of the collapsed
##     cell permits in that direction; repeat until fixpoint;
##   - a cell whose domain is wiped is a CONTRADICTION: flag it, leave it "", and continue (fail-soft).
## Total determinism: fixed scan order + a single seeded RNG drawn in a fixed sequence + lexicographic
## tie-break on equal-weight draws. Same (ruleset, seed) -> identical grid, every run, every machine.
func _wfc_collapse(w: int, h: int, tiles: Array, adjacency: Dictionary, seed: int) -> Dictionary:
	var n := w * h
	var names := []
	var weight := {}
	for t in tiles:
		var nm := String(t.get("name"))
		names.append(nm)
		weight[nm] = float(t.get("weight", 1.0))
	# domains[i] = Array of still-possible tile names for cell i (row-major: i = y*w + x).
	var domains := []
	for i in n:
		domains.append(names.duplicate())
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var contradiction := false
	var collapses := 0
	for _step in n:
		var ci := _wfc_min_entropy_cell(domains)
		if ci < 0:
			break  # every cell decided
		var chosen := _wfc_weighted_pick(domains[ci], weight, rng)
		domains[ci] = [chosen] if chosen != "" else []
		if chosen == "":
			contradiction = true
		else:
			collapses += 1
		if not _wfc_propagate(domains, w, h, adjacency, ci):
			contradiction = true
	# Materialize the grid: a decided cell shows its single tile; an undecided/empty cell shows "".
	var grid := []
	for y in h:
		var row := []
		for x in w:
			var dom: Array = domains[y * w + x]
			row.append(String(dom[0]) if dom.size() == 1 else "")
		grid.append(row)
	return { "grid": grid, "contradiction": contradiction, "collapses": collapses }

## Index of the undecided cell (domain size > 1) with the SMALLEST domain, ties broken by lowest index
## (the deterministic min-entropy heuristic). Returns -1 when every cell is decided (size <= 1). A size-0
## (already contradicted) cell is skipped -- it cannot be collapsed further.
func _wfc_min_entropy_cell(domains: Array) -> int:
	var best := -1
	var best_size := 0
	for i in domains.size():
		var sz: int = (domains[i] as Array).size()
		if sz > 1 and (best < 0 or sz < best_size):
			best = i
			best_size = sz
	return best

## A seeded WEIGHTED choice from a cell's domain, deterministic for a given (domain order, weights, rng
## stream). The domain is sorted by name first so the draw is independent of the order tiles happened to
## be eliminated in (only the seed + ruleset decide the outcome, never propagation history). An empty
## domain -> "" (a contradiction marker; the caller flags it). A zero total weight (shouldn't happen --
## every weight is clamped > 0) falls back to the first name.
func _wfc_weighted_pick(domain: Array, weight: Dictionary, rng: RandomNumberGenerator) -> String:
	if domain.is_empty():
		return ""
	var sorted := domain.duplicate()
	sorted.sort()
	var total := 0.0
	for nm in sorted:
		total += float(weight.get(String(nm), 1.0))
	if total <= 0.0:
		return String(sorted[0])
	var r := rng.randf() * total
	var acc := 0.0
	for nm in sorted:
		acc += float(weight.get(String(nm), 1.0))
		if r < acc:
			return String(nm)
	return String(sorted[sorted.size() - 1])

## AC-3-style constraint propagation from a just-changed cell `start`. A neighbour keeps only tiles that
## SOME surviving tile of the source permits in the source->neighbour direction; any neighbour that loses a
## tile is itself re-queued so the wave reaches fixpoint. Returns false iff propagation wiped some cell's
## entire domain (a contradiction). The 4-neighbourhood uses the same direction names as the ruleset
## (right/left/down/up). Bounds are respected (edge cells simply have fewer neighbours).
func _wfc_propagate(domains: Array, w: int, h: int, adjacency: Dictionary, start: int) -> bool:
	var queue := [start]
	var ok := true
	while not queue.is_empty():
		var ci: int = queue.pop_back()
		var cx := ci % w
		var cy := ci / w
		for nb in _wfc_neighbours(cx, cy, w, h):
			var ni: int = nb[0]
			var dir: String = nb[1]
			var allowed := {}
			# Union of what the source's surviving tiles permit toward the neighbour.
			for src_tile in domains[ci]:
				var per: Dictionary = (adjacency[dir] as Dictionary).get(String(src_tile), {})
				for at in per.keys():
					allowed[String(at)] = true
			# Keep only neighbour tiles that remain allowed; track whether anything was removed.
			var kept := []
			for nt in domains[ni]:
				if allowed.has(String(nt)):
					kept.append(nt)
			if kept.size() != (domains[ni] as Array).size():
				domains[ni] = kept
				if kept.is_empty():
					ok = false
				else:
					queue.append(ni)
	return ok

## The in-bounds 4-neighbours of (x, y) as [index, direction] pairs, where `direction` is the direction
## FROM the centre cell TO the neighbour -- matching the ruleset's allow-set orientation. Order is fixed
## (right, left, down, up) for determinism.
func _wfc_neighbours(x: int, y: int, w: int, h: int) -> Array:
	var out := []
	if x + 1 < w:
		out.append([y * w + (x + 1), "right"])
	if x - 1 >= 0:
		out.append([y * w + (x - 1), "left"])
	if y + 1 < h:
		out.append([(y + 1) * w + x, "down"])
	if y - 1 >= 0:
		out.append([(y - 1) * w + x, "up"])
	return out
