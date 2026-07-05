extends RefCounted
## SCENE REGISTRY for the explore-a-scene demo. Data-only: maps a scene SLUG to how its environment
## is built, so one explorer (explore_scene_demo.gd) can open ANY of the vendored scenes by passing
## `--scene-params={"scene":"<slug>"}` (the scene_launcher params path). Liam approved all 5 candidate
## scenes (2026-07-05); each is vendored under res://assets/scenes/<slug>/ with a LICENSE + PROVENANCE.
##
## Two ENVIRONMENT KINDS (both end up as SOLID geometry you run into + props you grab):
##   * "glb"       — a single pre-assembled GLB scene loaded as the world; its meshes are auto-wrapped
##                   in trimesh colliders so its walls/floor are solid. A few kit props are scattered
##                   as collectibles on top.
##   * "assembled" — a KIT of individual GLB pieces (walls/floor/columns + props). The explorer lays
##                   out a walled room from the structure pieces and scatters the props as
##                   grab-into-inventory collectibles. (Kenney/KayKit/Quaternius ship as kits, not
##                   pre-built scenes, so this is how they become an explorable space.)
##
## Every field is DATA. Adding a 6th scene is a new dictionary entry here + a vendored asset dir —
## no change to the explorer mechanic. `attribution` is surfaced in-scene (a corner label) + on the
## card for CC-BY scenes; empty for CC0/MIT.

const SCENES_DIR := "res://assets/scenes/"

## slug -> config. `dir` is relative to SCENES_DIR. `structure` / `props` are GLB basenames (without
## .glb) inside <dir>/glb/. `glb` is a single pre-assembled scene path inside <dir>/glb/.
static func registry() -> Dictionary:
	return {
		"kaykit_dungeon": {
			"title": "KayKit Dungeon Remastered",
			"kind": "assembled",
			"dir": "kaykit_dungeon",
			"license": "CC0",
			"attribution": "",
			# Filled from whatever the vendored kit actually contains (resolved at load time by name
			# match); these are the PREFERRED basenames, matched loosely so a slightly different file
			# name still works.
			"structure_hints": ["wall", "floor", "column", "pillar", "corner", "stairs", "gate", "arch"],
			"prop_hints": ["barrel", "chest", "crate", "torch", "coin", "key", "bottle", "banner", "candle", "bones", "skull", "pot", "shield", "sword", "axe"],
		},
		"godot_platformer": {
			"title": "Godot 3D Platformer level",
			"kind": "glb",
			"dir": "godot_platformer",
			"glb": "stage.glb",
			"license": "MIT",
			"attribution": "",
			# Props scattered on top come from the already-imported Kenney/Quaternius manifest kits
			# (this scene has no loose props of its own).
			"prop_source": "manifest",
		},
		"kenney_mini_dungeon": {
			"title": "Kenney Mini Dungeon",
			"kind": "assembled",
			"dir": "kenney_mini_dungeon",
			"license": "CC0",
			"attribution": "",
			"structure_hints": ["wall", "floor", "column", "gate", "stairs", "dirt", "wood-structure", "wood-support"],
			"prop_hints": ["barrel", "chest", "coin", "banner", "rocks", "stones", "trap", "shield", "weapon"],
		},
		"quaternius_dungeon": {
			"title": "Quaternius Modular Dungeon",
			"kind": "assembled",
			"dir": "quaternius_dungeon",
			"license": "CC0",
			"attribution": "",
			"structure_hints": ["wall", "floor", "column", "pillar", "corner", "stairs", "arch", "door"],
			"prop_hints": ["barrel", "chest", "crate", "torch", "coin", "key", "bottle", "banner", "candle", "bones", "skull", "pot", "chair", "table"],
		},
		"sketchfab_dungeon": {
			"title": "Sketchfab dungeon environment",
			"kind": "glb",
			"dir": "sketchfab_dungeon",
			"glb": "scene.glb",
			"license": "CC-BY 4.0",
			# Filled from the vendored ATTRIBUTION.txt at load time when present; this is the fallback.
			"attribution": "Dungeon environment — CC-BY 4.0 (see PROVENANCE)",
			"prop_source": "manifest",
		},
	}

## Ordered slug list for the selector menu (best-first, matching the approval ranking).
static func order() -> Array:
	return ["kaykit_dungeon", "godot_platformer", "kenney_mini_dungeon", "quaternius_dungeon", "sketchfab_dungeon"]

## The absolute glb/ dir for a scene, or "" if the slug is unknown.
static func glb_dir(slug: String) -> String:
	var reg := registry()
	if not reg.has(slug):
		return ""
	return SCENES_DIR + String(reg[slug]["dir"]) + "/glb/"

## Does this scene have vendored assets present on disk? (A scene whose download failed has an empty
## glb/ dir → the explorer shows the procedural fallback for it instead of hard-failing.)
static func is_vendored(slug: String) -> bool:
	var d := glb_dir(slug)
	if d == "":
		return false
	var abs := ProjectSettings.globalize_path(d)
	if not DirAccess.dir_exists_absolute(abs):
		return false
	var da := DirAccess.open(abs)
	if da == null:
		return false
	for f in da.get_files():
		if f.to_lower().ends_with(".glb"):
			return true
	return false

## List the .glb basenames (without extension) present in a scene's glb/ dir, sorted.
static func glb_names(slug: String) -> Array:
	var out: Array = []
	var abs := ProjectSettings.globalize_path(glb_dir(slug))
	var da := DirAccess.open(abs)
	if da == null:
		return out
	for f in da.get_files():
		if f.to_lower().ends_with(".glb"):
			out.append(f.get_basename())
	out.sort()
	return out

## Resolve the vendored ATTRIBUTION.txt (CC-BY) first line, if present — surfaced in-scene + on card.
static func attribution_line(slug: String) -> String:
	var reg := registry()
	if not reg.has(slug):
		return ""
	var att_path := ProjectSettings.globalize_path(SCENES_DIR + String(reg[slug]["dir"]) + "/ATTRIBUTION.txt")
	if FileAccess.file_exists(att_path):
		var txt := FileAccess.get_file_as_string(att_path)
		# Prefer the file's explicit "Short credit line" (meant for an on-screen credit); fall back
		# to the registry's clean attribution string, never the file's header line.
		var lines := txt.split("\n")
		for i in lines.size():
			if String(lines[i]).to_lower().contains("short credit line"):
				for j in range(i + 1, lines.size()):
					var s := String(lines[j]).strip_edges()
					if s != "":
						return s
	return String(reg[slug].get("attribution", ""))
