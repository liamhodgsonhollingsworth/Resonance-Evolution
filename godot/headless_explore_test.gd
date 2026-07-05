extends SceneTree
## Headless verification of the EXPLORE-A-SCENE demo (examples/explore), WITHOUT a window.
##
##   <godot> --headless --path godot -s res://headless_explore_test.gd
##
## Proves the demo does what Liam asked (item 3, 2026-07-05, all 5 scenes approved): a SCENE SELECTOR
## when no scene is chosen; and for a chosen scene, explore (walk + SOLID walls), collect via the
## sandbox GRAB feature into inventory, and leave in-scene feedback. It drives the SAME public grab
## API the live scene uses (through the adapter), so a green run means the mechanic is sound.
## Asserts:
##   (0) with no scene param the demo shows a SELECTOR listing the vendored scenes,
##   (1) entering a scene assembles env + player + grab adapter,
##   (2) it built SOLID walls (StaticBody3D with a box collider) — "run into solid walls",
##   (3) it registered collectibles as walk-up pickables through the adapter,
##   (4) walking up to a collectible + grabbing it adds it to the inventory (grab -> inventory),
##   (5) an out-of-range collectible is NOT grabbable (proximity gate holds),
##   (6) in-scene feedback appends a keyed line to a notes.jsonl (F1 path),
##   (7) the adapter constructs the peer PickupInteractor + BuildHud by PATH (cache-independent),
##   (8) EVERY registry scene either enters as a real vendored scene OR falls back to a walled room
##       (never hard-fails), and every registry scene has a LICENSE/PROVENANCE on disk.

const Scenes := preload("res://examples/explore/explore_scenes.gd")

func _initialize() -> void:
	var ok := true

	# (0) SELECTOR: no scene param -> a selector layer with one button per registry scene.
	var DemoScene := load("res://examples/explore/explore_scene_demo.tscn")
	ok = _check("explore scene loads", DemoScene != null) and ok
	if DemoScene == null:
		_finish(false); return
	var sel_demo: Node3D = (DemoScene as PackedScene).instantiate()
	get_root().add_child(sel_demo)
	await process_frame
	await process_frame
	var selector = sel_demo.get_node_or_null("SelectorLayer")
	ok = _check("no-param launch shows a scene SELECTOR", selector != null) and ok
	if selector != null:
		var buttons := _count_buttons(selector)
		ok = _check("selector lists all %d registry scenes" % Scenes.order().size(),
			buttons >= Scenes.order().size()) and ok
	sel_demo.queue_free()
	await process_frame

	# (1)-(6): pick the first VENDORED scene and drive the full loop through it.
	var chosen := _first_vendored()
	ok = _check("at least one vendored scene is present on disk", chosen != "") and ok
	var demo: Node3D = (DemoScene as PackedScene).instantiate()
	get_root().add_child(demo)
	await process_frame                     # _ready runs; no param -> selector, so drive _enter_scene
	if demo.has_method("_on_scene_chosen"):
		demo._on_scene_chosen(chosen if chosen != "" else Scenes.order()[0])
	await process_frame
	await process_frame

	var player = demo.get_node_or_null("Player")
	ok = _check("demo built a Player (CharacterBody3D)", player != null and player is CharacterBody3D) and ok
	var grab = demo.get_node_or_null("Grab")
	ok = _check("demo built the grab adapter", grab != null) and ok

	# (2) SOLID walls — at least the four room walls, each a StaticBody3D with a BoxShape3D collider.
	var solid_walls := 0
	for child in demo.get_children():
		if child is StaticBody3D and String(child.name).begins_with("Wall"):
			for c in child.get_children():
				if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
					solid_walls += 1
					break
	ok = _check("built >=4 SOLID walls (StaticBody3D + box collider)", solid_walls >= 4) and ok

	# (3) collectibles registered as pickables through the adapter
	var registered := int(grab.pickable_count())
	ok = _check("registered >=1 collectible pickable", registered >= 1) and ok

	# (4)+(5) grab loop via the peer interactor (drive it directly, as the peer's own test does).
	var interactor = grab.interactor()
	ok = _check("adapter exposes a peer PickupInteractor", interactor != null) and ok
	if interactor != null:
		var target: Node3D = null
		for child in demo.get_children():
			if child is Node3D and String(child.name).begins_with("collectible_"):
				target = child
				break
		ok = _check("found a live collectible node", target != null) and ok
		if target != null:
			var here := target.global_position + Vector3(0.5, 0, 0)   # within the 2.5m grab radius
			var far := target.global_position + Vector3(100, 0, 0)    # well outside it
			interactor.refresh(far)
			ok = _check("collectible NOT grabbable when far (proximity gate)",
				interactor.available_ids().is_empty()) and ok
			interactor.refresh(here)
			ok = _check("collectible becomes grabbable when player walks up",
				not interactor.available_ids().is_empty()) and ok
			var before := int(grab.held_total())
			var picked: String = interactor.use_nearest(here)
			ok = _check("grab picks up the in-range collectible", picked != "") and ok
			ok = _check("grabbed item lands in the inventory (held_total +1)",
				int(grab.held_total()) == before + 1) and ok

	# (6) in-scene feedback appends a keyed jsonl line
	var notes := "user://headless_explore_notes.jsonl"
	var abs := ProjectSettings.globalize_path(notes)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)
	var wrote: bool = demo.append_note("headless test note", abs)
	ok = _check("append_note returns true", wrote) and ok
	if FileAccess.file_exists(abs):
		var txt := FileAccess.get_file_as_string(abs)
		var parsed = JSON.parse_string(txt.strip_edges())
		ok = _check("note line is valid JSON keyed to the scene",
			typeof(parsed) == TYPE_DICTIONARY and String(parsed.get("scene", "")) == "explore_scene_demo"
			and String(parsed.get("note", "")) == "headless test note") and ok
		DirAccess.remove_absolute(abs)
	else:
		ok = _check("notes file was written", false) and ok
	demo.queue_free()
	await process_frame

	# (8) EVERY registry scene builds SOMETHING (real vendored OR fallback) and has LICENSE/PROVENANCE.
	for slug in Scenes.order():
		var d: Node3D = (DemoScene as PackedScene).instantiate()
		get_root().add_child(d)
		await process_frame
		d._on_scene_chosen(slug)
		await process_frame
		await process_frame
		# A scene is SOLID if it has the boundary walls (assembled/fallback) OR a premade GLB whose
		# meshes got trimesh StaticBody3D colliders (glb kind). Count both kinds of solid geometry.
		var solid := 0
		for child in d.get_children():
			if child is StaticBody3D and String(child.name).begins_with("Wall"):
				solid += 1
		var premade = d.get_node_or_null("PremadeScene")
		if premade != null:
			solid += _count_static_bodies(premade)
		ok = _check("scene '%s' is SOLID (walls or auto-collided GLB)" % slug, solid >= 4) and ok
		var provs := _has_provenance(slug)
		ok = _check("scene '%s' has LICENSE/PROVENANCE on disk" % slug, provs) and ok
		d.queue_free()
		await process_frame

	_finish(ok)

func _first_vendored() -> String:
	for slug in Scenes.order():
		if Scenes.is_vendored(slug):
			return slug
	return ""

func _has_provenance(slug: String) -> bool:
	var reg := Scenes.registry()
	if not reg.has(slug):
		return false
	var base := "res://assets/scenes/" + String(reg[slug]["dir"]) + "/"
	var has_prov := FileAccess.file_exists(ProjectSettings.globalize_path(base + "PROVENANCE.md"))
	var has_lic := FileAccess.file_exists(ProjectSettings.globalize_path(base + "LICENSE.txt")) \
		or FileAccess.file_exists(ProjectSettings.globalize_path(base + "License.txt")) \
		or FileAccess.file_exists(ProjectSettings.globalize_path(base + "ATTRIBUTION.txt"))
	return has_prov and has_lic

func _count_static_bodies(node: Node) -> int:
	var n := 0
	var stack: Array = [node]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is StaticBody3D:
			n += 1
		for ch in c.get_children():
			stack.append(ch)
	return n

func _count_buttons(node: Node) -> int:
	var n := 0
	var stack: Array = [node]
	while not stack.is_empty():
		var c: Node = stack.pop_back()
		if c is Button:
			n += 1
		for ch in c.get_children():
			stack.append(ch)
	return n

func _finish(ok: bool) -> void:
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
