extends RefCounted
## WIRING TOOL — the point-and-bind tool that opens an object's in-world node panel (Dreams-arc Slice 1).
##
## "Equip a wiring tool → point at an object → its node panel opens in-world → close → edits are live."
## This module is the small, pure resolver in the middle: given what the player is POINTING AT, it finds
## the bindable object and returns the arrangement-file path whose GraphPanel should open. The room does
## the mounting (via graph_panel_mount.gd); this file owns only "which object, which arrangement file".
##
## IT REUSES TWO EXISTING SEAMS (no new targeting logic, no primitive edits):
##   1. The AIM seam — the room already raycasts a crosshair ray and records `_aimed_meta.obj_id` for the
##      Area3D under the crosshair (aperture_3d.gd:_update_aim). "Point at an object" == read that obj_id.
##   2. The PROXIMITY seam — PickupInteractor (walkabout/pickup_interactor.gd) registers objects and, per
##      frame, computes which are within range via the `proximity` Context handler (register/refresh/
##      available_ids). Used as the FALLBACK target when the crosshair isn't dead-on an object: bind the
##      nearest in-range one. This is the SAME register + KEY_E-edge "use what you're near" mechanism the
##      pickup interactor already ships — reused, not reimplemented.
##
## The BIND itself is edge-triggered exactly like PickupInteractor's KEY_E path (fire once on the press
## transition, not every frame) — the room supplies the edge; this module supplies the resolution.
##
## Arrangement file convention (Slice 1, minimal — NOT a new store): each bindable object's node graph
## lives at `user://object_arrangements/<safe_id>.json`. It is the SAME container GraphPanel commits and
## LiveHost hot-loads, so editing the panel live-writes it and the running graph re-wires as a diff. When
## an object has no arrangement yet, seed_arrangement() writes a tiny starter (a Const wired into a
## WorldAction:log) so opening a fresh object shows a real, editable, hot-loadable graph.
##
## No class_name (mistake #046): the room preloads this file by path.

const ARRANGEMENT_DIR := "user://object_arrangements"


## The arrangement-file path for an object id (deterministic, filesystem-safe).
static func arrangement_path_for(object_id: String) -> String:
	return "%s/%s.json" % [ARRANGEMENT_DIR, _safe(object_id)]


## Resolve WHICH object the player is binding, given the room's aim + an optional PickupInteractor for the
## proximity fallback. Returns "" when nothing is bindable. Aim wins (dead-on the crosshair); otherwise
## the nearest in-range pickable (the "use what you're near" reuse). `player_pos` refreshes proximity.
static func resolve_target(aimed_meta: Dictionary, interactor: Object = null, player_pos = null) -> String:
	# 1) AIM: the crosshair is on an object with an obj_id meta.
	var aimed := String(aimed_meta.get("obj_id", "")) if aimed_meta != null else ""
	if aimed != "":
		return aimed
	# 2) PROXIMITY FALLBACK: the nearest in-range pickable (PickupInteractor's register/refresh seam).
	if interactor != null and is_instance_valid(interactor) and interactor.has_method("available_ids"):
		if player_pos != null and interactor.has_method("refresh"):
			interactor.refresh(player_pos)
		var ids: Array = interactor.available_ids()
		if not ids.is_empty():
			return String(ids[0])
	return ""


## Ensure the object's arrangement file exists, seeding a minimal starter graph if absent. Returns the
## path (ready to hand to GraphPanel.commit_path / graph_panel_mount.open_panel). The starter is a Const
## feeding a WorldAction:log — a real 2-node, 1-wire graph that evaluates + hot-loads, so a freshly-bound
## object opens with something editable rather than an empty canvas.
static func ensure_arrangement(object_id: String) -> String:
	var path := arrangement_path_for(object_id)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ARRANGEMENT_DIR))
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(seed_arrangement(object_id), "\t"))
			f.close()
	return path


## The minimal starter arrangement for a freshly-bound object: a Const value wired into a WorldAction
## whose op is `log`. Two nodes, one wire — a genuine editable graph in resonance.arrangement/v1.
static func seed_arrangement(object_id: String) -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"name": "object_%s" % _safe(object_id),
		"nodes": [
			{ "id": "src", "type": "Const", "params": { "value": 1 }, "pos": [40, 60] },
			{ "id": "act", "type": "WorldAction",
				"params": { "op": "log", "message": "bound %s" % object_id }, "pos": [320, 60] },
		],
		"wires": [
			{ "from": "src", "out": "value", "to": "act", "in": "value" },
		],
	}


static func _safe(s: String) -> String:
	var out := ""
	for c in s:
		if (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9") or c == "_" or c == "-":
			out += c
		else:
			out += "_"
	return out if out != "" else "unnamed"
