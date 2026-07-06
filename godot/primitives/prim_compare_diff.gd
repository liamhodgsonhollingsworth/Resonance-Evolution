class_name PrimCompareDiff
extends Primitive
## The COMPARATOR primitive — the ONE convergence comparator (Dreams-arc Slice 6). It reads a
## `candidate` and a `reference` off two wires and emits a SINGLE scalar DISTANCE `d` selected by
## params.metric from a PLUGGABLE metric table. This is the shared measurement seam under every
## "how far is this from the target" arc: the two-version Lathe blue-green swap, the compare-to-real-
## image evolver, module re-implementation verification, and GD ≡ Py ≡ JS parity. All of them reduce to
## "score candidate against reference" — so they wire the SAME node and only differ by the metric string.
##
## THE METRIC-PLUGIN SEAM (the load-bearing design, mirrored on WorldActions' op registry):
##   A metric is a NAME -> Callable(candidate, reference, params) -> float. The table `_metrics` is the
##   ENTIRE extension surface: `register_metric(name, fn)` adds a distance function without touching this
##   file's dispatch — "add a way to compare" == "register one metric", never an engine edit (the N ideal).
##   UNKNOWN METRIC = A DECLARED SENTINEL (d = +INF), never an error — so an arrangement authored against a
##   richer host (one that registered "ssim"/"lpips") still runs here, its unavailable metric harmlessly
##   reporting "maximally far" rather than crashing. This is the portability keystone WorldActions documents,
##   applied to measurement: image metrics (ssim / lpips) belong to the image/evolver visuals lane and are
##   registered THERE later against the SAME seam; this slice ships only the dict/scalar metrics + the seam.
##
## Metrics shipped NOW (deliberately tiny, per the no-auto-generalize rule):
##   "dict_equality" — 0.0 if candidate and reference are DEEP-EQUAL, else 1.0. The state/output-dict case
##                     (module re-implementation verification, GD≡Py≡JS parity: two evaluate() receipts match
##                     or they don't). Non-dict values fall back to plain equality (0.0 iff ==).
##   "l2"            — Euclidean distance |candidate - reference| over scalars, OR over equal-length numeric
##                     arrays (sqrt of summed squared componentwise differences). The convergence-to-a-target
##                     case: a shrinking l2 IS "the candidate is approaching the reference".
##   "abs"          — absolute scalar difference |candidate - reference| (the 1-D l2; a cheaper knob for a
##                     single-number target). Over arrays it is the L1 (sum of |componentwise diff|).
##
## params:
##   metric — one of the registered metric names. Default "l2".
##   (metric-specific params, e.g. a future "channels" for an image metric, are read by that metric's fn.)
##
## inputs:  candidate, reference (any-typed — a number, a numeric array, or a dict, per the metric).
## output:  d — the scalar distance (Float). Smaller == closer; 0.0 == identical (for the shipped metrics).

## The metric registry. name(String) -> Callable(candidate, reference, params:Dictionary) -> float.
## A metric absent here yields the declared +INF sentinel (see evaluate()), never an error. Instance-level
## (built once per node in _init) so a host / a later visuals-lane slice can register_metric() extra metrics
## on a specific node without leaking into siblings — the same posture as WorldActions' per-instance _ops.
var _metrics: Dictionary = {}

func _init() -> void:
	prim_type = "CompareDiff"
	_register_builtins()

func input_ports() -> Array:
	return [
		{ "name": "candidate", "type": "any" },
		{ "name": "reference", "type": "any" },
	]

func output_ports() -> Array:
	return [{ "name": "d", "type": "number" }]

## Register (or replace) a metric. THE ENTIRE extension surface — an image metric (ssim/lpips) is one
## call here from the visuals lane, never an edit to the dispatch below. Additive by construction.
func register_metric(name: String, fn: Callable) -> void:
	if name == "":
		return
	_metrics[name] = fn

## Is `name` a registered metric? (False => evaluate() returns the +INF declared sentinel.)
func has_metric(name: String) -> bool:
	return _metrics.has(name)

## The sorted list of registered metric names (test observability + a future panel picker).
func metrics() -> Array:
	var names := _metrics.keys()
	names.sort()
	return names

func evaluate(inputs: Dictionary) -> Dictionary:
	var metric := String(params.get("metric", "l2"))
	var candidate = inputs.get("candidate")
	var reference = inputs.get("reference")
	if not _metrics.has(metric):
		# The portability keystone: an unknown metric is a DECLARED SENTINEL (maximally far), never a
		# failure — an arrangement authored against a host that registered "ssim" still runs here.
		return { "d": INF }
	var fn: Callable = _metrics[metric]
	if not fn.is_valid():
		return { "d": INF }
	return { "d": float(fn.call(candidate, reference, params)) }

# --- built-in metrics ------------------------------------------------------------------------------

func _register_builtins() -> void:
	register_metric("dict_equality", _metric_dict_equality)
	register_metric("l2", _metric_l2)
	register_metric("abs", _metric_abs)

## "dict_equality": 0.0 iff candidate and reference are DEEP-EQUAL, else 1.0. GDScript's `==` on
## Dictionaries / Arrays IS a recursive deep compare (by value), so it gives exact deep-equality for the
## state/output-dict + parity cases. Non-dict values fall through the same `==` (0.0 iff equal), so this
## metric doubles as "identical or not" for any Variant.
func _metric_dict_equality(candidate, reference, _params: Dictionary) -> float:
	return 0.0 if candidate == reference else 1.0

## "l2": Euclidean distance. Over scalars it is |candidate - reference|; over two equal-length numeric
## arrays it is sqrt(sum of squared componentwise differences). Mismatched-length / non-numeric arrays
## fall back to the scalar coercion of each side (Primitive.as_num), so an ill-typed wire yields a defined
## number rather than a crash (the null-input-safety discipline the pure ops follow).
func _metric_l2(candidate, reference, _params: Dictionary) -> float:
	if candidate is Array and reference is Array and (candidate as Array).size() == (reference as Array).size():
		var sum := 0.0
		for i in (candidate as Array).size():
			var dv := Primitive.as_num(candidate[i]) - Primitive.as_num(reference[i])
			sum += dv * dv
		return sqrt(sum)
	var d := Primitive.as_num(candidate) - Primitive.as_num(reference)
	return absf(d)

## "abs": absolute scalar difference |candidate - reference| (the 1-D l2 — a cheaper knob for a single
## number target). Over two equal-length numeric arrays it is the L1 norm (sum of |componentwise diff|).
func _metric_abs(candidate, reference, _params: Dictionary) -> float:
	if candidate is Array and reference is Array and (candidate as Array).size() == (reference as Array).size():
		var sum := 0.0
		for i in (candidate as Array).size():
			sum += absf(Primitive.as_num(candidate[i]) - Primitive.as_num(reference[i]))
		return sum
	return absf(Primitive.as_num(candidate) - Primitive.as_num(reference))

## Pure: d is a deterministic function of (candidate, reference, metric, params), no side effect. Safe to
## memoize. (An impure future metric would register a non-cacheable node type, not flip this default.)
func is_cacheable() -> bool:
	return true
