class_name LSystem
extends RefCounted
## L-SYSTEM INTERPRETER — axiom + production rules + iteration depth + turtle interpretation, ALL as
## DATA (the spec'd scope, no more): `expand` rewrites the axiom string through the rules `depth`
## times; `interpret` walks the result with a classic 3D turtle and emits line SEGMENTS as pure data;
## `to_scene_node` turns the segments into the renderer-neutral scene_node descriptor (a group of
## oriented primitive cylinders) the GodotSceneRenderer / any delegate already builds. Deterministic:
## plain string rules are pure rewriting; stochastic rules (an Array of [weight, replacement] options)
## are chosen by a SEEDED LCG — same seed, same plant, byte for byte.
##
## Rules (DATA):        { "X": "F[+X][-X]FX", "F": "FF" }                      (deterministic)
##                      { "F": [[0.7, "F[+F]"], [0.3, "F[-F]"]] }              (stochastic, seeded)
## Turtle alphabet (classic ABOP set, exactly): F draw forward · f move forward · + - yaw · & ^ pitch
## · \ / roll · | turn around · [ push state · ] pop state · ! multiply radius by radius_decay ·
## " multiply step by step_decay. Unknown symbols are structural (ignored by the turtle), so rule
## non-terminals like X cost nothing.
## Turtle params (DATA): { step, angle_deg, radius, radius_decay, step_decay }.

## Rewrite `axiom` through `rules` `depth` times. Stochastic options are picked by a seeded LCG so the
## expansion is reproducible. Returns the final symbol string.
static func expand(axiom: String, rules: Dictionary, depth: int, seed: int = 0) -> String:
	var rng := [int(seed) * 2654435761 + 40503]
	var s := axiom
	for _i in maxi(0, depth):
		var out := ""
		for ch in s:
			if rules.has(ch):
				out += _pick(rules[ch], rng)
			else:
				out += ch
		s = out
	return s

## One production: a plain String replaces verbatim; an Array of [weight, replacement] options is a
## seeded weighted choice (the stochastic L-system case).
static func _pick(rule, rng: Array) -> String:
	if typeof(rule) == TYPE_STRING:
		return rule
	if typeof(rule) == TYPE_ARRAY:
		var options: Array = rule
		var total := 0.0
		for o in options:
			if o is Array and (o as Array).size() >= 2:
				total += maxf(0.0, float(o[0]))
		if total <= 0.0:
			return ""
		var roll := _rand01(rng) * total
		var acc := 0.0
		for o in options:
			if not (o is Array) or (o as Array).size() < 2:
				continue
			acc += maxf(0.0, float(o[0]))
			if roll <= acc:
				return String(o[1])
		return String((options[options.size() - 1] as Array)[1])
	return ""

## Walk `symbols` with a 3D turtle (heading starts +Y — plants grow up). Returns segments as DATA:
## [ { "a": [x,y,z], "b": [x,y,z], "radius": float, "level": int }, ... ]  (level = bracket depth).
static func interpret(symbols: String, turtle: Dictionary = {}) -> Array:
	var step := float(turtle.get("step", 0.35))
	var angle := deg_to_rad(float(turtle.get("angle_deg", 25.0)))
	var radius := float(turtle.get("radius", 0.05))
	var radius_decay := float(turtle.get("radius_decay", 0.7))
	var step_decay := float(turtle.get("step_decay", 0.9))
	var pos := Vector3.ZERO
	var basis := Basis.IDENTITY  # heading = basis.y (+Y up), left = basis.x, up(out-of-plane) = basis.z
	var level := 0
	var stack := []
	var segments := []
	for ch in symbols:
		match ch:
			"F":
				var nxt := pos + basis.y * step
				segments.append({
					"a": [pos.x, pos.y, pos.z],
					"b": [nxt.x, nxt.y, nxt.z],
					"radius": radius,
					"level": level,
				})
				pos = nxt
			"f":
				pos += basis.y * step
			"+":
				basis = basis.rotated(basis.z.normalized(), angle)
			"-":
				basis = basis.rotated(basis.z.normalized(), -angle)
			"&":
				basis = basis.rotated(basis.x.normalized(), angle)
			"^":
				basis = basis.rotated(basis.x.normalized(), -angle)
			"\\":
				basis = basis.rotated(basis.y.normalized(), angle)
			"/":
				basis = basis.rotated(basis.y.normalized(), -angle)
			"|":
				basis = basis.rotated(basis.z.normalized(), PI)
			"!":
				radius *= radius_decay
			"\"":
				step *= step_decay
			"[":
				stack.push_back([pos, basis, radius, step])
				level += 1
			"]":
				if not stack.is_empty():
					var st: Array = stack.pop_back()
					pos = st[0]
					basis = st[1]
					radius = st[2]
					step = st[3]
					level -= 1
			_:
				pass  # structural non-terminals (X, A, …) draw nothing
	return segments

## Segments → the renderer-neutral scene_node descriptor: a group whose children are oriented
## primitive CYLINDERS (one per segment; midpoint translation + a quaternion turning the cylinder's
## +Y axis onto the segment direction) — the exact `mesh:{source:"primitive"...}` shape the
## PartsCatalog emits, so the existing delegate builds it unchanged. Pure JSON-serializable data.
static func to_scene_node(segments: Array, name: String = "lsystem") -> Dictionary:
	var children := []
	var i := 0
	for seg in segments:
		if typeof(seg) != TYPE_DICTIONARY:
			continue
		var a := _v3(seg.get("a", [0, 0, 0]))
		var b := _v3(seg.get("b", [0, 0, 1]))
		var d := b - a
		var length := d.length()
		if length < 0.00001:
			continue
		var mid := (a + b) * 0.5
		var q := _quat_y_to(d / length)
		var r := float(seg.get("radius", 0.05))
		children.append({
			"name": "seg_%d" % i,
			"translation": [mid.x, mid.y, mid.z],
			"rotation": [q.x, q.y, q.z, q.w],
			"scale": [1.0, 1.0, 1.0],
			"mesh": { "source": "primitive", "shape": "cylinder", "params": {
				"radius": r, "height": length } },
			"children": [],
		})
		i += 1
	return {
		"name": name,
		"translation": [0.0, 0.0, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"children": children,
	}

## Shortest-arc quaternion rotating +Y onto `dir` (unit). The antiparallel case (dir ≈ -Y) has no
## unique shortest arc — use a half-turn around X.
static func _quat_y_to(dir: Vector3) -> Quaternion:
	var up := Vector3.UP
	var d := clampf(up.dot(dir), -1.0, 1.0)
	if d > 0.99999:
		return Quaternion.IDENTITY
	if d < -0.99999:
		return Quaternion(Vector3.RIGHT, PI)
	var axis := up.cross(dir).normalized()
	return Quaternion(axis, acos(d))

static func _v3(a) -> Vector3:
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO

## Deterministic LCG in [0,1) (Knuth MMIX constants) — the seeded stream for stochastic rules.
static func _rand01(state: Array) -> float:
	state[0] = int(state[0]) * 6364136223846793005 + 1442695040888963407
	var v := (int(state[0]) >> 17) & 0x7FFFFFFF
	return float(v) / float(0x80000000)
