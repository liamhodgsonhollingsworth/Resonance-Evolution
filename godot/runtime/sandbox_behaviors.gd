extends RefCounted
## COMPOSABLE OBJECT BEHAVIORS — attach/detach/edit motion + effect components on placed
## objects, as pure DATA (spec apx_e5c6f8dc: "adding and changing their behavior").
##
## Follows the engine's design law: a behavior is NOT bespoke per-object code, it is a typed
## DATA descriptor ({type, params}) interpreted by a registry — the same shape as
## GraphRuntime's primitive registry, so a behavior travels inside arrangement JSON, hotloads,
## and composes (an object carries a LIST of behaviors; each contributes an offset).
##
## STARTER SET (proving the seam, not an exhaustive library):
##   spin   {speed_deg: 45}                       — yaw rotation, deg/sec
##   orbit  {radius: 2.0, speed_deg: 45}          — circle around the placed position
##   bob    {amplitude: 0.5, period: 2.0}         — sinusoidal vertical float
##   follow {speed: 2.0, min_dist: 3.0}           — walk toward the player, stop when close
##   light  {color: [1,0.9,0.6], energy: 2.0, period: 0}   — attached OmniLight3D; period>0 blinks
##
## DETERMINISTIC BY CONSTRUCTION: spin/orbit/bob are pure functions of (base transform, t) —
## an offset from the object's base, never an accumulation — so hotloads / saves / replays
## produce identical motion. `follow` is the one deliberately stateful behavior (it moves the
## base position itself). `light` manages one child node, keyed by name.
##
## Adding a new behavior = one entry in TYPES + one branch in apply(). No placement/world
## code changes (the same additive rule as _apply_material / GraphRuntime.register).
##
## No class_name (mistake #046): consumers preload() this file by path.

const TYPES := ["spin", "orbit", "bob", "follow", "light"]

const DEFAULTS := {
	"spin":   { "speed_deg": 45.0 },
	"orbit":  { "radius": 2.0, "speed_deg": 45.0 },
	"bob":    { "amplitude": 0.5, "period": 2.0 },
	"follow": { "speed": 2.0, "min_dist": 3.0 },
	"light":  { "color": [1.0, 0.9, 0.6], "energy": 2.0, "period": 0.0 },
}

const LIGHT_NODE_NAME := "__behavior_light"


## Normalize a behavior descriptor: known type -> {type, params(defaults overlaid)}; else {}.
static func make(type: String, params: Dictionary = {}) -> Dictionary:
	if not TYPES.has(type):
		return {}
	var merged: Dictionary = (DEFAULTS[type] as Dictionary).duplicate(true)
	for k in params:
		merged[k] = params[k]
	return { "type": type, "params": merged }


static func has_behavior(behaviors: Array, type: String) -> bool:
	for b in behaviors:
		if typeof(b) == TYPE_DICTIONARY and String(b.get("type", "")) == type:
			return true
	return false


## Toggle: attach (with defaults) if absent, detach if present. Returns the new list
## (input list is not mutated — records swap wholesale, append-only style).
static func toggle(behaviors: Array, type: String) -> Array:
	var out := []
	var found := false
	for b in behaviors:
		if typeof(b) == TYPE_DICTIONARY and String(b.get("type", "")) == type:
			found = true
			continue
		out.append(b)
	if not found:
		var d := make(type)
		if not d.is_empty():
			out.append(d)
	return out


## Tick one object's behavior stack. Pure-offset model:
##   pos/yaw start from the record's BASE (base_pos: Vector3, yaw_deg: float, scale: float),
##   each behavior adds its contribution, and the final transform lands on `node`.
## `ctx` supplies the world around the object: { "t": float seconds, "delta": float,
##   "player_pos": Vector3 } (player_pos drives `follow`; pass Vector3.INF to disable).
## Returns the computed position (tests assert on it).
static func tick(record: Dictionary, node: Node3D, ctx: Dictionary) -> Vector3:
	var t := float(ctx.get("t", 0.0))
	var delta := float(ctx.get("delta", 0.0))
	var base_pos: Vector3 = record.get("base_pos", Vector3.ZERO)
	var yaw := deg_to_rad(float(record.get("yaw_deg", 0.0)))
	var scl := float(record.get("scale", 1.0))
	var offset := Vector3.ZERO      # pure-function contributions (orbit/bob)
	var behaviors: Array = record.get("behaviors", [])
	for b in behaviors:
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var p: Dictionary = b.get("params", {})
		match String(b.get("type", "")):
			"spin":
				yaw += deg_to_rad(float(p.get("speed_deg", 45.0))) * t
			"orbit":
				var r := float(p.get("radius", 2.0))
				var w := deg_to_rad(float(p.get("speed_deg", 45.0)))
				offset += Vector3(cos(w * t), 0.0, sin(w * t)) * r
			"bob":
				var period := maxf(0.05, float(p.get("period", 2.0)))
				offset.y += float(p.get("amplitude", 0.5)) * sin(TAU * t / period)
			"follow":
				var target = ctx.get("player_pos", Vector3.INF)
				if typeof(target) == TYPE_VECTOR3 and target != Vector3.INF and delta > 0.0:
					var to: Vector3 = target - base_pos
					to.y = 0.0
					if to.length() > float(p.get("min_dist", 3.0)):
						base_pos += to.normalized() * float(p.get("speed", 2.0)) * delta
						record["base_pos"] = base_pos      # stateful ON PURPOSE (see header)
			"light":
				pass    # node management below, outside the transform fold
	var pos := base_pos + offset
	if node != null and is_instance_valid(node):
		node.position = pos
		node.rotation = Vector3(0.0, yaw, 0.0)
		node.scale = Vector3.ONE * scl
		_sync_light(record, node, t)
	return pos


## Ensure/refresh/remove the light child according to the behavior list. Blink when period>0.
static func _sync_light(record: Dictionary, node: Node3D, t: float) -> void:
	var behaviors: Array = record.get("behaviors", [])
	var want: Dictionary = {}
	for b in behaviors:
		if typeof(b) == TYPE_DICTIONARY and String(b.get("type", "")) == "light":
			want = b.get("params", {})
			break
	var existing: Node = node.get_node_or_null(LIGHT_NODE_NAME)
	if want.is_empty():
		if existing != null:
			existing.queue_free()
		return
	var light: OmniLight3D
	if existing is OmniLight3D:
		light = existing
	else:
		light = OmniLight3D.new()
		light.name = LIGHT_NODE_NAME
		light.position = Vector3(0.0, 1.0, 0.0)
		node.add_child(light)
	var col = want.get("color", [1.0, 0.9, 0.6])
	if typeof(col) == TYPE_ARRAY and (col as Array).size() >= 3:
		light.light_color = Color(col[0], col[1], col[2])
	light.light_energy = float(want.get("energy", 2.0))
	light.omni_range = float(want.get("range", 8.0))
	var period := float(want.get("period", 0.0))
	light.visible = true if period <= 0.0 else fmod(t, period) < period * 0.5
