class_name ParamDist
extends RefCounted
## CONCENTRATING ADAPTIVE PER-PARAMETER DISTRIBUTIONS — the probability math under NodeGenome
## (the third genome KIND). Every scalar/enum gene of a VARIABLE node is drawn from a per-param
## distribution whose STATE is plain JSON data carried on the genome; each time a genome is
## evolved, the child's distributions TRANSFORM to concentrate around the parent's realized
## value. More evolution ⇒ smaller typical change — but the change probability NEVER reaches
## zero, and dramatic outward moves stay possible forever (heavy tails).
##
## THE MATH (documented in notes/design/node_genome_evolver_2026-07-03.md):
##
##   SCALAR gene over [lo, hi] — a two-component MIXTURE:
##     draw ~ (1 - tail_w) · TruncNormal(mu, sigma)  +  tail_w · Uniform(lo, hi)
##       mu     = the parent's realized value (re-centered on every evolution)
##       sigma  = max(sigma_min, sigma0 · gamma^depth)   — the SHRINKING CORE
##       tail_w = FIXED mixture weight (default 0.10)    — the NON-DECAYING HEAVY TAIL
##     Concentration transform (applied once per evolution, child inherits the result):
##       mu' = realized;  sigma' = max(sigma_min, sigma · gamma);  depth' = depth + 1
##     sigma_min > 0 forbids zero variance; tail_w never decays, so from ANY depth the
##     probability of a move of ANY size is ≥ tail_w · (move size / range) — the escape
##     guarantee the premature-concentration adversarial test exercises.
##
##   CATEGORICAL gene over n options — concentrating weights with a UNIFORM FLOOR:
##     sample p_i = (1 - tail_w) · w_i + tail_w / n     (every option forever has p ≥ tail_w/n)
##     Concentration: w' = normalize((1 - eta) · w + eta · onehot(realized));  depth' = depth + 1
##
##   GRANULARITY / APPROXIMATION LAYER (configurable as DATA, per-genome config):
##     The continuous draw may be SNAPPED to a grid — granular, compressed, approximate.
##       grid.mode = "off"      : exact continuous math.
##       grid.mode = "fixed"    : step = range / grid.bins (a fixed resolution).
##       grid.mode = "adaptive" : step = clamp(sigma · step_frac, min_step, range/4) — the grid
##         COARSENS when the distribution is wide (cheap, compressed early exploration) and
##         REFINES automatically as evolution concentrates sigma (fine detail exactly when the
##         search needs it). O(1) per draw, no PDF tables — the optimized backend for rapid
##         user-facing iteration.
##
## Pure static functions over plain-dict state (JSON-serializable, headless); ALL randomness
## flows through the caller's seeded RandomNumberGenerator ⇒ deterministic evolution.

## Default per-genome distribution config — carried as DATA on NodeGenome.config, overridable
## per genome (and therefore per canvas page / per evolver run) without touching code.
const DEFAULT_CONFIG := {
	"sigma0_frac": 0.25,    # initial core scale, as a fraction of the param's range
	"gamma": 0.7,           # per-evolution concentration factor (sigma multiplier)
	"sigma_min_frac": 0.01, # variance floor as a fraction of range — zero variance FORBIDDEN
	"tail_w": 0.10,         # fixed heavy-tail mixture weight — NEVER decays
	"eta": 0.4,             # categorical concentration rate toward the realized option
	"grid": { "mode": "adaptive", "step_frac": 0.25, "min_step_frac": 0.001, "bins": 64 },
}

# ---------------------------------------------------------------------------------------------------
# state constructors — a dist state is a plain dict, serialized inside the genome node
# ---------------------------------------------------------------------------------------------------

## Fresh scalar state centered on `mu0` (the configured starting shape: wide core + tail).
static func init_scalar(lo: float, hi: float, mu0: float, vtype: String, cfg: Dictionary) -> Dictionary:
	var range_w := maxf(hi - lo, 1e-9)
	return {
		"kind": "scalar",
		"lo": lo, "hi": hi,
		"vtype": vtype,
		"mu": clampf(mu0, lo, hi),
		"sigma": range_w * float(_c(cfg, "sigma0_frac")),
		"depth": 0,
	}

## Fresh categorical state: uniform weights, optionally pre-centered on `initial`.
static func init_categorical(options: Array, initial: String, cfg: Dictionary) -> Dictionary:
	var n := options.size()
	var w := []
	for i in n:
		w.append(1.0 / float(maxi(n, 1)))
	var state := {
		"kind": "categorical",
		"options": options.duplicate(),
		"weights": w,
		"depth": 0,
	}
	if initial != "" and options.has(initial):
		state = concentrate(state, initial, cfg)
		state["depth"] = 0  # pre-centering is part of the STARTING configuration, not lineage depth
	return state

# ---------------------------------------------------------------------------------------------------
# the concentration transform — applied once per evolution; returns a NEW state dict
# ---------------------------------------------------------------------------------------------------

static func concentrate(state: Dictionary, realized, cfg: Dictionary) -> Dictionary:
	var s := state.duplicate(true)
	if String(s.get("kind", "")) == "scalar":
		var lo := float(s["lo"])
		var hi := float(s["hi"])
		var range_w := maxf(hi - lo, 1e-9)
		var sigma_min := range_w * float(_c(cfg, "sigma_min_frac"))
		s["mu"] = clampf(float(realized), lo, hi)
		s["sigma"] = maxf(sigma_min, float(s["sigma"]) * float(_c(cfg, "gamma")))
		s["depth"] = int(s.get("depth", 0)) + 1
	elif String(s.get("kind", "")) == "categorical":
		var opts: Array = s.get("options", [])
		var w: Array = (s.get("weights", []) as Array).duplicate()
		var eta := float(_c(cfg, "eta"))
		var hit := opts.find(realized)
		var total := 0.0
		for i in w.size():
			w[i] = (1.0 - eta) * float(w[i]) + (eta if i == hit else 0.0)
			total += float(w[i])
		if total > 0.0:
			for i in w.size():
				w[i] = float(w[i]) / total
		s["weights"] = w
		s["depth"] = int(s.get("depth", 0)) + 1
	return s

# ---------------------------------------------------------------------------------------------------
# draw — one sample from the current state (mixture core + heavy tail, then the grid snap)
# ---------------------------------------------------------------------------------------------------

static func draw(state: Dictionary, cfg: Dictionary, rng: RandomNumberGenerator) -> Variant:
	if String(state.get("kind", "")) == "categorical":
		return _draw_categorical(state, cfg, rng)
	return _draw_scalar(state, cfg, rng)

static func _draw_scalar(state: Dictionary, cfg: Dictionary, rng: RandomNumberGenerator) -> Variant:
	var lo := float(state["lo"])
	var hi := float(state["hi"])
	var v: float
	if rng.randf() < float(_c(cfg, "tail_w")):
		v = rng.randf_range(lo, hi)  # heavy tail: uniform over the WHOLE range, weight never decays
	else:
		v = clampf(rng.randfn(float(state["mu"]), float(state["sigma"])), lo, hi)
	v = _snap(v, lo, hi, float(state["sigma"]), cfg)
	if String(state.get("vtype", "float")) == "int":
		return int(round(v))
	return v

static func _draw_categorical(state: Dictionary, cfg: Dictionary, rng: RandomNumberGenerator) -> Variant:
	var opts: Array = state.get("options", [])
	if opts.is_empty():
		return ""
	var w: Array = state.get("weights", [])
	var tail_w := float(_c(cfg, "tail_w"))
	var n := opts.size()
	# Sampling distribution = (1 - tail_w)·w + tail_w·uniform — the floor keeps every option alive.
	var r := rng.randf()
	var acc := 0.0
	for i in n:
		var wi := float(w[i]) if i < w.size() else 0.0
		acc += (1.0 - tail_w) * wi + tail_w / float(n)
		if r <= acc:
			return opts[i]
	return opts[n - 1]

# ---------------------------------------------------------------------------------------------------
# introspection — the invariants the tests assert
# ---------------------------------------------------------------------------------------------------

## The current core scale — must NEVER reach zero (the variance floor).
static func effective_sigma(state: Dictionary) -> float:
	return float(state.get("sigma", 0.0))

## The minimum probability any single option can be sampled with (categorical floor).
static func min_option_prob(state: Dictionary, cfg: Dictionary) -> float:
	var n := (state.get("options", []) as Array).size()
	if n == 0:
		return 0.0
	return float(_c(cfg, "tail_w")) / float(n)

## The grid step a draw would snap to under the current state (0.0 = continuous). Exposed so the
## granularity tests can assert the adaptive grid coarsens/refines with sigma.
static func grid_step(state: Dictionary, cfg: Dictionary) -> float:
	if String(state.get("kind", "")) != "scalar":
		return 0.0
	var lo := float(state["lo"])
	var hi := float(state["hi"])
	return _step_for(lo, hi, float(state.get("sigma", 0.0)), cfg)

# ---------------------------------------------------------------------------------------------------
# granularity backend
# ---------------------------------------------------------------------------------------------------

static func _step_for(lo: float, hi: float, sigma: float, cfg: Dictionary) -> float:
	var grid: Dictionary = _c(cfg, "grid")
	var mode := String(grid.get("mode", "off"))
	var range_w := maxf(hi - lo, 1e-9)
	match mode:
		"fixed":
			return range_w / float(maxi(int(grid.get("bins", 64)), 1))
		"adaptive":
			var min_step := range_w * float(grid.get("min_step_frac", 0.001))
			return clampf(sigma * float(grid.get("step_frac", 0.25)), min_step, range_w / 4.0)
		_:
			return 0.0

static func _snap(v: float, lo: float, hi: float, sigma: float, cfg: Dictionary) -> float:
	var step := _step_for(lo, hi, sigma, cfg)
	if step <= 0.0:
		return v
	return clampf(lo + round((v - lo) / step) * step, lo, hi)

## Config accessor with DEFAULT_CONFIG fallback (a partial config dict is always valid DATA).
static func _c(cfg: Dictionary, key: String) -> Variant:
	return cfg.get(key, DEFAULT_CONFIG[key])
