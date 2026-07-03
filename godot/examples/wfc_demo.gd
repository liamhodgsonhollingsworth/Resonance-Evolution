extends Node2D
## GENERALIZED PROBABILISTIC WFC DEMO — a minimal openable wrapper around the merged
## weight-oracle WFC (primitives/wfc_generalized.gd via the `wfc` Context handler; RE #133).
## It collapses THE SAME ruleset with THE SAME seed at three weight tiers, side by side:
##   T0 uniform      — the deterministic base collapser (static per-tile weights).
##   T1 conditional  — neighbour-conditioned constants ("grass is 6x likelier next to grass").
##   T2 evolving     — weights fed back from generation-state counters (P(A|B) ∝ f(n_AB) —
##                     water-water adjacency reinforces itself into blobs).
## SPACE draws a new seed; the same seed always reproduces the same three grids
## (probabilistic ≠ non-deterministic — the module's hard invariant).
##
## Wrapper only: everything here is an ARRANGEMENT wired as DATA through GraphRuntime,
## exactly the path headless_wfc_prob_test.gd proves. No new functionality.
## Preloads are path-based (no class_name dependence) per the class-cache gotcha.

const GraphRuntimeScript := preload("res://runtime/graph_runtime.gd")

const TILE_COLORS := {
	"grass": Color(0.35, 0.63, 0.31),
	"sand": Color(0.93, 0.79, 0.42),
	"water": Color(0.29, 0.47, 0.66),
}
const GRID_W := 24
const GRID_H := 24
const CELL := 11.0
const PANEL_GAP := 36.0
const ORIGIN := Vector2(24, 72)

var _seed_value := 42
var _panels: Array = []  # [{ label: String, grid: Array }]


func _ready() -> void:
	get_window().title = "Generalized probabilistic WFC demo"
	_collapse_all()


func _unhandled_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k != null and k.pressed and not k.echo and k.keycode == KEY_SPACE:
		# Deterministic reroll chain: the demo stays reproducible run-to-run.
		_seed_value = int((_seed_value * 1103515245 + 12345) % 2147483647)
		_collapse_all()


func _collapse_all() -> void:
	_panels = []
	for spec in _panel_specs():
		_panels.append({
			"label": spec["label"],
			"grid": _collapse(spec["ruleset"], _seed_value),
		})
	queue_redraw()


## grass|sand|water with the classic beach constraint (water never touches grass directly),
## identical in all four directions.
func _beach_adjacency() -> Dictionary:
	var allowed := {
		"grass": ["grass", "sand"],
		"sand": ["grass", "sand", "water"],
		"water": ["sand", "water"],
	}
	return {
		"right": allowed.duplicate(true),
		"left": allowed.duplicate(true),
		"up": allowed.duplicate(true),
		"down": allowed.duplicate(true),
	}


func _panel_specs() -> Array:
	var base := {
		"width": GRID_W, "height": GRID_H,
		"tiles": ["grass", "sand", "water"],
		"adjacency": _beach_adjacency(),
	}
	var t1: Dictionary = base.duplicate(true)
	t1["weights"] = { "mode": "conditional", "rules": [
		{ "tile": "grass", "given": { "dir": "any", "neighbor": "grass" }, "weight": 6.0 },
		{ "tile": "water", "given": { "dir": "any", "neighbor": "water" }, "weight": 4.0 },
	] }
	var t2: Dictionary = base.duplicate(true)
	t2["weights"] = { "mode": "evolving", "rules": [
		{ "tile": "water", "weight_expr": {
			"op": "linear", "base": 1.0, "k": 0.2, "counter": "n_ww", "cap": 6.0 } },
	] }
	t2["counters"] = { "n_ww": { "track": "adjacent_pair", "a": "water", "b": "water" } }
	return [
		{ "label": "T0 uniform (base)", "ruleset": base },
		{ "label": "T1 conditional (neighbour rules)", "ruleset": t1 },
		{ "label": "T2 evolving (counter feedback)", "ruleset": t2 },
	]


## Collapse ONE ruleset through the engine-idiomatic path: a Context(wfc) arrangement
## evaluated by GraphRuntime — the exact shape headless_wfc_prob_test.gd exercises.
func _collapse(ruleset: Dictionary, seed_v: int) -> Array:
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ctx", "type": "Context", "params": {
				"handler": "wfc", "wfc": ruleset,
				"ports": { "inputs": [], "outputs": [{ "name": "grid" }] } } },
			{ "id": "s", "type": "Const", "params": { "value": seed_v } },
		],
		"wires": [
			{ "from": "s", "out": "value", "to": "ctx", "in": "seed" },
		],
	}
	var rt := GraphRuntimeScript.new()
	add_child(rt)
	rt.load_arrangement(arr)
	var outs: Dictionary = rt.evaluate()
	remove_child(rt)
	rt.free()
	var g = (outs.get("ctx", {}) as Dictionary).get("grid")
	return g if g is Array else []


func _draw() -> void:
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(24, 32),
		"Generalized probabilistic WFC — one seed, three weight tiers",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
	draw_string(font, Vector2(24, 54),
		"seed %d   -   SPACE: new seed (same seed = same grids, always)" % _seed_value,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.78, 0.78, 0.78))
	for p in _panels.size():
		var off := ORIGIN + Vector2(float(p) * (GRID_W * CELL + PANEL_GAP), 0.0)
		draw_string(font, off + Vector2(0, 14),
			String(_panels[p]["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		var grid: Array = _panels[p]["grid"]
		for y in grid.size():
			var row: Array = grid[y]
			for x in row.size():
				var c: Color = TILE_COLORS.get(String(row[x]), Color.MAGENTA)
				draw_rect(Rect2(
					off + Vector2(float(x) * CELL, 24.0 + float(y) * CELL),
					Vector2(CELL - 1.0, CELL - 1.0)), c)
