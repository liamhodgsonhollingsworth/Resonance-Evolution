extends Node3D
## CREATIVE-MODE BUILDABLE SANDBOX (MVP) — a Minecraft-creative-style buildable world in the RE engine.
## Liam's ask (2026-07-02): "give this instance a basic minecraft style visual inventory with the same
## layout and controls as minecraft creative mode ... some basic blocks and placement systems ... a voxel
## based system ... some basic 3D asset building blocks that are untextured but can be textured using tools
## in the game engine."
##
## WHAT THIS IS (and is NOT):
##   • A SIMPLE, IN-ENGINE, universal grid-snapped placement sandbox — NO external voxel library ported.
##     The world is a plain Dictionary keyed by integer grid coord (Vector3i) → a block record; each placed
##     block is one MeshInstance3D. Minimal + readable — the "start iterating right away" core, not a
##     production voxel engine.
##   • Creative-mode FREE-FLY camera + controls (WASD + mouse-look + space/shift up/down), like MC creative.
##   • A Minecraft-creative INVENTORY UI: a 9-slot hotbar (number keys 1..9 select), a paged inventory grid
##     opened/closed with E, category tabs, click a block to load it into the active hotbar slot.
##   • The building blocks are the engine's 13-shape primitive vocabulary (box/sphere/cylinder/cone/torus/
##     plane/capsule/prism/wedge/pyramid/tube/stairs/arch) — reused verbatim from GodotSceneRenderer, so
##     "cube + all the parts-catalog shapes" are the palette. ORIGINAL/GENERIC blocks — no MC assets/textures.
##   • Blocks start UNTEXTURED (a plain material). The per-block `material`/`texture` slot is wired as DATA
##     (see BlockRecord below + _apply_material) — this is the CLEAN SEAM the deep node-based LIVE-TEXTURING
##     system attaches to later (a FABLE-5 handoff piece; NOT built here).
##
## HOTLOADABLE + OPENABLE (the live_demo / painterly_scene watcher pattern):
##   Open live (stays open, first-person creative build):
##     <Godot> --path godot res://examples/sandbox_creative.tscn
##   Headless proof PNG of a pre-seeded build, then quit:
##     <Godot> --path godot res://examples/sandbox_creative.tscn -- --shot
##   The world + settings HOT-RELOAD from godot/examples/sandbox_params.json by CONTENT (LiveHost-style):
##   edit the file and SAVE and the seeded blocks / fly speed / grid size re-apply live, no restart. This
##   is the "openable object you edit as DATA" seam — Claude Code (or Liam) can rewrite the world on disk.
##   (<Godot> = C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe for stdout.)
##
## CONTROLS (Minecraft creative parity):
##   Move        : W A S D            (relative to look direction, flattened to horizontal)
##   Up / Down   : Space / Shift
##   Look        : move mouse (pointer captured; ESC releases; click canvas to recapture)
##   Faster      : hold Ctrl (sprint)
##   Select slot : 1 .. 9 (or mouse wheel)
##   Place block : LEFT click  (on the grid cell adjacent to the face you're pointing at)
##   Remove block: RIGHT click (the block you're pointing at)
##   Inventory   : E  (opens the paged block picker + category tabs; click a block → active hotbar slot)

const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")

const PARAMS_PATH := "res://examples/sandbox_params.json"     # the file Liam/Claude edit to iterate the world
const SHOT_PATH := "res://docs/sandbox_creative.png"          # headless proof PNG (committed under docs/)

const GRID := 1.0                                             # default grid cell size (overridable via params)
const REACH := 8.0                                            # how far the build ray reaches, in cells

# ── the WORLD as DATA ────────────────────────────────────────────────────────────────────────────────
# A plain Dictionary keyed by Vector3i grid coord → a block record. This IS the "voxel-ish" store: simple,
# readable, universal. Each record carries the block's shape + params + the MATERIAL/TEXTURE SEAM (see below).
var world: Dictionary = {}                                    # Vector3i -> block record {type, shape, params, material, node}
var grid_size := GRID

# The BLOCK PALETTE — the engine's primitive vocabulary as generic, untextured building blocks. Each entry
# is pure DATA: a shape name (fed to GodotSceneRenderer._primitive_mesh), default params, a display color
# (so untextured blocks are visually distinguishable), and a category (the inventory tabs). NO MC assets.
var palette: Array = []                                       # filled in _build_palette()
var hotbar: Array = []                                        # 9 palette indices (the MC hotbar)
var active_slot := 0                                          # 0..8

# ── nodes ──────────────────────────────────────────────────────────────────────────────────────────
var _cam: Camera3D
var _blocks_root: Node3D
var _preview: MeshInstance3D                                  # ghost of the block about to be placed
var _hud: CanvasLayer
var _hotbar_ui: HBoxContainer
var _inv_panel: Panel
var _inv_grid: GridContainer
var _inv_tabs: HBoxContainer
var _inv_title: Label
var _crosshair: Control
var _status: Label

# ── camera / movement state ──────────────────────────────────────────────────────────────────────────
var _yaw := 0.0
var _pitch := -0.2
var fly_speed := 8.0                                          # metres/sec (overridable via params)
var sprint_mult := 3.0
var mouse_sens := 0.0025
var _inv_open := false
var _did_shot := false

# hotload watcher state (the painterly_scene / live_demo pattern: content-change → re-apply)
var _params_mtime := -1
var _headless := false


func _ready() -> void:
	_headless = DisplayServer.get_name() == "headless"
	_build_palette()
	_default_hotbar()
	_build_world_nodes()
	_build_env()
	if not _headless:
		_build_hud()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# Load the world + settings from the params file (writes a seed file on first run so there is something
	# to edit), then place the seeded blocks. This is the openable/hotloadable DATA seam.
	var cfg := _load_params()
	_apply_settings(cfg)
	_seed_world(cfg)
	_params_mtime = _mtime(PARAMS_PATH)
	# Position the camera to survey the seeded build.
	var start: Array = cfg.get("camera_start", [6.0, 6.0, 12.0])
	_cam.position = Vector3(start[0], start[1], start[2])
	_look_toward(Vector3(0.0, 1.0, 0.0))
	if _shot_requested():
		await _take_shot()


func _process(delta: float) -> void:
	# HOT-RELOAD watcher: if sandbox_params.json changed on disk, re-apply the world + settings live.
	if not _did_shot:
		var m := _mtime(PARAMS_PATH)
		if m != _params_mtime:
			_params_mtime = m
			var cfg := _load_params()
			_apply_settings(cfg)
			_seed_world(cfg, true)
	if _headless:
		return
	_update_movement(delta)
	_update_preview()


# ══ CREATIVE-MODE CAMERA + CONTROLS ═══════════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	if _headless:
		return
	# Mouse-look (only while the pointer is captured and the inventory is closed).
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sens
		_pitch = clampf(_pitch - event.relative.y * mouse_sens, -1.5, 1.5)
		_apply_camera_rotation()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_E:
				_toggle_inventory()
				return
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				return
		# Number keys 1..9 select the hotbar slot (MC parity).
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_select_slot(event.keycode - KEY_1)
			return
	if event is InputEventMouseButton and event.pressed:
		if _inv_open:
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED     # click to recapture after ESC
				else:
					_place_block()
			MOUSE_BUTTON_RIGHT:
				_remove_block()
			MOUSE_BUTTON_WHEEL_UP:
				_select_slot(wrapi(active_slot - 1, 0, 9))
			MOUSE_BUTTON_WHEEL_DOWN:
				_select_slot(wrapi(active_slot + 1, 0, 9))


func _update_movement(delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	var dir := Vector3.ZERO
	var basis := _cam.global_transform.basis
	# Horizontal move relative to look yaw (flatten forward/right to the XZ plane, MC-style).
	var fwd := -basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length() > 0.001 else Vector3.FORWARD
	var right := basis.x
	right.y = 0.0
	right = right.normalized() if right.length() > 0.001 else Vector3.RIGHT
	if Input.is_key_pressed(KEY_W): dir += fwd
	if Input.is_key_pressed(KEY_S): dir -= fwd
	if Input.is_key_pressed(KEY_D): dir += right
	if Input.is_key_pressed(KEY_A): dir -= right
	if Input.is_key_pressed(KEY_SPACE): dir += Vector3.UP
	if Input.is_key_pressed(KEY_SHIFT): dir += Vector3.DOWN
	if dir.length() > 0.001:
		var speed := fly_speed
		if Input.is_key_pressed(KEY_CTRL):
			speed *= sprint_mult
		_cam.position += dir.normalized() * speed * delta


func _apply_camera_rotation() -> void:
	var b := Basis.IDENTITY
	b = b.rotated(Vector3.UP, _yaw)
	b = b.rotated(b.x, _pitch)
	_cam.global_transform.basis = b


func _look_toward(target: Vector3) -> void:
	var to := (target - _cam.position)
	if to.length() < 0.001:
		return
	_yaw = atan2(-to.x, -to.z)
	_pitch = clampf(asin(to.normalized().y), -1.5, 1.5)
	_apply_camera_rotation()


# ══ BLOCK PLACEMENT / REMOVAL (simple grid-snapped, in-engine) ════════════════════════════════════════
# A ray from the camera steps forward in small increments; the first cell that contains a block is the
# TARGET. LEFT-click places on the empty cell just BEFORE that (the adjacent face), like MC. RIGHT-click
# removes the target cell. If the ray hits nothing, LEFT-click places at a fixed reach distance on the
# ground plane (y grid 0) so you can start a build in empty space.

## Returns { hit:bool, cell:Vector3i (the block hit), place:Vector3i (empty cell to place into) }.
func _raycast_grid() -> Dictionary:
	var origin := _cam.global_position
	var fwd := -_cam.global_transform.basis.z
	var step := 0.1
	var prev_cell := _world_to_cell(origin)
	var t := 0.0
	while t < REACH * grid_size:
		var p := origin + fwd * t
		var cell := _world_to_cell(p)
		if world.has(cell):
			return { "hit": true, "cell": cell, "place": prev_cell }
		prev_cell = cell
		t += step
	# No block hit: aim at a point half the reach out; place on that cell (its own coord), snapped.
	var far := origin + fwd * (REACH * grid_size * 0.5)
	return { "hit": false, "cell": _world_to_cell(far), "place": _world_to_cell(far) }


func _place_block() -> void:
	var rc := _raycast_grid()
	var cell: Vector3i = rc["place"]
	if world.has(cell):
		return
	var pal_idx: int = hotbar[active_slot]
	_set_block(cell, pal_idx)


func _remove_block() -> void:
	var rc := _raycast_grid()
	if not rc["hit"]:
		return
	_erase_block(rc["cell"])


## Place a palette block at a grid cell. This is the ONE write path into the world Dictionary + the scene:
## it records the block as DATA (shape/params/material seam) and instances exactly one MeshInstance3D.
func _set_block(cell: Vector3i, pal_idx: int) -> void:
	if pal_idx < 0 or pal_idx >= palette.size():
		return
	if world.has(cell):
		_erase_block(cell)
	var entry: Dictionary = palette[pal_idx]
	var mi := MeshInstance3D.new()
	mi.mesh = GodotSceneRenderer._primitive_mesh(String(entry["shape"]), entry.get("params", {}))
	mi.position = _cell_to_world(cell)
	_blocks_root.add_child(mi)
	# BlockRecord — the per-block DATA. `material` is the LIVE-TEXTURING SEAM (see _apply_material): today
	# it is just {albedo:[r,g,b]} (untextured plain colour); later a node-based texturing chip writes a
	# richer material/texture descriptor here and the block re-skins with ZERO placement-code change.
	var record := {
		"type": String(entry["name"]),
		"shape": String(entry["shape"]),
		"params": entry.get("params", {}).duplicate(true),
		"material": entry.get("material", {}).duplicate(true),   # ← the seam
		"node": mi,
	}
	_apply_material(mi, record["material"])
	world[cell] = record


func _erase_block(cell: Vector3i) -> void:
	if not world.has(cell):
		return
	var rec: Dictionary = world[cell]
	var n = rec.get("node", null)
	if n != null and is_instance_valid(n):
		n.queue_free()
	world.erase(cell)


# ── THE LIVE-TEXTURING SEAM ────────────────────────────────────────────────────────────────────────
# Every block gets its material HERE, from the block record's `material` DATA slot. Today the descriptor is
# minimal ({albedo:[r,g,b]} → a plain untextured StandardMaterial3D), so blocks start UNTEXTURED exactly as
# Liam asked. The seam is intentionally the SINGLE choke point: a later node-based live-texturing system
# only has to write a richer `material` descriptor (albedo_texture / roughness / normal_map / a node-graph
# handle) into the record and call _apply_material — the placement/removal/world code above never changes.
# This function is the documented FABLE-5 handoff attachment point.
func _apply_material(mi: MeshInstance3D, material_desc: Dictionary) -> void:
	var mat := StandardMaterial3D.new()
	var albedo = material_desc.get("albedo", [0.75, 0.75, 0.78])
	if typeof(albedo) == TYPE_ARRAY and albedo.size() >= 3:
		mat.albedo_color = Color(albedo[0], albedo[1], albedo[2])
	# --- SEAM: a future texturing chip fills these from the `material` descriptor ---
	var tex_path = material_desc.get("albedo_texture", "")
	if typeof(tex_path) == TYPE_STRING and tex_path != "" and ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)
	if material_desc.has("roughness"):
		mat.roughness = float(material_desc["roughness"])
	if material_desc.has("metallic"):
		mat.metallic = float(material_desc["metallic"])
	# --- end seam ---
	mi.material_override = mat


# ── grid math ────────────────────────────────────────────────────────────────────────────────────────
func _world_to_cell(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / grid_size + 0.5)), int(floor(p.y / grid_size + 0.5)), int(floor(p.z / grid_size + 0.5)))

func _cell_to_world(c: Vector3i) -> Vector3:
	return Vector3(c.x * grid_size, c.y * grid_size, c.z * grid_size)


# ══ THE BLOCK PALETTE (untextured generic building blocks) ════════════════════════════════════════════
# The engine's 13-shape primitive vocabulary, presented as generic untextured blocks in three categories
# (the inventory tabs). Each block is DATA: name, shape, params (sized ≈1 cell), a display colour so the
# untextured blocks are distinguishable, and a category. No Minecraft assets — the UX convention only.
func _build_palette() -> void:
	palette = [
		# --- Blocks (solid cell-filling) ---
		_pal("Cube",     "box",      {"width":1.0,"height":1.0,"depth":1.0},               [0.80,0.80,0.82], "Blocks"),
		_pal("Slab",     "box",      {"width":1.0,"height":0.5,"depth":1.0},               [0.66,0.70,0.74], "Blocks"),
		_pal("Panel",    "plane",    {"width":1.0,"depth":1.0},                            [0.72,0.74,0.60], "Blocks"),
		_pal("Pillar",   "cylinder", {"radius":0.4,"height":1.0},                          [0.78,0.72,0.60], "Blocks"),
		_pal("Ball",     "sphere",   {"radius":0.5},                                       [0.62,0.72,0.82], "Blocks"),
		_pal("Capsule",  "capsule",  {"radius":0.3,"height":1.0},                          [0.70,0.66,0.80], "Blocks"),
		_pal("Tube",     "tube",     {"outer_radius":0.5,"inner_radius":0.3,"height":1.0}, [0.60,0.66,0.70], "Blocks"),
		# --- Shapes (angled / decorative building parts) ---
		_pal("Cone",     "cone",     {"radius":0.5,"height":1.0},                          [0.82,0.68,0.56], "Shapes"),
		_pal("Pyramid",  "pyramid",  {"width":1.0,"height":1.0,"depth":1.0},               [0.84,0.74,0.52], "Shapes"),
		_pal("Wedge",    "wedge",    {"width":1.0,"height":1.0,"depth":1.0},               [0.66,0.78,0.64], "Shapes"),
		_pal("Prism",    "prism",    {"width":1.0,"height":1.0,"depth":1.0},               [0.60,0.80,0.70], "Shapes"),
		_pal("Torus",    "torus",    {"inner_radius":0.25,"outer_radius":0.5},             [0.78,0.60,0.72], "Shapes"),
		# --- Structures (composite multi-cell parts) ---
		_pal("Stairs",   "stairs",   {"width":1.0,"total_height":1.0,"total_depth":1.0,"steps":4}, [0.72,0.72,0.76], "Structures"),
		_pal("Arch",     "arch",     {"width":2.0,"height":2.0,"depth":0.6},               [0.76,0.70,0.66], "Structures"),
	]

func _pal(name: String, shape: String, params: Dictionary, albedo: Array, category: String) -> Dictionary:
	# `material` starts as a plain albedo colour (UNTEXTURED). This dict is the per-block live-texturing seam.
	return { "name": name, "shape": shape, "params": params, "material": { "albedo": albedo }, "category": category }

func _categories() -> Array:
	var seen := {}
	var out := []
	for e in palette:
		var c: String = e["category"]
		if not seen.has(c):
			seen[c] = true
			out.append(c)
	return out

func _default_hotbar() -> void:
	# The 9 MC hotbar slots seeded with the first 9 palette blocks.
	hotbar = []
	for i in 9:
		hotbar.append(i if i < palette.size() else 0)


# ══ MINECRAFT-CREATIVE INVENTORY UI ═══════════════════════════════════════════════════════════════════
# Same layout + controls as MC creative: a bottom-centre hotbar (9 slots, active slot highlighted, number
# keys select), and an E-toggled inventory panel with category TABS + a paged grid of every block. Click a
# block in the grid → it loads into the ACTIVE hotbar slot (MC creative behaviour).
func _build_hud() -> void:
	_hud = CanvasLayer.new()
	add_child(_hud)
	# Crosshair (a small + at screen centre).
	_crosshair = Control.new()
	_crosshair.set_anchors_preset(Control.PRESET_CENTER)
	_hud.add_child(_crosshair)
	var ch := Label.new()
	ch.text = "+"
	ch.add_theme_font_size_override("font_size", 22)
	ch.position = Vector2(-7, -16)
	_crosshair.add_child(ch)
	# Status line (top-left): active block + control hint.
	_status = Label.new()
	_status.position = Vector2(14, 10)
	_status.add_theme_font_size_override("font_size", 15)
	_hud.add_child(_status)
	# The hotbar (bottom-centre).
	_hotbar_ui = HBoxContainer.new()
	_hotbar_ui.add_theme_constant_override("separation", 4)
	_hotbar_ui.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_hotbar_ui.position = Vector2(0, -70)
	_hud.add_child(_hotbar_ui)
	_rebuild_hotbar_ui()
	# The inventory panel (hidden until E).
	_build_inventory_panel()
	_refresh_status()


func _rebuild_hotbar_ui() -> void:
	if _hotbar_ui == null:
		return
	for c in _hotbar_ui.get_children():
		c.queue_free()
	for i in 9:
		var slot := _make_slot_button(hotbar[i], i == active_slot, str(i + 1))
		var idx := i
		slot.pressed.connect(func(): _select_slot(idx))
		_hotbar_ui.add_child(slot)


func _make_slot_button(pal_idx: int, active: bool, label: String) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(56, 56)
	b.clip_text = true
	var entry: Dictionary = palette[pal_idx] if pal_idx >= 0 and pal_idx < palette.size() else {}
	if label != "":
		b.text = "%s\n%s" % [label, String(entry.get("name", "-"))]
	else:
		b.text = String(entry.get("name", "-"))
	b.add_theme_font_size_override("font_size", 11)
	# Tint the slot with the block's untextured albedo so the palette reads at a glance.
	var col_arr = entry.get("material", {}).get("albedo", [0.8, 0.8, 0.8])
	var col := Color(col_arr[0], col_arr[1], col_arr[2])
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.15)
	sb.set_border_width_all(3)
	sb.border_color = Color(1, 1, 0.4) if active else Color(0.15, 0.15, 0.18)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	return b


func _build_inventory_panel() -> void:
	_inv_panel = Panel.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	_inv_panel.custom_minimum_size = Vector2(520, 380)
	_inv_panel.size = Vector2(520, 380)
	_inv_panel.position = Vector2(-260, -190)
	_inv_panel.visible = false
	_hud.add_child(_inv_panel)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 8)
	vb.offset_left = 12; vb.offset_top = 10; vb.offset_right = -12; vb.offset_bottom = -12
	_inv_panel.add_child(vb)
	_inv_title = Label.new()
	_inv_title.text = "Creative Inventory  —  click a block → hotbar slot %d  (E to close)" % (active_slot + 1)
	_inv_title.add_theme_font_size_override("font_size", 14)
	vb.add_child(_inv_title)
	# Category tabs.
	_inv_tabs = HBoxContainer.new()
	_inv_tabs.add_theme_constant_override("separation", 6)
	vb.add_child(_inv_tabs)
	# The paged block grid.
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(scroll)
	_inv_grid = GridContainer.new()
	_inv_grid.columns = 6
	_inv_grid.add_theme_constant_override("h_separation", 6)
	_inv_grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(_inv_grid)
	_rebuild_inventory_tabs()
	_populate_inventory(_categories()[0] if _categories().size() > 0 else "Blocks")


var _active_category := "Blocks"

func _rebuild_inventory_tabs() -> void:
	for c in _inv_tabs.get_children():
		c.queue_free()
	for cat in _categories():
		var t := Button.new()
		t.text = cat
		t.toggle_mode = true
		t.button_pressed = (cat == _active_category)
		var cc := cat
		t.pressed.connect(func(): _populate_inventory(cc))
		_inv_tabs.add_child(t)


func _populate_inventory(category: String) -> void:
	_active_category = category
	for c in _inv_grid.get_children():
		c.queue_free()
	for pal_idx in palette.size():
		var entry: Dictionary = palette[pal_idx]
		if entry["category"] != category:
			continue
		var b := _make_slot_button(pal_idx, false, "")
		b.custom_minimum_size = Vector2(72, 72)
		b.add_theme_font_size_override("font_size", 12)
		var idx := pal_idx
		b.pressed.connect(func(): _pick_into_hotbar(idx))
		_inv_grid.add_child(b)
	# reflect the active tab
	for t in _inv_tabs.get_children():
		if t is Button:
			t.button_pressed = (t.text == category)


func _pick_into_hotbar(pal_idx: int) -> void:
	# MC creative: clicking a block in the inventory puts it in the ACTIVE hotbar slot.
	hotbar[active_slot] = pal_idx
	_rebuild_hotbar_ui()
	_refresh_status()
	_update_preview_mesh()


func _toggle_inventory() -> void:
	if _headless or _inv_panel == null:
		return
	_inv_open = not _inv_open
	_inv_panel.visible = _inv_open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _inv_open else Input.MOUSE_MODE_CAPTURED
	if _inv_open and _inv_title != null:
		_inv_title.text = "Creative Inventory  —  click a block → hotbar slot %d  (E to close)" % (active_slot + 1)


func _select_slot(i: int) -> void:
	active_slot = clampi(i, 0, 8)
	_rebuild_hotbar_ui()
	_refresh_status()
	_update_preview_mesh()


func _refresh_status() -> void:
	if _status == null:
		return
	var entry: Dictionary = palette[hotbar[active_slot]]
	_status.text = "Block: %s   (slot %d)   |   L-click place · R-click remove · 1-9 select · E inventory · WASD+Space/Shift fly" % [
		String(entry["name"]), active_slot + 1]


# ── the placement PREVIEW ghost (shows where the next block lands) ────────────────────────────────────
func _update_preview() -> void:
	if _inv_open or _cam == null:
		if _preview != null:
			_preview.visible = false
		return
	var rc := _raycast_grid()
	var cell: Vector3i = rc["place"]
	if _preview == null:
		return
	if world.has(cell):
		_preview.visible = false
		return
	_preview.visible = true
	_preview.position = _cell_to_world(cell)


func _update_preview_mesh() -> void:
	if _preview == null:
		return
	var entry: Dictionary = palette[hotbar[active_slot]]
	_preview.mesh = GodotSceneRenderer._primitive_mesh(String(entry["shape"]), entry.get("params", {}))


# ══ WORLD NODES + ENVIRONMENT ═════════════════════════════════════════════════════════════════════════
func _build_world_nodes() -> void:
	_cam = Camera3D.new()
	_cam.fov = 70.0
	add_child(_cam)
	_blocks_root = Node3D.new()
	_blocks_root.name = "Blocks"
	add_child(_blocks_root)
	# The translucent placement ghost.
	if not _headless:
		_preview = MeshInstance3D.new()
		var ghost := StandardMaterial3D.new()
		ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost.albedo_color = Color(1, 1, 1, 0.35)
		_preview.material_override = ghost
		_preview.visible = false
		add_child(_preview)
		_update_preview_mesh()


func _build_env() -> void:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.15
	light.shadow_enabled = true
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.38, 0.56, 0.82)
	sky_mat.sky_horizon_color = Color(0.72, 0.80, 0.88)
	sky_mat.ground_horizon_color = Color(0.66, 0.70, 0.66)
	sky_mat.ground_bottom_color = Color(0.42, 0.46, 0.42)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env_node.environment = env
	add_child(env_node)
	# A subtle ground plate so the build has a floor reference (not itself a placeable block).
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(64, 64)
	floor_mi.mesh = pm
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.30, 0.34, 0.30)
	floor_mi.material_override = fmat
	floor_mi.position = Vector3(0, -0.5 * grid_size, 0)
	add_child(floor_mi)


# ══ PARAMS: the openable / hotloadable world DATA ═════════════════════════════════════════════════════
# The world + settings live in godot/examples/sandbox_params.json — the ONE file Claude Code (or Liam)
# edits to iterate the sandbox. Content-change → re-apply (the LiveHost pattern). On first run a seed file
# is written so there is something to edit.
func _load_params() -> Dictionary:
	if FileAccess.file_exists(PARAMS_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
		if typeof(data) == TYPE_DICTIONARY:
			return data
	var cfg := _default_params()
	var f := FileAccess.open(PARAMS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(cfg, "\t"))
		f.close()
	return cfg


func _apply_settings(cfg: Dictionary) -> void:
	grid_size = float(cfg.get("grid_size", GRID))
	fly_speed = float(cfg.get("fly_speed", 8.0))
	mouse_sens = float(cfg.get("mouse_sensitivity", 0.0025))


## Seed (or, on hotload, re-seed) the world from the params `blocks` list. Each entry is
## {cell:[x,y,z], block:"Cube"} — a grid coord + a palette block NAME. On a live re-seed we clear the
## world first so the params file is the source of truth for the seeded build.
func _seed_world(cfg: Dictionary, is_reload := false) -> void:
	if is_reload:
		for cell in world.keys():
			var rec: Dictionary = world[cell]
			var n = rec.get("node", null)
			if n != null and is_instance_valid(n):
				n.queue_free()
		world.clear()
	var blocks = cfg.get("blocks", [])
	if typeof(blocks) != TYPE_ARRAY:
		return
	for b in blocks:
		if typeof(b) != TYPE_DICTIONARY:
			continue
		var cell_arr = b.get("cell", [0, 0, 0])
		if typeof(cell_arr) != TYPE_ARRAY or cell_arr.size() < 3:
			continue
		var cell := Vector3i(int(cell_arr[0]), int(cell_arr[1]), int(cell_arr[2]))
		var pal_idx := _palette_index(String(b.get("block", "Cube")))
		if pal_idx >= 0:
			_set_block(cell, pal_idx)


func _palette_index(name: String) -> int:
	for i in palette.size():
		if String(palette[i]["name"]) == name:
			return i
	return -1


## The seed world: a small demo build so the sandbox is meaningful out of the box — a plinth of cubes, a
## couple of pillars, an arch gateway, a staircase, and a few decorative shapes on top. All grid-snapped.
func _default_params() -> Dictionary:
	var blocks := []
	# a 5x5 cube floor plinth at y=0
	for x in range(-2, 3):
		for z in range(-2, 3):
			blocks.append({ "cell": [x, 0, z], "block": "Cube" })
	# two pillars
	for y in range(1, 4):
		blocks.append({ "cell": [-2, y, -2], "block": "Pillar" })
		blocks.append({ "cell": [2, y, -2], "block": "Pillar" })
	# spheres capping the pillars
	blocks.append({ "cell": [-2, 4, -2], "block": "Ball" })
	blocks.append({ "cell": [2, 4, -2], "block": "Ball" })
	# an arch gateway centred
	blocks.append({ "cell": [0, 2, -2], "block": "Arch" })
	# a staircase leading up
	blocks.append({ "cell": [0, 1, 2], "block": "Stairs" })
	# decorative shapes on the plinth
	blocks.append({ "cell": [-1, 1, 0], "block": "Cone" })
	blocks.append({ "cell": [1, 1, 0], "block": "Pyramid" })
	blocks.append({ "cell": [0, 1, 1], "block": "Wedge" })
	blocks.append({ "cell": [-2, 1, 2], "block": "Torus" })
	blocks.append({ "cell": [2, 1, 2], "block": "Capsule" })
	return {
		"grid_size": 1.0,
		"fly_speed": 8.0,
		"mouse_sensitivity": 0.0025,
		"camera_start": [6.0, 6.0, 12.0],
		"blocks": blocks,
	}


# ══ HEADLESS PROOF ════════════════════════════════════════════════════════════════════════════════════
# --shot: render the seeded build to a proof PNG (docs/sandbox_creative.png), then quit. Runs windowed
# (a real viewport is needed to grab pixels); the caller supplies a window via the normal scene launch.
func _take_shot() -> void:
	_did_shot = true
	# Let the scene light + render a few frames before grabbing.
	for _i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://docs")
	img.save_png(SHOT_PATH)
	print("[sandbox_creative] proof written: %s  (%d blocks placed)" % [SHOT_PATH, world.size()])
	get_tree().quit(0)


func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()


func _mtime(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	return int(FileAccess.get_modified_time(ProjectSettings.globalize_path(path)))
