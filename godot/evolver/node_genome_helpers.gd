class_name NodeGenomeHelpers
extends RefCounted
## CONDITIONAL CONVERGENCE-HELPER NODES — the pluggable seam where a per-parameter EVOLUTION
## METHOD is itself a NODE living inside the artifact's node collection, wired as DATA.
##
## A helper node is a normal NodeGenome node whose schema type declares `is_helper: true`. It
## carries:
##   - `when`   : a CONDITION dict on the node (all keys must match — AND semantics):
##                  { "param": "gain" }        — applies to params with this name
##                  { "node_type": "transform" } — applies to params of nodes of this type
##                  { "depth_gte": 5 }          — applies once the dist has concentrated ≥ 5 steps
##   - `params` : the helper's own hyperparameters (themselves evolvable genes if the node is
##                flagged variable — the evolution method can itself evolve).
##
## During NodeGenome.mutate, AFTER the standard concentration transform re-centers a param's
## distribution, every helper node whose condition matches gets to TRANSFORM that distribution
## state further. Adding a new evolution method = registering one function here + adding the
## helper node type to the schema — additive, reusable across genomes, never a foundation edit.
##
## SHIPPED EXAMPLE — "helper_momentum" (momentum-toward-improvement):
##   The selection loop keeps the children that moved a param in a GOOD direction; momentum
##   extrapolates that motion. The state gains a velocity `vel`:
##     vel' = beta · vel + (realized − previous_center)     (EMA of realized displacement)
##     mu'  = clamp(mu + gain · vel', lo, hi)               (bias the next draw forward)
##   With beta = 0, mu' = mu + gain·(last step) — pure extrapolation; larger beta smooths.
##   Deterministic (no randomness in the transform), state serializes with the genome.

## helper type name -> Callable-shaped dispatch (match in `apply`). Kept as an explicit match
## (not a Dictionary of Callables) so the registry serializes trivially and hot-reload survives.
static func known_helpers() -> Array:
	return ["helper_momentum"]

## Does `when` match this parameter's context? ctx: { "param", "node_type", "depth" }.
static func matches(when: Dictionary, ctx: Dictionary) -> bool:
	if when.has("param") and String(when["param"]) != String(ctx.get("param", "")):
		return false
	if when.has("node_type") and String(when["node_type"]) != String(ctx.get("node_type", "")):
		return false
	if when.has("depth_gte") and int(ctx.get("depth", 0)) < int(when["depth_gte"]):
		return false
	return true

## Apply one helper node's transform to a (already concentrated) dist state. Returns the NEW
## state. Unknown helper types are a no-op (fail-open: a genome carrying a helper this build
## doesn't know still evolves normally).
##   helper_node : the helper node dict ({ "type", "when", "params": {...} }).
##   state       : the param's dist state AFTER ParamDist.concentrate.
##   ctx         : { "param", "node_type", "depth", "realized", "prev_center" }.
static func apply(helper_node: Dictionary, state: Dictionary, ctx: Dictionary) -> Dictionary:
	match String(helper_node.get("type", "")):
		"helper_momentum":
			return _momentum(helper_node, state, ctx)
		_:
			return state

## Momentum-toward-improvement — see class doc. Scalar-only (categorical states pass through).
static func _momentum(helper_node: Dictionary, state: Dictionary, ctx: Dictionary) -> Dictionary:
	if String(state.get("kind", "")) != "scalar":
		return state
	var p: Dictionary = helper_node.get("params", {})
	var beta := clampf(float(p.get("beta", 0.5)), 0.0, 0.99)
	var gain := float(p.get("gain", 1.0))
	var s := state.duplicate(true)
	var step := float(ctx.get("realized", s["mu"])) - float(ctx.get("prev_center", s["mu"]))
	var vel := beta * float(s.get("vel", 0.0)) + step
	s["vel"] = vel
	s["mu"] = clampf(float(s["mu"]) + gain * vel, float(s["lo"]), float(s["hi"]))
	return s
