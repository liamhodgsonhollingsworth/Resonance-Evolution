extends Node3D
## CREATIVE-MODE BUILDABLE SANDBOX — a Minecraft-creative-style buildable world in the RE engine,
## extended into a GENERAL-PURPOSE WORLD BUILDER (spec apx_e5c6f8dc, 2026-07-03).
##
## Liam's original ask (2026-07-02): "give this instance a basic minecraft style visual inventory with
## the same layout and controls as minecraft creative mode ... some basic blocks and placement systems
## ... a voxel based system ... some basic 3D asset building blocks that are untextured but can be
## textured using tools in the game engine."
##
## Liam's world-builder spec (2026-07-03, card apx_e5c6f8dc — each capability below traces to it):
##   • ALL IMPORTED ASSETS: "include not just the assets that you loaded there but also the other ones
##     that were found and imported for other experiments" → every asset in godot/assets/manifest.json
##     appears in the creative inventory (per-kit tabs), alongside the original block palette.
##   • LAZY LOADING: "efficient for having any number of assets by not having them loaded when the game
##     starts up and instead loading them when they are needed, or starting the sandbox with a
##     preselected arrangement that are preloaded and changing that as I move from scene to scene" →
##     runtime/asset_library.gd loads GLBs on demand (background thread + placeholder), each world
##     carries its derived preload set, and switching worlds evicts what the new one does not use.
##   • PLACE + REARRANGE: "not only placing objects but also rearranging them" → F selects the object
##     under the crosshair; G grabs it (follows the build ray, click drops); R/Shift+R rotates; +/-
##     scales; X deletes. Worlds persist as APPEND-ONLY versioned data files (runtime/world_store.gd).
##   • BEHAVIOR ADD/CHANGE: "adding and changing their behavior" → composable DATA behaviors
##     (runtime/sandbox_behaviors.gd: spin/orbit/bob/follow/light); B toggles them on the selection.
##   • NOTES → CLAUDE CODE: "leaving notes and comments on specific things which can get handed off to
##     claude code" → N leaves a note on the selected object (or crosshair spot); notes append to
##     G:/Wavelet/Alethea-cc/state/sandbox/notes.jsonl with world/object/asset/position context.
##   (The UI beyond these minimal key-driven affordances is deliberately NOT designed here — the spec
##    ends "ask me how I want the UI for this system to work"; that Q/A happens before any UI build.)
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
##     system attaches to later.
##
## HOTLOADABLE + OPENABLE (the live_demo / painterly_scene watcher pattern):
##   Open live (stays open, first-person creative build):
##     <Godot> --path godot res://examples/sandbox_creative.tscn
##   Headless proof PNG of a pre-seeded build, then quit:
##     <Godot> --path godot res://examples/sandbox_creative.tscn -- --shot
##   Startup/memory numbers (headless-safe):
##     <Godot> --headless --path godot res://examples/sandbox_creative.tscn -- --bench [--eager]
##   TWO hot-reload seams, both content-watched (LiveHost-style), no restart:
##     1. godot/examples/sandbox_params.json — settings (fly speed, grid, active world selection).
##     2. the ACTIVE WORLD's latest version file in the world store — edit it (or save a NEW version:
##        the store is append-only) and the running scene re-seeds live. This is the seam Claude Code
##        uses to iterate a world on disk while it stays open.
##   (<Godot> = C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe for stdout.)
##
## CONTROLS — MINECRAFT DEFAULTS (Liam spec 2026-07-03; empty hand = standard MC):
##   Move        : W A S D            (relative to look direction, flattened to horizontal)
##   Up / Down   : Space / Shift
##   Look        : move mouse (pointer captured; ESC releases; click canvas to recapture)
##   Faster      : hold Ctrl (sprint)
##   Select slot : 1 .. 9 (or mouse wheel)
##   PLACE       : RIGHT click  (block OR asset, per the active hotbar entry) — MC place
##   DESTROY     : LEFT click   (the block or placed object you're pointing at) — MC destroy
##   PICK        : MIDDLE click  (the thing you're looking at → into the hand/hotbar) — MC pick-block
##   Inventory   : E  (drag-and-drop block+asset+tool picker, image previews; drag → hotbar slot)
##   Save world  : F5 (append-only: writes version N+1, never overwrites)
##   Switch world: [ / ]  (previous / next world; preloads swap scene-to-scene)
##
## HELD-ITEM SEAM (spec: "items I can hold in my hand ... clicking using those items has
## different behavior than usual"): what you hold decides what clicking does. Empty hand = the
## MC defaults above. A TOOL item overrides them (see runtime/sandbox_items.gd + sticky_note.gd):
##   Sticky Note : hold it, aim at any surface (a preview orb shows the exact stick point), LEFT
##                 click sticks a note there (rides the object if it moves), then type; Enter saves.
##   (The rotate/scale/manipulate WAND is a queued tool — a future handler in the same seam.)
##
## DEBUG VERB LAYER (superseded default, kept reachable — press BACKSLASH \ to toggle):
##   The pre-2026-07-03 default verbs are NOT gone, only demoted. Toggle the debug layer on and:
##   F select obj · G grab/drop · R/Shift+R rotate · +/- scale · X delete · B behaviors · N note.
##   Append-only supersession: MC controls are the default; these remain for power/debug use.

const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")
const AssetLibraryScript := preload("res://runtime/asset_library.gd")
const Behaviors := preload("res://runtime/sandbox_behaviors.gd")
const WorldStoreScript := preload("res://runtime/world_store.gd")
const Items := preload("res://runtime/sandbox_items.gd")               # held-item seam (MC-default + tool handlers)
const StickyNote := preload("res://runtime/sticky_note.gd")            # the one tool built now
const ItemThumbnails := preload("res://runtime/item_thumbnails.gd")   # inventory image previews
const _InvSlot := preload("res://examples/sandbox_inventory_slot.gd") # drag-and-drop inventory/hotbar slot

const PARAMS_PATH := "res://examples/sandbox_params.json"     # the file Liam/Claude edit to iterate settings
const SHOT_PATH := "res://docs/sandbox_creative.png"          # headless proof PNG (committed under docs/)
const DEFAULT_NOTES_PATH := "G:/Wavelet/Alethea-cc/state/sandbox/notes.jsonl"

const GRID := 1.0                                             # default grid cell size (overridable via params)
const REACH := 8.0                                            # legacy voxel build-ray reach, in cells (seeds/hotload)

# ── FREE PLACEMENT + REACH TUNING (Liam correction 2026-07-05) ─────────────────────────────────────────
# Liam: "the grid system of assets as well as the highlighted preview location of the assets was not asked
# for. Let me ... place items and assets anywhere". Runtime placement is FREE: the held block/asset spawns
# at the EXACT raycast hit point under the crosshair (free position + orientation), NO grid snap and NO
# grid-cell preview marker. Fine repositioning comes later via a queued wand tool (NOT built here).
# `reach_distance` is the ONE tunable for how far place/destroy/grab/target reach, in metres (coordinator
# control #2 — a single exported/params knob). The voxel layer (world dict / _raycast_grid / _set_block) is
# KEPT for seeded + hotloaded worlds and backward compat, but the PLAYER's own placements go through the
# free path into the object layer (which already supports arbitrary position + orientation).
@export var reach_distance := 8.0                            # metres; place/destroy/grab/target reach (params-tunable)

# ── the WORLD as DATA ────────────────────────────────────────────────────────────────────────────────
# Two layers, both pure data:
#   blocks : Dictionary keyed by Vector3i grid coord → block record (the voxel layer, unchanged).
#   objects: Dictionary keyed by obj id → object record (the free-asset layer: any manifest asset,
#            grid-snapped on placement, freely rearrangeable, with composable behaviors).
var world: Dictionary = {}                                    # Vector3i -> block record {type, shape, params, material, node} (voxel: seeds/hotload)
var objects: Dictionary = {}                                  # "obj_N" -> {id, asset|block, base_pos, yaw_deg, scale, behaviors, node, loaded, aabb}
#   The object layer is the FREE-PLACEMENT layer (Liam 2026-07-05): a placed record carries EITHER an
#   `asset` (a manifest GLB) OR a `block` (a primitive shape name from the palette) — both placed at an
#   arbitrary world `base_pos` + `yaw_deg`, no grid. `pal_idx` records which palette entry made it (so
#   MIDDLE-click pick can put it back in hand). This is how "place items and assets anywhere" is realized
#   without a voxel grid, while the voxel `world` dict stays for backward-compatible seeded worlds.
var grid_size := GRID
var world_name := "starter"                                   # the active world (arrangement)
var _obj_seq := 0                                             # monotonic object-id counter (kept above loaded ids)

# The BLOCK PALETTE — the engine's primitive vocabulary as generic, untextured building blocks, PLUS
# (appended in _ready) every manifest asset as kind:"asset" entries under per-kit category tabs.
var palette: Array = []                                       # filled in _build_palette / _extend_palette_with_assets
var hotbar: Array = []                                        # 9 palette indices; EMPTY_HAND (-1) = holding nothing
var active_slot := 0                                          # 0..8

## EMPTY HAND (Liam item 1, 2026-07-05): holding nothing is a REAL, selectable hotbar state. A slot set to
## EMPTY_HAND holds no item — with an empty hand the MC defaults apply: LMB destroys the targeted thing,
## RMB does nothing (nothing to place), MMB picks the looked-at thing INTO the hand. Q (drop) empties the
## active slot back to this state.
const EMPTY_HAND := -1

# ── modules ─────────────────────────────────────────────────────────────────────────────────────────
var assets: Node = null                                       # AssetLibrary (lazy loader; child node)
var store = null                                              # WorldStore (RefCounted)

# ── nodes ──────────────────────────────────────────────────────────────────────────────────────────
var _cam: Camera3D
var _blocks_root: Node3D
var _objects_root: Node3D
var _preview: MeshInstance3D                                  # ghost of the block about to be placed
var _sel_marker: MeshInstance3D                               # translucent box around the selection
var _target_outline: MeshInstance3D                           # OBJECT-target outline: the thing LMB destroy / MMB pick will act on
var _hud: CanvasLayer
var _hotbar_ui: HBoxContainer
var _inv_panel: Panel
var _inv_grid: GridContainer
var _inv_tabs: HBoxContainer
var _inv_title: Label
var _inv_search: LineEdit
var _inv_query := ""                                          # active inventory search substring ("" = browse by tab)
var _crosshair: Control
var _status: Label
var _behavior_panel: Panel
var _behavior_list: Label
var _note_panel: Panel
var _note_edit: LineEdit
var _note_target_label: Label

# ── camera / movement state ──────────────────────────────────────────────────────────────────────────
var _yaw := 0.0
var _pitch := -0.2
var fly_speed := 8.0                                          # metres/sec (overridable via params)
var sprint_mult := 3.0
var mouse_sens := 0.0025
var _inv_open := false
var _did_shot := false

# ── selection / rearrange state ──────────────────────────────────────────────────────────────────────
var selected_id := ""                                         # the selected object ("" = none)
var _grabbing := false                                        # selection follows the build ray until dropped
# The CURRENT crosshair TARGET (coordinator control #2): the object/block LMB-destroy / MMB-pick will act
# on, outlined each frame so it is clear what a click hits. This is an OBJECT-target highlight (the actual
# thing you point at) — NOT the grid-cell placement preview Liam rejected. { kind:"object"/"block"/"", id/cell }.
var _target := { "kind": "" }
var _behavior_open := false
var _note_open := false
var _time := 0.0                                              # behavior clock (seconds since scene start)

# ── held-item seam + sticky notes (Liam spec 2026-07-03) ──────────────────────────────────────────────
var _debug_verbs := false                                    # the superseded F/G/R/+-/X verb layer (BACKSLASH toggles)
var _handlers: Dictionary = {}                               # palette index -> tool handler object (lazily built)
var _active_handler = null                                   # handler for the currently held item (empty hand => null)
var _preview3d_root: Node3D = null                           # parent for held-tool 3D previews (the sticky-note orb)
var _notes: Dictionary = {}                                  # note_id -> note record (anchor + text + render node)
var _note_seq := 0                                           # monotonic note-id counter
var _notes_root: Node3D = null                               # parent for stuck-note render meshes
var _editing_note_id := ""                                   # the note whose text the editor is currently editing
var _feedback_mode := false                                  # the note editor is capturing IN-SCENE FEEDBACK (F1), not a stuck note
var thumbs = null                                            # ItemThumbnails (image previews; lazily built)

# hotload watcher state (the painterly_scene / live_demo pattern: content-change → re-apply)
var _params_mtime := -1
var _world_watch_path := ""                                   # latest version file of the active world
var _world_watch_hash := ""
var _world_poll_accum := 0.0
var _headless := false

# persistence config (params/env-overridable so tests never touch the real store)
var worlds_dir_override := ""
var notes_path := DEFAULT_NOTES_PATH


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	_headless = DisplayServer.get_name() == "headless"
	_build_action_map()
	_build_palette()
	_default_hotbar()
	_build_world_nodes()
	_build_env()
	# The lazy asset library: reads ONLY the manifest at startup (metadata; no GLB bytes).
	assets = AssetLibraryScript.new()
	assets.name = "AssetLibrary"
	add_child(assets)
	assets.load_manifest()
	assets.asset_ready.connect(_on_asset_ready)
	_extend_palette_with_assets()
	if not _headless:
		# Inventory image previews (small low-quality thumbnail screenshots), cached to disk per host.
		thumbs = ItemThumbnails.new(get_tree())
		_build_hud()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_refresh_held_item()                         # select the handler for the starting hotbar slot
	# Settings from the params file (writes a seed file on first run so there is something to edit).
	var cfg := _load_params()
	_apply_settings(cfg)
	_params_mtime = _mtime(PARAMS_PATH)
	# The world store (append-only versioned arrangements, OUTSIDE the repo). Committed seed worlds
	# are copied in on first touch; the params file picks the starting world.
	var wdir := _resolve_worlds_dir(cfg)
	store = WorldStoreScript.new(wdir)
	store.seed_from()
	world_name = String(cfg.get("world", "starter"))
	if not _load_active_world():
		# Fallback (no store world): seed from the params `blocks` list — the original behavior.
		_seed_world(cfg)
	# Position the camera to survey the seeded build.
	var start: Array = cfg.get("camera_start", [6.0, 6.0, 12.0])
	_cam.position = Vector3(start[0], start[1], start[2])
	_look_toward(Vector3(0.0, 1.0, 0.0))
	if _bench_requested():
		await _run_bench(t0)
		return
	if _shot_requested():
		await _take_shot()


func _process(delta: float) -> void:
	_time += delta
	# HOT-RELOAD watcher 1: settings + world selection (sandbox_params.json).
	if not _did_shot:
		var m := _mtime(PARAMS_PATH)
		if m != _params_mtime:
			_params_mtime = m
			var cfg := _load_params()
			_apply_settings(cfg)
			var w := String(cfg.get("world", world_name))
			if w != world_name:
				_switch_world(w)
		# HOT-RELOAD watcher 2: the active world's latest version file (Claude-Code-iterates seam).
		_world_poll_accum += delta
		if _world_poll_accum >= 0.5:
			_world_poll_accum = 0.0
			_poll_world_file()
	_tick_objects(delta)
	if _headless:
		return
	_update_movement(delta)
	_update_target()                             # what the crosshair points at (LMB destroy / MMB pick)
	_update_target_outline()                     # outline that target (Liam correction: object-target, NOT grid preview)
	_update_preview()                            # subtle placement-point dot at the free aim point
	_update_selection_marker()
	_tick_notes()                                # notes ride their (moving) targets
	# The held tool draws its per-frame preview (the sticky-note orb at the aimed point).
	if _active_handler != null and _active_handler.has_method("while_held") and not _inv_open and not _note_open:
		_active_handler.while_held(self, delta)


# ══ CREATIVE-MODE CAMERA + CONTROLS ═══════════════════════════════════════════════════════════════════
#
# DATA-DRIVEN ACTION MAP (coordinator control-extensibility ask 2026-07-05): the always-on key bindings
# are a DICTIONARY (keycode -> a zero-arg Callable). Adding a Minecraft-equivalent control is a ONE-LINE
# entry here — the dispatch loop below never changes. This is the plug point for the extra controls Liam
# picks (full-inventory E is already here; creative flight / sprint / jump / sneak, when chosen, each add
# ONE row). Kept separate from the mouse/number/wheel handling (those are MC-fixed).
var _key_actions: Dictionary = {}                            # keycode:int -> Callable (built in _build_action_map)

func _build_action_map() -> void:
	_key_actions = {
		KEY_E:            func(_ev): _toggle_inventory(),                       # full creative inventory / picker
		KEY_Q:            func(_ev): _drop_held(),                             # MC drop: empty the held slot (item disappears)
		KEY_ESCAPE:       func(_ev): Input.mouse_mode = Input.MOUSE_MODE_VISIBLE,
		KEY_BACKSLASH:    func(_ev): _toggle_debug_verbs(),                    # superseded verb layer toggle
		KEY_F5:           func(_ev): _save_world(),
		KEY_BRACKETLEFT:  func(_ev): _cycle_world(-1),
		KEY_BRACKETRIGHT: func(_ev): _cycle_world(1),
		KEY_F1:           func(_ev): _open_feedback(),                         # in-scene feedback (overarching ask)
		# --- Liam's extra MC-equivalent controls fold in here as ONE line each when he picks them. ---
		# e.g. creative flight toggle, sprint hold, jump, sneak — one KEY_* -> Callable row apiece.
	}


func _unhandled_input(event: InputEvent) -> void:
	if _headless:
		return
	# During a --shot proof run, ignore ALL player input: the window can open under the pointer and a
	# stray click leaks in as a placement, making the proof nondeterministic (observed live: 41 blocks
	# rendered from a 40-block params file; sandbox-live-verify pass, 2026-07-02).
	if _did_shot:
		return
	# While the note editor is open, keys belong to the LineEdit; only ESC (cancel) is handled here.
	if _note_open:
		if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
			_close_note(false)
		return
	# Mouse-look (only while the pointer is captured and the inventory is closed).
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sens
		_pitch = clampf(_pitch - event.relative.y * mouse_sens, -1.5, 1.5)
		_apply_camera_rotation()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		# The behavior panel owns the number keys while open (1..5 toggle, B/ESC close).
		if _behavior_open:
			if event.keycode >= KEY_1 and event.keycode <= KEY_5:
				_toggle_behavior_by_index(event.keycode - KEY_1)
				return
			if event.keycode == KEY_B or event.keycode == KEY_ESCAPE:
				_toggle_behavior_panel()
				return
			return
		# ALWAYS-ON keys via the DATA-DRIVEN action map (one dictionary row per binding — see _build_action_map).
		if _key_actions.has(event.keycode):
			(_key_actions[event.keycode] as Callable).call(event)
			return
		# DEBUG VERB LAYER (superseded default, gated behind BACKSLASH; append-only supersession).
		# MC controls (mouse) are the default; these fire only when the debug layer is toggled on.
		if _debug_verbs:
			match event.keycode:
				KEY_F:
					_toggle_select()
					return
				KEY_G:
					_toggle_grab()
					return
				KEY_R:
					_rotate_selected(-15.0 if event.shift_pressed else 15.0)
					return
				KEY_EQUAL, KEY_KP_ADD:
					_scale_selected(1.1)
					return
				KEY_MINUS, KEY_KP_SUBTRACT:
					_scale_selected(1.0 / 1.1)
					return
				KEY_X:
					_delete_selected()
					return
				KEY_B:
					_toggle_behavior_panel()
					return
				KEY_N:
					_open_note()
					return
		# Number keys 1..9 select the hotbar slot (MC parity).
		if event.keycode >= KEY_1 and event.keycode <= KEY_9:
			_select_slot(event.keycode - KEY_1)
			return
	if event is InputEventMouseButton and event.pressed:
		if _inv_open:
			return
		# Wheel = hotbar select — always active (capture-independent, MC parity).
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_select_slot(wrapi(active_slot - 1, 0, 9))
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_select_slot(wrapi(active_slot + 1, 0, 9))
			return
		# Recapture-after-ESC gates the ACTION buttons only: the first click after releasing the pointer
		# re-captures it rather than placing/destroying (so a click to refocus the window doesn't build).
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_click_primary()          # MC DESTROY (empty hand) / tool primary
			MOUSE_BUTTON_RIGHT:
				_click_secondary()        # MC PLACE (empty hand) / tool secondary
			MOUSE_BUTTON_MIDDLE:
				_click_middle()           # MC PICK (empty hand) / tool middle


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

## Returns { hit:bool, cell:Vector3i (the block hit), place:Vector3i (empty cell to place into), t:float }.
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
			return { "hit": true, "cell": cell, "place": prev_cell, "t": t }
		prev_cell = cell
		t += step
	# No block hit: aim at a point half the reach out; place on that cell (its own coord), snapped.
	var far := origin + fwd * (REACH * grid_size * 0.5)
	return { "hit": false, "cell": _world_to_cell(far), "place": _world_to_cell(far), "t": REACH * grid_size * 0.5 }


# ══ FREE-PLACEMENT RAYCAST (Liam correction 2026-07-05) ═══════════════════════════════════════════════
# The FREE build ray: return the EXACT world hit point + surface normal under the crosshair (no grid snap),
# picking the nearest of { a placed object's surface, a voxel block face, the ground plane }. If nothing is
# within reach, fall back to a point `reach_distance` out along the look ray so you can start a build in the
# air. This is what makes "place items and assets anywhere" real — the held item spawns at `point`.
## Returns { hit:bool, point:Vector3, normal:Vector3, t:float }.
func _raycast_free() -> Dictionary:
	if _cam == null:
		return { "hit": false, "point": Vector3.ZERO, "normal": Vector3.UP, "t": reach_distance }
	var origin := _cam.global_position
	var dir := (-_cam.global_transform.basis.z).normalized()
	var reach := reach_distance
	# nearest placed OBJECT surface (its exact AABB entry point)
	var pick := _pick_object()
	var obj_t: float = pick["t"] if pick["id"] != "" else INF
	# nearest voxel BLOCK face
	var rc := _raycast_grid()
	var block_t: float = rc["t"] if rc["hit"] else INF
	# the ground plane (y = floor plate), so a first placement in empty space lands ON the floor
	var ground_t := INF
	if absf(dir.y) > 1e-5:
		var gy := -0.5 * grid_size
		var gt := (gy - origin.y) / dir.y
		if gt > 0.0:
			ground_t = gt
	var best_t: float = min(obj_t, min(block_t, ground_t))
	if best_t <= reach and best_t < INF:
		var point := origin + dir * best_t
		var normal := Vector3.UP
		if best_t == obj_t and objects.has(pick["id"]):
			var rec: Dictionary = objects[pick["id"]]
			var node = rec.get("node")
			if node != null and is_instance_valid(node):
				var world_aabb: AABB = (node as Node3D).global_transform * (rec["aabb"] as AABB)
				normal = _aabb_face_normal(world_aabb, point)
		elif best_t == block_t and rc["hit"]:
			normal = _cell_face_normal(_cell_to_world(rc["cell"]), point)
		else:
			normal = Vector3.UP                       # ground plane
		return { "hit": true, "point": point, "normal": normal, "t": best_t }
	# nothing within reach: aim into the air at `reach_distance`
	return { "hit": false, "point": origin + dir * reach, "normal": Vector3.UP, "t": reach }


## MC PLACE (empty-hand RIGHT click): place whatever the active hotbar entry is — a block OR an asset —
## FREELY at the exact aim point under the crosshair (no grid, Liam correction 2026-07-05). Both go into
## the free OBJECT layer so they carry an arbitrary position + orientation. (Tools act via the seam.)
func _place_active() -> void:
	if _hand_empty():
		return                                       # empty hand => nothing to place (MC default: RMB no-op)
	var pal_idx: int = hotbar[active_slot]
	var entry: Dictionary = palette[pal_idx]
	if Items.is_tool_entry(entry):
		return                                       # tools are not placed; they act on click
	var rc := _raycast_free()
	var pos: Vector3 = rc["point"]
	# Orient the placement to face back toward the camera (yaw from the look direction) — a sensible free
	# default; fine orientation comes later via the queued wand tool.
	var yaw := 0.0
	if _cam != null:
		var look := -_cam.global_transform.basis.z
		yaw = rad_to_deg(atan2(look.x, look.z))
	if String(entry.get("kind", "block")) == "asset":
		_place_object(String(entry["asset_id"]), pos, yaw, 1.0, [], "", pal_idx)
	else:
		_place_block_free(pal_idx, pos, yaw)


## Free-place a primitive BLOCK as an object (a MeshInstance3D built from the palette shape) at an
## arbitrary point + yaw. Mirrors _place_object but the body is a primitive mesh, not a GLB.
func _place_block_free(pal_idx: int, pos: Vector3, yaw_deg := 0.0, forced_id := "") -> String:
	if pal_idx < 0 or pal_idx >= palette.size():
		return ""
	var entry: Dictionary = palette[pal_idx]
	if String(entry.get("kind", "block")) != "block":
		return ""
	var id := forced_id
	if id == "":
		_obj_seq += 1
		id = "obj_%d" % _obj_seq
	else:
		_obj_seq = maxi(_obj_seq, int(id.trim_prefix("obj_")))
	var node := Node3D.new()
	node.name = id
	_objects_root.add_child(node)
	var record := {
		"id": id, "block": String(entry["name"]), "pal_idx": pal_idx,
		"base_pos": pos, "yaw_deg": yaw_deg, "scale": 1.0,
		"behaviors": [], "node": node, "loaded": true,
		"aabb": AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE),
		"material": (entry.get("material", {}) as Dictionary).duplicate(true),
	}
	objects[id] = record
	_attach_block_body(record)
	Behaviors.tick(record, node, { "t": _time, "delta": 0.0 })
	return id


## Build the primitive-mesh body for a free-placed block object (uses the same renderer primitive vocab
## + the same material seam as the voxel path, so free blocks are texturable identically later).
func _attach_block_body(record: Dictionary) -> void:
	var node: Node3D = record["node"]
	var old: Node = node.get_node_or_null("body")
	if old != null:
		old.name = "body_old"
		old.queue_free()
	var pal_idx: int = int(record.get("pal_idx", -1))
	if pal_idx < 0 or pal_idx >= palette.size():
		return
	var entry: Dictionary = palette[pal_idx]
	var mi := MeshInstance3D.new()
	mi.name = "body"
	mi.mesh = GodotSceneRenderer._primitive_mesh(String(entry["shape"]), entry.get("params", {}))
	_apply_material(mi, record.get("material", entry.get("material", {})))
	node.add_child(mi)
	record["aabb"] = _combined_aabb(node)


## MC DESTROY (empty-hand LEFT click): remove the placed object OR the voxel block under the crosshair —
## whichever the ray reaches first. Free-placed blocks/assets ARE objects, so they go through _delete_object.
func _remove_target() -> void:
	var rc := _raycast_grid()
	var block_t: float = rc["t"] if rc["hit"] else INF
	var pick := _pick_object()
	if pick["id"] != "" and pick["t"] < block_t:
		_delete_object(String(pick["id"]))
		return
	if rc["hit"]:
		_erase_block(rc["cell"])


# ══ HELD-ITEM SEAM: click dispatch (Liam spec 2026-07-03) ═════════════════════════════════════════════
# Every click asks the ACTIVE HELD ITEM what to do. Empty hand => the Minecraft defaults; a TOOL item
# (the sticky note today, the wand later) overrides. The controller never hard-codes per-tool behavior —
# the tool's handler does, via the small documented API below. See runtime/sandbox_items.gd.

## LEFT click. Empty hand => MC DESTROY. Tool => its primary().
func _click_primary() -> void:
	if _active_handler != null and _active_handler.has_method("primary"):
		_active_handler.primary(self)
		return
	_remove_target()

## RIGHT click. Empty hand => MC PLACE. Tool => its secondary().
func _click_secondary() -> void:
	if _active_handler != null and _active_handler.has_method("secondary"):
		_active_handler.secondary(self)
		return
	# Empty hand or a tool held => nothing is "placed" (MC: RMB no-op); only blocks/assets place.
	if _hand_empty() or Items.is_tool_entry(_active_entry()):
		return
	_place_active()

## MIDDLE click. Empty hand OR a tool that does not override middle => MC PICK-BLOCK.
func _click_middle() -> void:
	if _active_handler != null and _active_handler.has_method("middle"):
		_active_handler.middle(self)
		return
	_pick_into_hand()

## MC pick-block: the thing you are looking at (a placed asset object first, else a block) becomes
## the ACTIVE hotbar entry. If it is not already in the hotbar, it replaces the active slot.
func _pick_into_hand() -> void:
	var rc := _raycast_grid()
	var block_t: float = rc["t"] if rc["hit"] else INF
	var pick := _pick_object()
	# Object under the crosshair (closer than any block) => pick its palette entry (asset OR free block).
	if pick["id"] != "" and pick["t"] < block_t and objects.has(pick["id"]):
		var orec: Dictionary = objects[pick["id"]]
		# A free block object carries its palette index directly; an asset object resolves by asset id.
		var pi := int(orec.get("pal_idx", -1))
		if pi < 0 or pi >= palette.size():
			pi = _palette_index_for_asset(String(orec.get("asset", ""))) if orec.has("asset") else _palette_index(String(orec.get("block", "")))
		if pi >= 0:
			hotbar[active_slot] = pi
			_after_hotbar_change()
			_flash_status("picked %s: %s" % ["block" if orec.has("block") else "asset", String(palette[pi].get("name", "?"))])
		return
	# Else a block => pick its palette type.
	if rc["hit"] and world.has(rc["cell"]):
		var type_name := String((world[rc["cell"]] as Dictionary)["type"])
		var bi := _palette_index(type_name)
		if bi >= 0:
			hotbar[active_slot] = bi
			_after_hotbar_change()
			_flash_status("picked block: %s" % type_name)

func _palette_index_for_asset(asset_id: String) -> int:
	for i in palette.size():
		var e: Dictionary = palette[i]
		if String(e.get("kind", "block")) == "asset" and String(e.get("asset_id", "")) == asset_id:
			return i
	return -1

## The palette entry the active hotbar slot holds — {} for an EMPTY HAND (holding nothing).
func _active_entry() -> Dictionary:
	var pi: int = hotbar[active_slot] if active_slot >= 0 and active_slot < hotbar.size() else EMPTY_HAND
	if pi == EMPTY_HAND or pi < 0 or pi >= palette.size():
		return {}
	return palette[pi]

## Is the active hotbar slot an EMPTY HAND (holding nothing)?
func _hand_empty() -> bool:
	return active_slot < 0 or active_slot >= hotbar.size() or int(hotbar[active_slot]) == EMPTY_HAND


## Human label for an object record — its asset id (asset objects) or its block name (free blocks).
func _obj_label(rec: Dictionary) -> String:
	if rec.has("asset"):
		return String(rec["asset"])
	if rec.has("block"):
		return String(rec["block"])
	return "?"

func _after_hotbar_change() -> void:
	_refresh_held_item()
	_rebuild_hotbar_ui()
	_refresh_status()
	_update_preview_mesh()


func _toggle_debug_verbs() -> void:
	_debug_verbs = not _debug_verbs
	_flash_status("debug verb layer %s (F/G/R/+-/X/B/N)" % ("ON" if _debug_verbs else "OFF"))


# ══ HELD-ITEM REFRESH: build/select the handler for the active hotbar entry ════════════════════════════
# Called whenever the active slot or its content changes. Empty hand / block / asset => no handler (MC
# defaults). A tool => its (reused) handler; on_select / on_deselect fire so a tool can set up/tear down
# its preview (the sticky-note orb).
func _refresh_held_item() -> void:
	var prev = _active_handler
	var entry: Dictionary = _active_entry()        # {} for an EMPTY HAND (no handler => MC defaults)
	var next = null
	if Items.is_tool_entry(entry):
		var slot_idx: int = hotbar[active_slot]
		if not _handlers.has(slot_idx):
			_handlers[slot_idx] = Items.make_handler(entry)
		next = _handlers[slot_idx]
	if next == prev:
		return
	if prev != null and prev.has_method("on_deselect"):
		prev.on_deselect(self)
	_active_handler = next
	if next != null and next.has_method("on_select"):
		next.on_select(self)


# ══ STICKY-NOTE CONTROLLER API (the surface the sticky_note handler calls) ═════════════════════════════
# The handler stays persistence-/scene-agnostic; the controller owns the world, the objects, the render
# roots, and the save paths. These methods are that documented surface.

## Raycast the crosshair to the EXACT surface point (spec: "sticks at the exact point I am looking at").
## Returns { hit, point:Vector3 (world), normal:Vector3 (world), target:{kind, id?|cell?} }. Picks the
## nearest of: a placed object (its exact mesh surface) OR a block cell face.
func surface_pick() -> Dictionary:
	if _cam == null:
		return { "hit": false }
	var origin := _cam.global_position
	var dir := (-_cam.global_transform.basis.z).normalized()
	# 1) placed objects: exact triangle-less approximation via the object AABB entry point + face.
	var pick := _pick_object()
	var obj_t: float = pick["t"] if pick["id"] != "" else INF
	# 2) blocks: step to the first filled cell, hit point on its face.
	var rc := _raycast_grid()
	var block_t: float = rc["t"] if rc["hit"] else INF
	if obj_t < block_t and objects.has(pick["id"]):
		var rec: Dictionary = objects[pick["id"]]
		var node = rec.get("node")
		if node != null and is_instance_valid(node):
			var world_aabb: AABB = (node as Node3D).global_transform * (rec["aabb"] as AABB)
			var point := origin + dir * obj_t
			var normal := _aabb_face_normal(world_aabb, point)
			return { "hit": true, "point": point, "normal": normal,
				"target": { "kind": "object", "id": String(pick["id"]) } }
	if rc["hit"] and world.has(rc["cell"]):
		var point2 := origin + dir * block_t
		var cell_centre := _cell_to_world(rc["cell"])
		var normal2 := _cell_face_normal(cell_centre, point2)
		return { "hit": true, "point": point2, "normal": normal2,
			"target": { "kind": "block", "cell": [rc["cell"].x, rc["cell"].y, rc["cell"].z] } }
	return { "hit": false }

## Outward normal of the AABB face nearest to a surface point.
func _aabb_face_normal(aabb: AABB, point: Vector3) -> Vector3:
	var c := aabb.get_center()
	var d := point - c
	var e := aabb.size * 0.5
	# distance from each face (positive outside); largest ratio => the face we are on.
	var rx := absf(d.x) / maxf(e.x, 1e-4)
	var ry := absf(d.y) / maxf(e.y, 1e-4)
	var rz := absf(d.z) / maxf(e.z, 1e-4)
	if rx >= ry and rx >= rz:
		return Vector3(signf(d.x), 0, 0)
	elif ry >= rx and ry >= rz:
		return Vector3(0, signf(d.y), 0)
	return Vector3(0, 0, signf(d.z))

func _cell_face_normal(cell_centre: Vector3, point: Vector3) -> Vector3:
	var d := point - cell_centre
	var ax := absf(d.x); var ay := absf(d.y); var az := absf(d.z)
	if ax >= ay and ax >= az:
		return Vector3(signf(d.x), 0, 0)
	elif ay >= ax and ay >= az:
		return Vector3(0, signf(d.y), 0)
	return Vector3(0, 0, signf(d.z))

## Stick a note at a surface hit. Stores the anchor in the TARGET's LOCAL space (+ face normal) so it
## rides the target if it moves, renders the flat orange square, and returns the note id ("" on failure).
func stick_note(hit: Dictionary) -> String:
	if not bool(hit.get("hit", false)):
		return ""
	var target: Dictionary = hit.get("target", {})
	var world_point: Vector3 = hit["point"]
	var world_normal: Vector3 = hit.get("normal", Vector3.UP)
	var local_point := world_point
	var local_normal := world_normal
	var xform := Transform3D.IDENTITY
	if String(target.get("kind", "")) == "object" and objects.has(String(target.get("id", ""))):
		var rec: Dictionary = objects[String(target["id"])]
		var node = rec.get("node")
		if node != null and is_instance_valid(node):
			xform = (node as Node3D).global_transform
			local_point = xform.affine_inverse() * world_point
			local_normal = xform.affine_inverse().basis * world_normal
	elif String(target.get("kind", "")) == "block":
		var ca = target.get("cell", [0, 0, 0])
		var cell := Vector3i(int(ca[0]), int(ca[1]), int(ca[2]))
		xform = Transform3D(Basis.IDENTITY, _cell_to_world(cell))
		local_point = xform.affine_inverse() * world_point
		local_normal = world_normal
	_note_seq += 1
	var note_id := "note_%d" % _note_seq
	var record := {
		"id": note_id,
		"target": target,
		"local_point": [local_point.x, local_point.y, local_point.z],
		"local_normal": [local_normal.x, local_normal.y, local_normal.z],
		"text": "",
		"held_item": Items.TOOL_STICKY_NOTE,   # provenance: which tool stuck it
		"node": null,
	}
	_notes[note_id] = record
	_realize_note(record)
	return note_id

## Build (or refresh) the flat orange square render node for a note and parent it under the notes root.
func _realize_note(record: Dictionary) -> void:
	if _headless:
		return
	if _notes_root == null:
		_notes_root = Node3D.new()
		_notes_root.name = "Notes"
		add_child(_notes_root)
	var mi = record.get("node")
	if mi == null or not is_instance_valid(mi):
		mi = StickyNote.make_note_mesh()
		_notes_root.add_child(mi)
		record["node"] = mi
	_position_note(record)

## Place a note's square at target.global_transform * local_anchor, oriented to the face normal.
func _position_note(record: Dictionary) -> void:
	var mi = record.get("node")
	if mi == null or not is_instance_valid(mi):
		return
	var lp: Array = record["local_point"]
	var ln: Array = record["local_normal"]
	var local_point := Vector3(lp[0], lp[1], lp[2])
	var local_normal := Vector3(ln[0], ln[1], ln[2])
	var xform := _note_target_xform(record)
	var world_point := xform * local_point
	var world_normal := (xform.basis * local_normal).normalized()
	if world_normal.length() < 0.01:
		world_normal = Vector3.UP
	# Sit the square just off the surface, facing outward along the normal.
	(mi as Node3D).global_position = world_point + world_normal * 0.02
	var up := Vector3.UP if absf(world_normal.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	(mi as Node3D).look_at(world_point + world_normal * 0.02 + world_normal, up)

## The current world transform of a note's target (object => its live node; block => its fixed cell).
func _note_target_xform(record: Dictionary) -> Transform3D:
	var target: Dictionary = record.get("target", {})
	if String(target.get("kind", "")) == "object" and objects.has(String(target.get("id", ""))):
		var rec: Dictionary = objects[String(target["id"])]
		var node = rec.get("node")
		if node != null and is_instance_valid(node):
			return (node as Node3D).global_transform
	if String(target.get("kind", "")) == "block":
		var ca = target.get("cell", [0, 0, 0])
		return Transform3D(Basis.IDENTITY, _cell_to_world(Vector3i(int(ca[0]), int(ca[1]), int(ca[2]))))
	return Transform3D.IDENTITY

## Re-place every note each frame so notes ride their (possibly moving/rotating) targets.
func _tick_notes() -> void:
	if _headless:
		return
	for id in _notes:
		_position_note(_notes[id])

## Open the note text editor bound to a specific note id (reuses the N-note LineEdit panel).
func open_note_editor(note_id: String) -> void:
	if _headless or _note_panel == null or not _notes.has(note_id):
		return
	_editing_note_id = note_id
	_note_open = true
	_note_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _note_target_label != null:
		var rec: Dictionary = _notes[note_id]
		_note_target_label.text = "Sticky note on: %s" % String((rec.get("target", {}) as Dictionary).get("kind", "surface"))
	_note_edit.text = String((_notes[note_id] as Dictionary).get("text", ""))
	_note_edit.grab_focus()

## Handlers call this to surface a one-line hint (delegates to the existing flash).
func flash(msg: String) -> void:
	_flash_status(msg)

## Handlers call this to parent a 3D preview node (the sticky-note orb) under a HUD-3D root.
func add_preview_child(n: Node3D) -> void:
	if _preview3d_root == null:
		_preview3d_root = Node3D.new()
		_preview3d_root.name = "HeldToolPreview"
		add_child(_preview3d_root)
	_preview3d_root.add_child(n)


## Place a palette block at a grid cell. This is the ONE write path into the world Dictionary + the scene:
## it records the block as DATA (shape/params/material seam) and instances exactly one MeshInstance3D.
## `material_override` (optional) is the live-texturing hook: keys in it overlay the palette default, so a
## seeded/params block can carry a file or PROCEDURAL texture descriptor (see _apply_material).
func _set_block(cell: Vector3i, pal_idx: int, material_override: Dictionary = {}) -> void:
	if pal_idx < 0 or pal_idx >= palette.size():
		return
	if String((palette[pal_idx] as Dictionary).get("kind", "block")) != "block":
		return
	if world.has(cell):
		_erase_block(cell)
	var entry: Dictionary = palette[pal_idx]
	var mi := MeshInstance3D.new()
	mi.mesh = GodotSceneRenderer._primitive_mesh(String(entry["shape"]), entry.get("params", {}))
	mi.position = _cell_to_world(cell)
	_blocks_root.add_child(mi)
	# BlockRecord — the per-block DATA. `material` is the LIVE-TEXTURING SEAM (see _apply_material):
	# it starts as the palette's plain {albedo:[r,g,b]} (untextured); the live-texturing module
	# (TextureApply node ops / params material entries) overlays richer descriptor keys here and the
	# block re-skins with ZERO placement-code change.
	var material: Dictionary = entry.get("material", {}).duplicate(true)
	for k in material_override:
		material[k] = material_override[k]
	var record := {
		"type": String(entry["name"]),
		"shape": String(entry["shape"]),
		"params": entry.get("params", {}).duplicate(true),
		"material": material,   # ← the seam
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
		# Detach from the tree IMMEDIATELY (so the scene reflects the removal this frame, not after the
		# deferred free settles — matters for place-then-replace in one input), then free.
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
	world.erase(cell)


# ── THE LIVE-TEXTURING SEAM ────────────────────────────────────────────────────────────────────────
# Every block gets its material HERE, from the block record's `material` DATA slot. Today the descriptor is
# minimal ({albedo:[r,g,b]} → a plain untextured StandardMaterial3D), so blocks start UNTEXTURED exactly as
# Liam asked. The seam is intentionally the SINGLE choke point: a later node-based live-texturing system
# only has to write a richer `material` descriptor (albedo_texture / roughness / normal_map / a node-graph
# handle) into the record and call _apply_material — the placement/removal/world code above never changes.
func _apply_material(mi: MeshInstance3D, material_desc: Dictionary) -> void:
	var mat := StandardMaterial3D.new()
	var albedo = material_desc.get("albedo", [0.75, 0.75, 0.78])
	if typeof(albedo) == TYPE_ARRAY and albedo.size() >= 3:
		mat.albedo_color = Color(albedo[0], albedo[1], albedo[2])
	# --- SEAM: the live-texturing module fills these from the `material` descriptor ---
	# File texture (a path) wins; else a PROCEDURAL descriptor is synthesized by the renderer
	# delegate (renderers/texture_synth.gd) — the data the TextureApply node emits. Deterministic,
	# so the same descriptor always re-skins a block identically on hotload.
	var tex_path = material_desc.get("albedo_texture", "")
	var procedural = material_desc.get("procedural", {})
	if typeof(tex_path) == TYPE_STRING and tex_path != "" and ResourceLoader.exists(tex_path):
		mat.albedo_texture = load(tex_path)
	elif typeof(procedural) == TYPE_DICTIONARY and not (procedural as Dictionary).is_empty():
		mat.albedo_texture = TextureSynth.synthesize(procedural)
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

## Where an ASSET placed into a cell stands: on the cell's floor plane (base-origin models sit on
## top of the block below / the ground plate, instead of floating at the cell centre).
func _object_pos_for_cell(c: Vector3i) -> Vector3:
	return _cell_to_world(c) + Vector3(0.0, -0.5 * grid_size, 0.0)


# ══ THE OBJECT LAYER — any manifest asset, placed / rearranged / behaved / noted ══════════════════════
# Each placed object is DATA: {id, asset, base_pos, yaw_deg, scale, behaviors, node, loaded, aabb}.
# The node is a container Node3D; its "body" child is a placeholder box until the (lazily loaded)
# asset instance swaps in — placement never waits on IO.

func _place_object(asset_id: String, pos: Vector3, yaw_deg := 0.0, scale := 1.0,
		behaviors: Array = [], forced_id := "", pal_idx := -1) -> String:
	if assets == null or not assets.has_asset(asset_id):
		return ""
	var id := forced_id
	if id == "":
		_obj_seq += 1
		id = "obj_%d" % _obj_seq
	else:
		var n := int(id.trim_prefix("obj_"))
		_obj_seq = maxi(_obj_seq, n)
	var node := Node3D.new()
	node.name = id
	_objects_root.add_child(node)
	var record := {
		"id": id, "asset": asset_id, "pal_idx": pal_idx,
		"base_pos": pos, "yaw_deg": yaw_deg, "scale": scale,
		"behaviors": behaviors.duplicate(true),
		"node": node, "loaded": false,
		"aabb": AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.0, 1.0)),
	}
	objects[id] = record
	_attach_body(record)
	Behaviors.tick(record, node, { "t": _time, "delta": 0.0 })
	return id


## Placeholder-or-instance: swap in the real asset when the library has it, else a translucent box
## (and request the load — `asset_ready` will swap it the moment it lands).
func _attach_body(record: Dictionary) -> void:
	# A free-placed primitive BLOCK object builds its body from the primitive vocab, not a GLB.
	if record.has("block") and not record.has("asset"):
		_attach_block_body(record)
		return
	var node: Node3D = record["node"]
	var old: Node = node.get_node_or_null("body")
	if old != null:
		old.name = "body_old"
		old.queue_free()
	var asset_id := String(record["asset"])
	var inst: Node3D = assets.instantiate(asset_id)
	if inst != null:
		inst.name = "body"
		node.add_child(inst)
		record["loaded"] = true
		record["aabb"] = _combined_aabb(inst)
	else:
		var ph := MeshInstance3D.new()
		ph.name = "body"
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * 0.9
		ph.mesh = bm
		ph.position = Vector3(0.0, 0.45, 0.0)
		var m := StandardMaterial3D.new()
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.6, 0.7, 0.9, 0.45)
		ph.material_override = m
		node.add_child(ph)
		record["loaded"] = false
		record["aabb"] = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.0, 1.0))
		assets.request(asset_id)


func _on_asset_ready(asset_id: String) -> void:
	for id in objects:
		var rec: Dictionary = objects[id]
		if String(rec.get("asset", "")) == asset_id and not bool(rec.get("loaded", false)):
			_attach_body(rec)


func _delete_object(id: String) -> void:
	if not objects.has(id):
		return
	var rec: Dictionary = objects[id]
	var n = rec.get("node", null)
	if n != null and is_instance_valid(n):
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()
	objects.erase(id)
	if selected_id == id:
		selected_id = ""
		_grabbing = false
	_refresh_status()


func _clear_objects() -> void:
	for id in objects.keys():
		var rec: Dictionary = objects[id]
		var n = rec.get("node", null)
		if n != null and is_instance_valid(n):
			n.queue_free()
	objects.clear()
	selected_id = ""
	_grabbing = false


## Tick every object's behavior stack (also lands static objects on their base transform).
func _tick_objects(delta: float) -> void:
	var ctx := {
		"t": _time, "delta": delta,
		"player_pos": _cam.global_position if _cam != null else Vector3.INF,
	}
	for id in objects:
		var rec: Dictionary = objects[id]
		# While grabbed, the object follows the FREE build ray (no grid snap) instead of its behaviors.
		if _grabbing and id == selected_id and not _headless:
			var rc := _raycast_free()
			rec["base_pos"] = rc["point"]
		Behaviors.tick(rec, rec.get("node"), ctx)


# ── picking / selection / rearranging ─────────────────────────────────────────────────────────────────

## Nearest placed object along the camera ray (slab ray-vs-AABB in world space).
## Returns { id:String ("" = none), t:float }.
func _pick_object() -> Dictionary:
	if _cam == null:
		return { "id": "", "t": INF }
	var origin := _cam.global_position
	var dir := -_cam.global_transform.basis.z
	var best_id := ""
	var best_t := INF
	for id in objects:
		var rec: Dictionary = objects[id]
		var node = rec.get("node")
		if node == null or not is_instance_valid(node):
			continue
		var aabb: AABB = (node as Node3D).global_transform * (rec["aabb"] as AABB)
		var t := _ray_aabb(origin, dir, aabb.grow(0.05))
		if t >= 0.0 and t < best_t and t <= reach_distance:
			best_t = t
			best_id = id
	return { "id": best_id, "t": best_t }


## Slab-method ray/AABB intersection. Returns entry distance t (>=0) or -1.0 on miss.
func _ray_aabb(origin: Vector3, dir: Vector3, aabb: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	for axis in 3:
		var o := origin[axis]
		var d := dir[axis]
		var lo := aabb.position[axis]
		var hi := aabb.position[axis] + aabb.size[axis]
		if absf(d) < 1e-8:
			if o < lo or o > hi:
				return -1.0
		else:
			var t1 := (lo - o) / d
			var t2 := (hi - o) / d
			tmin = maxf(tmin, minf(t1, t2))
			tmax = minf(tmax, maxf(t1, t2))
			if tmin > tmax:
				return -1.0
	if tmax < 0.0:
		return -1.0
	return maxf(tmin, 0.0)


func _toggle_select() -> void:
	if _grabbing:
		return
	var pick := _pick_object()
	var id := String(pick["id"])
	selected_id = "" if (id == selected_id or id == "") else id
	_refresh_status()


func _toggle_grab() -> void:
	if selected_id == "" or not objects.has(selected_id):
		_grabbing = false
		return
	_grabbing = not _grabbing
	_refresh_status()


func _rotate_selected(deg: float) -> void:
	if selected_id == "" or not objects.has(selected_id):
		return
	var rec: Dictionary = objects[selected_id]
	rec["yaw_deg"] = fmod(float(rec["yaw_deg"]) + deg, 360.0)
	_refresh_status()


func _scale_selected(factor: float) -> void:
	if selected_id == "" or not objects.has(selected_id):
		return
	var rec: Dictionary = objects[selected_id]
	rec["scale"] = clampf(float(rec["scale"]) * factor, 0.1, 10.0)
	_refresh_status()


func _delete_selected() -> void:
	if selected_id != "":
		_delete_object(selected_id)


func _update_selection_marker() -> void:
	if _sel_marker == null:
		return
	if selected_id == "" or not objects.has(selected_id):
		_sel_marker.visible = false
		return
	var rec: Dictionary = objects[selected_id]
	var node = rec.get("node")
	if node == null or not is_instance_valid(node):
		_sel_marker.visible = false
		return
	var aabb: AABB = ((node as Node3D).global_transform * (rec["aabb"] as AABB)).grow(0.08)
	_sel_marker.visible = true
	_sel_marker.position = aabb.get_center()
	(_sel_marker.mesh as BoxMesh).size = aabb.size


# ══ CROSSHAIR TARGETING + OBJECT-TARGET OUTLINE (Liam correction / coordinator control #2) ═════════════
# What the crosshair currently points at (the nearest of a placed object or a voxel block within reach) —
# the thing LMB-destroy / MMB-pick will act on. Computed once per frame and outlined so the player can see
# exactly what a click hits. This is an OBJECT-target highlight (the actual object) — NOT the grid-cell
# placement preview Liam rejected. Placement stays free; only the destroy/pick TARGET is outlined.
func _update_target() -> void:
	if _cam == null:
		_target = { "kind": "" }
		return
	var rc := _raycast_grid()
	var block_t: float = rc["t"] if rc["hit"] else INF
	var pick := _pick_object()
	var obj_t: float = pick["t"] if pick["id"] != "" else INF
	if obj_t < block_t and obj_t <= reach_distance and objects.has(pick["id"]):
		_target = { "kind": "object", "id": String(pick["id"]) }
	elif rc["hit"] and block_t <= reach_distance and world.has(rc["cell"]):
		_target = { "kind": "block", "cell": rc["cell"] }
	else:
		_target = { "kind": "" }


func _update_target_outline() -> void:
	if _target_outline == null:
		return
	# Never outline while grabbing / inventory open / a --shot proof (keeps the proof + grab clean).
	if _grabbing or _inv_open or _did_shot or String(_target.get("kind", "")) == "":
		_target_outline.visible = false
		return
	var aabb := AABB()
	if String(_target["kind"]) == "object" and objects.has(String(_target["id"])):
		var rec: Dictionary = objects[String(_target["id"])]
		var node = rec.get("node")
		if node == null or not is_instance_valid(node):
			_target_outline.visible = false
			return
		aabb = ((node as Node3D).global_transform * (rec["aabb"] as AABB)).grow(0.03)
	elif String(_target["kind"]) == "block" and world.has(_target["cell"]):
		var c: Vector3i = _target["cell"]
		aabb = AABB(_cell_to_world(c) - Vector3.ONE * grid_size * 0.5, Vector3.ONE * grid_size).grow(0.03)
	else:
		_target_outline.visible = false
		return
	_target_outline.visible = true
	_target_outline.position = aabb.get_center()
	(_target_outline.mesh as BoxMesh).size = aabb.size


## Local-space combined AABB of every mesh under a node (relative to that node).
func _combined_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var found := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var n: Node = top[0]
		var xf: Transform3D = top[1]
		var here := xf
		if n is Node3D and n != root:
			here = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var a := here * (n as MeshInstance3D).mesh.get_aabb()
			merged = a if not found else merged.merge(a)
			found = true
		for c in n.get_children():
			stack.append([c, here])
	return merged if found else AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE)


# ── behaviors panel (B): toggle composable behaviors on the selection ─────────────────────────────────

func _toggle_behavior_panel() -> void:
	if _headless or _behavior_panel == null:
		return
	if not _behavior_open and (selected_id == "" or not objects.has(selected_id)):
		_flash_status("select an object first (F), then B for behaviors")
		return
	_behavior_open = not _behavior_open
	_behavior_panel.visible = _behavior_open
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if _behavior_open else Input.MOUSE_MODE_CAPTURED
	if _behavior_open:
		_refresh_behavior_list()


func _toggle_behavior_by_index(i: int) -> void:
	if selected_id == "" or not objects.has(selected_id):
		return
	var types: Array = Behaviors.TYPES
	if i < 0 or i >= types.size():
		return
	var rec: Dictionary = objects[selected_id]
	rec["behaviors"] = Behaviors.toggle(rec.get("behaviors", []), String(types[i]))
	_refresh_behavior_list()
	_refresh_status()


func _refresh_behavior_list() -> void:
	if _behavior_list == null or selected_id == "" or not objects.has(selected_id):
		return
	var rec: Dictionary = objects[selected_id]
	var lines := ["Behaviors on %s (%s):" % [selected_id, _obj_label(rec)], ""]
	var types: Array = Behaviors.TYPES
	for i in types.size():
		var t := String(types[i])
		var on := Behaviors.has_behavior(rec.get("behaviors", []), t)
		lines.append("  [%d] %s %s" % [i + 1, "[x]" if on else "[ ]", t])
	lines.append("")
	lines.append("1..5 toggle  ·  B close")
	_behavior_list.text = "\n".join(lines)


# ── IN-SCENE FEEDBACK (F1): leave feedback from inside the scene (overarching ask 2026-07-05) ──────────
# Liam (overarching): "the ability to leave feedback on pages and scenes from the aperture". F1 opens the
# text box; the line appends to the SAME notes.jsonl substrate as card + sticky-note feedback, keyed to the
# scene id "sandbox_creative" with kind:"scene_feedback" — so a note left in the scene is indistinguishable
# in the data contract from a card note (a Claude Code session reads them the same way). No shared code file.
func _open_feedback() -> void:
	if _headless or _note_panel == null:
		return
	_feedback_mode = true
	_note_open = true
	_note_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _note_target_label != null:
		_note_target_label.text = "Feedback on this scene (sandbox_creative)"
	if _note_edit != null:
		_note_edit.text = ""
		_note_edit.placeholder_text = "feedback on this scene…  (Enter saves · ESC cancels)"
		_note_edit.grab_focus()


## Append one IN-SCENE FEEDBACK line to notes.jsonl (same substrate as sticky notes + card feedback).
## Standalone so headless tests call it directly. Returns success.
func _write_feedback(text: String) -> bool:
	var pos := Vector3.ZERO
	if _cam != null:
		pos = _cam.global_position
	var entry := {
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"world": world_name,
		"world_version": store.latest_version(world_name) if store != null else 0,
		"object_id": "",
		"asset_id": "",
		"position": [pos.x, pos.y, pos.z],
		"note": text,
		# --- feedback provenance (additive; keyed to the scene id, same as an Aperture card note) ---
		"kind": "scene_feedback",
		"scene_id": "sandbox_creative",
	}
	return _append_note_line(entry)


# ── notes on things (N): the Claude Code handoff channel ──────────────────────────────────────────────
# A note lands as one JSONL line in notes_path with everything a Claude Code session needs to act on it
# cold: UTC timestamp, world + version, object id + asset id (or a bare location), world position, text.

func _open_note() -> void:
	if _headless or _note_panel == null:
		return
	_note_open = true
	_note_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _note_target_label != null:
		_note_target_label.text = "Note on: %s" % _note_target_desc()
	_note_edit.text = ""
	_note_edit.grab_focus()


func _note_target_desc() -> String:
	if selected_id != "" and objects.has(selected_id):
		return "%s (%s)" % [selected_id, _obj_label(objects[selected_id])]
	var rc := _raycast_grid()
	return "location %s" % str(_cell_to_world(rc["place"] if not rc["hit"] else rc["cell"]))


func _close_note(save: bool) -> void:
	_note_open = false
	if _note_panel != null:
		_note_panel.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	# IN-SCENE FEEDBACK path (F1): the editor was capturing scene feedback, not a stuck note.
	if _feedback_mode:
		_feedback_mode = false
		if save:
			var fb := _note_edit.text.strip_edges() if _note_edit != null else ""
			if fb != "":
				if _write_feedback(fb):
					_flash_status("scene feedback saved -> %s" % notes_path)
				else:
					_flash_status("FEEDBACK FAILED to write %s" % notes_path)
		if _note_edit != null:
			_note_edit.placeholder_text = "note for Claude Code…  (Enter saves · ESC cancels)"
		return
	var editing := _editing_note_id
	_editing_note_id = ""
	if not save:
		# Cancelled a fresh sticky note with no text yet => drop the empty note anchor.
		if editing != "" and _notes.has(editing) and String((_notes[editing] as Dictionary).get("text", "")) == "":
			_remove_note(editing)
		return
	var text := _note_edit.text.strip_edges() if _note_edit != null else ""
	if text == "":
		if editing != "" and _notes.has(editing):
			_remove_note(editing)   # empty text => discard the sticky note
		return
	# STICKY-NOTE path: text belongs to a stuck note anchor (LEFT-click-with-sticky-note-held).
	if editing != "" and _notes.has(editing):
		(_notes[editing] as Dictionary)["text"] = text
		if _write_sticky_note(_notes[editing]):
			_flash_status("sticky note saved -> %s" % notes_path)
		else:
			_flash_status("NOTE FAILED to write %s" % notes_path)
		return
	# LEGACY N-note path (debug verb layer): a note on the selection or the crosshair spot.
	if _write_note(text):
		_flash_status("note saved -> %s" % notes_path)
	else:
		_flash_status("NOTE FAILED to write %s" % notes_path)


## Remove a sticky note (its render node + record). Used when a fresh note is cancelled/left empty.
func _remove_note(note_id: String) -> void:
	if not _notes.has(note_id):
		return
	var rec: Dictionary = _notes[note_id]
	var n = rec.get("node")
	if n != null and is_instance_valid(n):
		n.queue_free()
	_notes.erase(note_id)


## Append one STICKY-NOTE line to notes.jsonl. ADDITIVELY extends the RE #145 row schema: every prior
## field is preserved (ts/world/world_version/object_id/asset_id/position/note) and the sticky-note
## anchor (local_point, local_normal, target) + held-item provenance are ADDED. A Claude Code session
## reading the file cold gets both the world position (for old readers) and the exact anchor.
func _write_sticky_note(record: Dictionary) -> bool:
	var target: Dictionary = record.get("target", {})
	var obj_id := ""
	var asset_id := ""
	if String(target.get("kind", "")) == "object":
		obj_id = String(target.get("id", ""))
		if objects.has(obj_id):
			asset_id = String((objects[obj_id] as Dictionary).get("asset", ""))
	# World position of the anchor now (so the legacy `position` field stays meaningful).
	var xform := _note_target_xform(record)
	var lp: Array = record["local_point"]
	var world_point: Vector3 = xform * Vector3(lp[0], lp[1], lp[2])
	var entry := {
		# --- existing RE #145 schema (unchanged) ---
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"world": world_name,
		"world_version": store.latest_version(world_name) if store != null else 0,
		"object_id": obj_id,
		"asset_id": asset_id,
		"position": [world_point.x, world_point.y, world_point.z],
		"note": String(record.get("text", "")),
		# --- ADDED (additive; old readers ignore unknown keys) ---
		"note_id": String(record.get("id", "")),
		"kind": "sticky_note",
		"held_item": String(record.get("held_item", Items.TOOL_STICKY_NOTE)),
		"anchor_target": target,
		"local_point": record["local_point"],
		"local_normal": record["local_normal"],
	}
	return _append_note_line(entry)


## Shared JSONL append (both note paths use it). Returns success.
func _append_note_line(entry: Dictionary) -> bool:
	var dir := notes_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f: FileAccess
	if FileAccess.file_exists(notes_path):
		f = FileAccess.open(notes_path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		f = FileAccess.open(notes_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_line(JSON.stringify(entry))
	f.close()
	return true


## Append one note line (JSONL). Standalone so headless tests call it directly. Returns success.
func _write_note(text: String, obj_id_override := "", pos_override = null) -> bool:
	var obj_id := obj_id_override if obj_id_override != "" else selected_id
	var asset_id := ""
	var pos: Vector3
	if obj_id != "" and objects.has(obj_id):
		var rec: Dictionary = objects[obj_id]
		asset_id = String(rec.get("asset", ""))
		pos = rec["base_pos"]
	else:
		obj_id = ""
		if pos_override != null:
			pos = pos_override
		elif not _headless and _cam != null:
			var rc := _raycast_grid()
			pos = _cell_to_world(rc["place"] if not rc["hit"] else rc["cell"])
		else:
			pos = Vector3.ZERO
	var entry := {
		"ts": Time.get_datetime_string_from_system(true) + "Z",
		"world": world_name,
		"world_version": store.latest_version(world_name) if store != null else 0,
		"object_id": obj_id,
		"asset_id": asset_id,
		"position": [pos.x, pos.y, pos.z],
		"note": text,
	}
	return _append_note_line(entry)


# ══ WORLDS: load / save (append-only) / switch (preload swap) ═════════════════════════════════════════

## Load the active world from the store (blocks + objects + preload set). False if absent.
func _load_active_world() -> bool:
	if store == null:
		return false
	var data: Dictionary = store.load_world(world_name)
	if data.is_empty():
		return false
	_apply_world_data(data)
	_world_watch_path = store.latest_path(world_name)
	_world_watch_hash = _file_hash(_world_watch_path)
	return true


func _apply_world_data(data: Dictionary) -> void:
	# blocks (clear + re-seed: the file is the source of truth for the seeded build)
	_seed_world({ "blocks": data.get("blocks", []), "material_ops": data.get("material_ops", []) }, true)
	# objects: preload the world's asset set (background), evict what this world does not use,
	# then place records (placeholders swap in as loads land) — the scene-to-scene swap path.
	_clear_objects()
	var pre: Array = WorldStoreScript.preload_set_of(data)
	if assets != null:
		assets.evict_except(pre)
		assets.preload_set(pre)
	for o in data.get("objects", []):
		if typeof(o) != TYPE_DICTIONARY:
			continue
		var p = o.get("position", [0, 0, 0])
		if typeof(p) != TYPE_ARRAY or (p as Array).size() < 3:
			continue
		var pos := Vector3(p[0], p[1], p[2])
		var yaw := float(o.get("yaw_deg", 0.0))
		# A free-placed primitive BLOCK object (Liam 2026-07-05) carries a `block` name, not an `asset`.
		if o.has("block") and not o.has("asset"):
			var bpi := _palette_index(String(o["block"]))
			if bpi >= 0:
				_place_block_free(bpi, pos, yaw, String(o.get("id", "")))
			continue
		if not o.has("asset"):
			continue
		_place_object(String(o["asset"]), pos, yaw, float(o.get("scale", 1.0)),
			o.get("behaviors", []) if typeof(o.get("behaviors")) == TYPE_ARRAY else [],
			String(o.get("id", "")), _palette_index_for_asset(String(o["asset"])))
	# Sticky notes reload with the world (their anchors target block cells / object ids just placed).
	_clear_notes()
	for nd in data.get("notes", []):
		if typeof(nd) != TYPE_DICTIONARY:
			continue
		_load_note(nd)
	_refresh_status()


## Clear every stuck-note render node + record (a world switch / re-seed).
func _clear_notes() -> void:
	for id in _notes.keys():
		var rec: Dictionary = _notes[id]
		var n = rec.get("node")
		if n != null and is_instance_valid(n):
			n.queue_free()
	_notes.clear()


## Rebuild a note record from persisted data + realize its render node.
func _load_note(nd: Dictionary) -> void:
	var id := String(nd.get("id", ""))
	if id == "":
		_note_seq += 1
		id = "note_%d" % _note_seq
	else:
		var n := int(id.trim_prefix("note_"))
		_note_seq = maxi(_note_seq, n)
	var record := {
		"id": id,
		"target": (nd.get("target", {}) as Dictionary).duplicate(true),
		"local_point": (nd.get("local_point", [0, 0, 0]) as Array).duplicate(),
		"local_normal": (nd.get("local_normal", [0, 1, 0]) as Array).duplicate(),
		"text": String(nd.get("text", "")),
		"held_item": String(nd.get("held_item", "sticky_note")),
		"node": null,
	}
	_notes[id] = record
	_realize_note(record)


## Serialize the live world back to pure data (the exact file shape the store persists).
func _serialize_world() -> Dictionary:
	var blocks := []
	for cell in world:
		var rec: Dictionary = world[cell]
		blocks.append({
			"cell": [cell.x, cell.y, cell.z],
			"block": String(rec["type"]),
			"material": (rec.get("material", {}) as Dictionary).duplicate(true),
		})
	var objs := []
	for id in objects:
		var rec: Dictionary = objects[id]
		var bp: Vector3 = rec["base_pos"]
		var entry := {
			"id": id,
			"position": [bp.x, bp.y, bp.z],
			"yaw_deg": float(rec["yaw_deg"]),
			"scale": float(rec["scale"]),
			"behaviors": (rec.get("behaviors", []) as Array).duplicate(true),
		}
		# Free-placed primitive BLOCK objects persist a `block` name; asset objects persist an `asset` id.
		if rec.has("block") and not rec.has("asset"):
			entry["block"] = String(rec["block"])
		else:
			entry["asset"] = String(rec.get("asset", ""))
		objs.append(entry)
	# Sticky notes: persist so they reload WITH the world (spec: "into the world save so notes
	# reload with the world"). Each carries its anchor (target + local point/normal) + text.
	var notes := []
	for id in _notes:
		var nrec: Dictionary = _notes[id]
		notes.append({
			"id": String(nrec.get("id", id)),
			"target": (nrec.get("target", {}) as Dictionary).duplicate(true),
			"local_point": (nrec.get("local_point", [0, 0, 0]) as Array).duplicate(),
			"local_normal": (nrec.get("local_normal", [0, 1, 0]) as Array).duplicate(),
			"text": String(nrec.get("text", "")),
			"held_item": String(nrec.get("held_item", "sticky_note")),
		})
	return {
		"grid_size": grid_size,
		"blocks": blocks,
		"objects": objs,
		"notes": notes,
	}


## F5 — APPEND-ONLY save: version N+1 in the store; prior versions are never touched.
func _save_world() -> void:
	if store == null:
		return
	var v: int = store.save_version(world_name, _serialize_world())
	if v > 0:
		_world_watch_path = store.latest_path(world_name)
		_world_watch_hash = _file_hash(_world_watch_path)
		_flash_status("saved %s v%d (append-only)" % [world_name, v])
	else:
		_flash_status("SAVE FAILED for %s" % world_name)


## [ / ] — move scene to scene: the next world's preload set loads, the old one's assets evict.
func _cycle_world(dir: int) -> void:
	if store == null:
		return
	var names: Array = store.list_worlds()
	if names.is_empty():
		return
	var idx := names.find(world_name)
	idx = wrapi((idx if idx >= 0 else 0) + dir, 0, names.size())
	_switch_world(String(names[idx]))


func _switch_world(name: String) -> void:
	world_name = name
	if not _load_active_world():
		# A brand-new name: start it empty (first F5 creates v1).
		_seed_world({ "blocks": [] }, true)
		_clear_objects()
		_world_watch_path = ""
		_world_watch_hash = ""
	_flash_status("world: %s (v%d)" % [world_name, store.latest_version(world_name) if store != null else 0])


## Watcher 2: reload when the active world's latest file CHANGES or a NEWER VERSION appears
## (Claude Code saving v(N+1) hot-swaps the running scene — append-only compatible).
func _poll_world_file() -> void:
	if store == null:
		return
	var latest: String = store.latest_path(world_name)
	if latest == "":
		return
	var h := _file_hash(latest)
	if latest != _world_watch_path or (h != "" and h != _world_watch_hash):
		_world_watch_path = latest
		_world_watch_hash = h
		var data: Dictionary = store.load_world(world_name)
		if not data.is_empty():
			_apply_world_data(data)


func _file_hash(path: String) -> String:
	if path == "" or not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).sha256_text()


func _resolve_worlds_dir(cfg: Dictionary) -> String:
	if worlds_dir_override != "":
		return worlds_dir_override
	var env := OS.get_environment("SANDBOX_WORLDS_DIR")
	if env != "":
		return env
	return String(cfg.get("worlds_dir", WorldStoreScript.DEFAULT_WORLDS_DIR))


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
	# HELD TOOLS (Liam spec 2026-07-03): holdable items whose click behavior overrides the MC defaults.
	# The sticky note is the one tool built now; the rotate/scale/manipulate wand is queued (same seam).
	for tool_entry in Items.tool_palette_entries():
		palette.append(tool_entry)

func _pal(name: String, shape: String, params: Dictionary, albedo: Array, category: String) -> Dictionary:
	# `material` starts as a plain albedo colour (UNTEXTURED). This dict is the per-block live-texturing seam.
	return { "kind": "block", "name": name, "shape": shape, "params": params, "material": { "albedo": albedo }, "category": category }


## EVERY imported asset joins the inventory as a kind:"asset" palette entry under a per-kit tab
## (spec: "include ... the other ones that were found and imported for other experiments").
## Metadata only — nothing loads until placement.
func _extend_palette_with_assets() -> void:
	if assets == null:
		return
	var kit_tints := {}
	var tints := [[0.55, 0.75, 0.55], [0.55, 0.68, 0.80], [0.80, 0.70, 0.55], [0.75, 0.60, 0.75]]
	for i in (assets.kits as Array).size():
		kit_tints[assets.kits[i]] = tints[i % tints.size()]
	for kit in assets.kits:
		for a in assets.kit_assets(String(kit)):
			palette.append({
				"kind": "asset",
				"name": String(a.get("name", a["id"])),
				"asset_id": String(a["id"]),
				"shape": "",
				"params": {},
				"material": { "albedo": kit_tints.get(kit, [0.6, 0.7, 0.6]) },
				"category": _kit_label(String(kit)),
			})

func _kit_label(kit: String) -> String:
	var words := kit.split("_")
	var out := []
	for w in words:
		out.append(String(w).capitalize())
	return " ".join(out)

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
	# The behavior panel (hidden until B) + the note editor (hidden until N).
	_build_behavior_panel()
	_build_note_panel()
	_refresh_status()


func _rebuild_hotbar_ui() -> void:
	if _hotbar_ui == null:
		return
	for c in _hotbar_ui.get_children():
		c.queue_free()
	for i in 9:
		var slot := _make_slot_button(hotbar[i], i == active_slot, str(i + 1))
		slot.role = "hotbar"                          # drag source + drop target
		slot.slot_index = i
		var idx := i
		slot.pressed.connect(func(): _select_slot(idx))
		_hotbar_ui.add_child(slot)
		_apply_slot_thumbnail(slot, hotbar[i])


## Build one drag-and-drop-aware inventory slot button (SandboxInventorySlot: extends Button).
## `role`/`slot_index` are set by the caller. Shows the item's thumbnail (image preview) if cached,
## else the flat albedo tint (fallback) + name.
func _make_slot_button(pal_idx: int, active: bool, label: String) -> Object:
	var b = _InvSlot.new()
	b.ctrl = self
	b.pal_idx = pal_idx
	b.custom_minimum_size = Vector2(56, 56)
	b.clip_text = true
	var entry: Dictionary = palette[pal_idx] if pal_idx >= 0 and pal_idx < palette.size() else {}
	var item_name := String(entry.get("name", "")) if pal_idx >= 0 else ""   # EMPTY_HAND (-1) => blank slot
	if label != "":
		b.text = "%s\n%s" % [label, item_name] if item_name != "" else label
	else:
		b.text = item_name
	b.add_theme_font_size_override("font_size", 11)
	# Tint the slot with the block's untextured albedo so the palette reads at a glance (fallback +
	# background behind the thumbnail).
	var col_arr = entry.get("material", {}).get("albedo", [0.8, 0.8, 0.8])
	var col := Color(col_arr[0], col_arr[1], col_arr[2])
	var sb := StyleBoxFlat.new()
	sb.bg_color = col.darkened(0.35)
	sb.set_border_width_all(3)
	sb.border_color = Color(1, 1, 0.4) if active else Color(0.15, 0.15, 0.18)
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb)
	b.add_theme_stylebox_override("pressed", sb)
	return b


## Overlay the item's image-preview thumbnail on a slot button (a TextureRect child that fills the
## button). If no thumbnail exists yet, request one (async render); the icon fills in on the next open.
func _apply_slot_thumbnail(slot: Object, pal_idx: int) -> void:
	if thumbs == null or pal_idx < 0 or pal_idx >= palette.size():
		return
	var entry: Dictionary = palette[pal_idx]
	var key := _thumb_key(entry)
	# Remove any prior thumbnail child.
	var old = (slot as Control).get_node_or_null("thumb")
	if old != null:
		old.queue_free()
	var tex: Texture2D = thumbs.get_texture(key)
	if tex != null:
		var tr := TextureRect.new()
		tr.name = "thumb"
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE   # clicks/drags pass through to the button
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.offset_top = 12                              # leave the top label visible
		(slot as Control).add_child(tr)
	else:
		# No thumbnail cached — kick off a render so it is ready next time the inventory opens.
		_request_thumbnail(pal_idx)


func _thumb_key(entry: Dictionary) -> String:
	var kind := String(entry.get("kind", "block"))
	if kind == "asset":
		return "asset__" + String(entry.get("asset_id", entry.get("name", "?")))
	if kind == "tool":
		return "tool__" + String(entry.get("tool", entry.get("name", "?")))
	return "block__" + String(entry.get("name", "?"))


## Render a thumbnail for a palette entry (block synchronously; asset when its GLB is loaded).
func _request_thumbnail(pal_idx: int) -> void:
	if thumbs == null or _headless or pal_idx < 0 or pal_idx >= palette.size():
		return
	var entry: Dictionary = palette[pal_idx]
	var key := _thumb_key(entry)
	if thumbs.has_thumbnail(key):
		return
	var kind := String(entry.get("kind", "block"))
	if kind == "block" or kind == "tool":
		var shape := String(entry.get("shape", ""))
		if shape == "":
			return                                       # tools have no mesh preview (flat tint is fine)
		await thumbs.ensure_block(key, shape, entry.get("params", {}), entry.get("material", {}).get("albedo", [0.8, 0.8, 0.8]))
	elif kind == "asset":
		var aid := String(entry.get("asset_id", ""))
		if assets != null and assets.is_loaded(aid):
			var tpl = assets._cache.get(aid)
			if tpl != null:
				await thumbs.ensure_asset(key, tpl)


## Public: a Texture2D thumbnail for a palette index (used by the drag preview). May be null.
func thumbnail_for(pal_idx: int) -> Texture2D:
	if thumbs == null or pal_idx < 0 or pal_idx >= palette.size():
		return null
	return thumbs.get_texture(_thumb_key(palette[pal_idx]))


func _build_inventory_panel() -> void:
	_inv_panel = Panel.new()
	_inv_panel.set_anchors_preset(Control.PRESET_CENTER)
	_inv_panel.custom_minimum_size = Vector2(560, 420)
	_inv_panel.size = Vector2(560, 420)
	_inv_panel.position = Vector2(-280, -210)
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
	# SEARCH box (control #1: "browse/scroll/search all assets + block types"). Typing filters the grid
	# across ALL categories by name; clearing it returns to the active category tab.
	_inv_search = LineEdit.new()
	_inv_search.placeholder_text = "search items…  (name substring; clear to browse by tab)"
	_inv_search.add_theme_font_size_override("font_size", 13)
	_inv_search.clear_button_enabled = true
	_inv_search.text_changed.connect(func(q: String): _on_inv_search(q))
	vb.add_child(_inv_search)
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
		var cc := String(cat)
		var t := Button.new()
		t.text = cc
		t.toggle_mode = true
		t.button_pressed = (cc == _active_category)
		t.pressed.connect(func(): _populate_inventory(cc))
		_inv_tabs.add_child(t)


func _populate_inventory(category: String) -> void:
	_active_category = category
	for c in _inv_grid.get_children():
		c.queue_free()
	var q := _inv_query.strip_edges().to_lower()
	for pal_idx in palette.size():
		var entry: Dictionary = palette[pal_idx]
		# With a search query set, match by name substring across ALL categories; else filter by tab.
		if q != "":
			if not String(entry.get("name", "")).to_lower().contains(q):
				continue
		elif entry["category"] != category:
			continue
		var b = _make_slot_button(pal_idx, false, "")
		b.role = "inventory"                          # drag source (drag onto a hotbar slot)
		b.custom_minimum_size = Vector2(80, 72)
		b.add_theme_font_size_override("font_size", 11)
		var idx: int = pal_idx
		b.pressed.connect(func(): _pick_into_hotbar(idx))
		_inv_grid.add_child(b)
		_apply_slot_thumbnail(b, pal_idx)
	# reflect the active tab (dimmed while a search query overrides the tab filter)
	for t in _inv_tabs.get_children():
		if t is Button:
			t.button_pressed = (q == "" and t.text == category)
	# Render any missing thumbnails for this tab's items, then re-apply so images fill in this open.
	if q == "":
		_render_missing_thumbnails_for(category)


## Search box changed: filter the grid by name substring (across all categories). Empty => back to tab view.
func _on_inv_search(query: String) -> void:
	_inv_query = query
	_populate_inventory(_active_category)


## Render (async) any not-yet-cached thumbnails for the given category, then re-skin the grid slots.
func _render_missing_thumbnails_for(category: String) -> void:
	if thumbs == null or _headless:
		return
	var rendered_any := false
	for pal_idx in palette.size():
		var entry: Dictionary = palette[pal_idx]
		if String(entry.get("category", "")) != category:
			continue
		var key := _thumb_key(entry)
		if thumbs.has_thumbnail(key):
			continue
		await _request_thumbnail(pal_idx)
		rendered_any = true
	# Only re-skin if the inventory is still open on this tab (the user may have moved on).
	if rendered_any and _inv_open and _active_category == category:
		for child in _inv_grid.get_children():
			if child.has_method("_get_drag_data") and int(child.pal_idx) >= 0:
				_apply_slot_thumbnail(child, int(child.pal_idx))


func _pick_into_hotbar(pal_idx: int) -> void:
	# MC creative: clicking (or dragging) a block in the inventory puts it in the ACTIVE hotbar slot.
	hotbar[active_slot] = pal_idx
	_refresh_held_item()
	_rebuild_hotbar_ui()
	_refresh_status()
	_update_preview_mesh()


## Drag-and-drop drop target: set a SPECIFIC hotbar slot to a palette entry (native DnD path).
func _set_hotbar_slot(slot: int, pal_idx: int) -> void:
	if slot < 0 or slot > 8 or pal_idx < 0 or pal_idx >= palette.size():
		return
	hotbar[slot] = pal_idx
	if slot == active_slot:
		_refresh_held_item()
	_rebuild_hotbar_ui()
	_refresh_status()
	_update_preview_mesh()


## Drag-and-drop between two hotbar slots (swap).
func _swap_hotbar_slots(a: int, b: int) -> void:
	if a < 0 or a > 8 or b < 0 or b > 8 or a == b:
		return
	var tmp: int = hotbar[a]
	hotbar[a] = hotbar[b]
	hotbar[b] = tmp
	_refresh_held_item()
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
	_refresh_held_item()
	_rebuild_hotbar_ui()
	_refresh_status()
	_update_preview_mesh()


## DROP (Q, MC default — Liam item 1, 2026-07-05): drop the held item. For now it simply DISAPPEARS (no
## physics / ground rest), emptying the held slot back to EMPTY_HAND. A no-op if the hand is already empty.
func _drop_held() -> void:
	if _hand_empty():
		return
	var dropped_name := String(_active_entry().get("name", "item"))
	hotbar[active_slot] = EMPTY_HAND
	_after_hotbar_change()
	_flash_status("dropped %s (empty hand)" % dropped_name)


var _flash_text := ""
var _flash_until := 0.0

func _flash_status(msg: String) -> void:
	_flash_text = msg
	_flash_until = _time + 4.0
	_refresh_status()
	print("[sandbox] %s" % msg)


func _refresh_status() -> void:
	if _status == null:
		return
	var lines := []
	if _hand_empty():
		lines.append("Empty hand   (slot %d)   |   world: %s   |   LEFT destroy · MIDDLE pick · RMB (nothing) · 1-9 slots · E inventory · Q drop · WASD fly" % [
			active_slot + 1, world_name])
	else:
		var entry: Dictionary = _active_entry()
		var kind := String(entry.get("kind", "block"))
		var label := "Tool" if kind == "tool" else ("Asset" if kind == "asset" else "Block")
		if kind == "tool":
			lines.append("%s: %s   (slot %d)   |   world: %s   |   LEFT use · MIDDLE pick · 1-9 slots · E inventory · Q drop · WASD+Space/Shift fly" % [
				label, String(entry["name"]), active_slot + 1, world_name])
		else:
			lines.append("%s: %s   (slot %d)   |   world: %s   |   RIGHT place · LEFT destroy · MIDDLE pick · 1-9 slots · E inventory · Q drop · WASD fly" % [
				label, String(entry["name"]), active_slot + 1, world_name])
	if _debug_verbs and selected_id != "" and objects.has(selected_id):
		var rec: Dictionary = objects[selected_id]
		lines.append("[debug] Selected: %s (%s)%s   |   G grab · R rotate · +/- scale · X delete · B behaviors · N note" % [
			selected_id, _obj_label(rec), "  [GRABBED — click to drop]" if _grabbing else ""])
	else:
		lines.append("F5 save world · [ ] switch world · \\ toggle debug verbs%s" % ("  [DEBUG VERBS ON]" if _debug_verbs else ""))
	if _time < _flash_until and _flash_text != "":
		lines.append(">> " + _flash_text)
	_status.text = "\n".join(lines)


# ── the SUBTLE placement-point DOT (Liam correction 2026-07-05) ───────────────────────────────────────
# Liam rejected the grid-cell placement highlight. A SUBTLE crosshair dot at the FREE aim point is fine
# ("A subtle crosshair dot is fine; the big grid-cell highlight is not."). `_preview` is now a tiny faint
# sphere sitting at the exact free hit point (where the held block/asset would spawn) — not a grid cell,
# not a full-size ghost mesh. Hidden while holding a tool (the tool draws its own preview) or grabbing.
func _update_preview() -> void:
	if _preview == null:
		return
	# No placement dot when there is nothing to place: empty hand, a held tool, grabbing, inventory, or --shot.
	if _did_shot or _inv_open or _cam == null or _grabbing or _hand_empty() or Items.is_tool_entry(_active_entry()):
		_preview.visible = false
		return
	var rc := _raycast_free()
	_preview.visible = true
	_preview.position = rc["point"]


## The subtle dot has a FIXED tiny mesh (a small sphere) — it does not mirror the held block's shape, so
## there is no big grid-cell-sized preview. Kept as a no-op-shaped setter for the call sites that still
## refresh on hotbar change (cheap; the dot mesh never actually changes).
func _update_preview_mesh() -> void:
	pass


# ══ WORLD NODES + ENVIRONMENT ═════════════════════════════════════════════════════════════════════════
func _build_world_nodes() -> void:
	_cam = Camera3D.new()
	_cam.fov = 70.0
	add_child(_cam)
	_blocks_root = Node3D.new()
	_blocks_root.name = "Blocks"
	add_child(_blocks_root)
	_objects_root = Node3D.new()
	_objects_root.name = "Objects"
	add_child(_objects_root)
	# The SUBTLE placement-point dot + the target outline + the selection marker (all non-headless).
	if not _headless:
		# subtle placement dot: a tiny faint sphere at the free aim point (NOT a grid-cell ghost).
		_preview = MeshInstance3D.new()
		var dot := SphereMesh.new()
		dot.radius = 0.05
		dot.height = 0.10
		_preview.mesh = dot
		var ghost := StandardMaterial3D.new()
		ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost.albedo_color = Color(1, 1, 1, 0.5)
		ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_preview.material_override = ghost
		_preview.visible = false
		add_child(_preview)
		# OBJECT-target outline: a thin bright wire-box around the exact thing the crosshair points at, so
		# it is clear what LMB destroy / MMB pick will act on (coordinator control #2). This is the ACTUAL
		# targeted object — NOT the rejected grid-cell placement highlight.
		_target_outline = MeshInstance3D.new()
		var obox := BoxMesh.new()
		_target_outline.mesh = obox
		var omat := StandardMaterial3D.new()
		omat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		omat.albedo_color = Color(1.0, 1.0, 1.0, 0.16)
		omat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		omat.grow = true                            # a slight outward grow so the outline hugs the surface
		omat.grow_amount = 0.02
		_target_outline.material_override = omat
		_target_outline.visible = false
		add_child(_target_outline)
		_sel_marker = MeshInstance3D.new()
		_sel_marker.mesh = BoxMesh.new()
		var selmat := StandardMaterial3D.new()
		selmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		selmat.albedo_color = Color(1.0, 0.9, 0.2, 0.22)
		selmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_sel_marker.material_override = selmat
		_sel_marker.visible = false
		add_child(_sel_marker)


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


# ── panels: behaviors (B) + note editor (N) ───────────────────────────────────────────────────────────
func _build_behavior_panel() -> void:
	_behavior_panel = Panel.new()
	_behavior_panel.set_anchors_preset(Control.PRESET_CENTER)
	_behavior_panel.custom_minimum_size = Vector2(340, 240)
	_behavior_panel.size = Vector2(340, 240)
	_behavior_panel.position = Vector2(-170, -120)
	_behavior_panel.visible = false
	_hud.add_child(_behavior_panel)
	_behavior_list = Label.new()
	_behavior_list.set_anchors_preset(Control.PRESET_FULL_RECT)
	_behavior_list.offset_left = 16; _behavior_list.offset_top = 12
	_behavior_list.add_theme_font_size_override("font_size", 15)
	_behavior_panel.add_child(_behavior_list)


func _build_note_panel() -> void:
	_note_panel = Panel.new()
	_note_panel.set_anchors_preset(Control.PRESET_CENTER)
	_note_panel.custom_minimum_size = Vector2(560, 110)
	_note_panel.size = Vector2(560, 110)
	_note_panel.position = Vector2(-280, -55)
	_note_panel.visible = false
	_hud.add_child(_note_panel)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 12; vb.offset_top = 10; vb.offset_right = -12; vb.offset_bottom = -10
	vb.add_theme_constant_override("separation", 6)
	_note_panel.add_child(vb)
	_note_target_label = Label.new()
	_note_target_label.add_theme_font_size_override("font_size", 13)
	vb.add_child(_note_target_label)
	_note_edit = LineEdit.new()
	_note_edit.placeholder_text = "note for Claude Code…  (Enter saves · ESC cancels)"
	_note_edit.add_theme_font_size_override("font_size", 15)
	vb.add_child(_note_edit)
	_note_edit.text_submitted.connect(func(_t: String): _close_note(true))


# ══ PARAMS: the openable / hotloadable settings DATA ══════════════════════════════════════════════════
# Settings + the active-world selection live in godot/examples/sandbox_params.json. Content-change →
# re-apply (the LiveHost pattern). On first run a seed file is written so there is something to edit.
# (World CONTENT lives in the world store — watcher 2 — so the params file stays small and settings-only;
# the legacy `blocks` list is still honored as a fallback when the store has no active world.)
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
	var np := OS.get_environment("SANDBOX_NOTES_PATH")
	if np == "":
		np = String(cfg.get("notes_path", DEFAULT_NOTES_PATH))
	notes_path = np


## Seed (or, on hotload, re-seed) the BLOCK layer from a `blocks` list. Each entry is
## {cell:[x,y,z], block:"Cube"} — a grid coord + a palette block NAME. On a live re-seed we clear the
## world first so the incoming data is the source of truth for the seeded build.
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
			# Optional per-block `material` override — a block entry can carry a file/procedural
			# texture descriptor and seed TEXTURED (the live-texturing module, hotloadable).
			var mo = b.get("material", {})
			_set_block(cell, pal_idx, mo if typeof(mo) == TYPE_DICTIONARY else {})
	# LIVE-TEXTURING ops: a top-level `material_ops` list re-skins ALREADY-PLACED blocks. Each entry
	# is exactly the DATA the TextureApply node emits ({cell:[x,y,z], material:{...}} — the "op" tag
	# is tolerated and ignored), so a node-graph tick's output pasted into this file textures the
	# world live via the same hotload watcher. Ops on empty cells are skipped (never crash).
	_apply_material_ops(cfg.get("material_ops", []))


## Apply set_material ops (the TextureApply node's output shape) onto existing blocks: overlay the
## descriptor keys onto the block's `material` DATA and re-run the ONE material seam. Returns how
## many ops applied (headless tests assert on it).
func _apply_material_ops(ops) -> int:
	if typeof(ops) != TYPE_ARRAY:
		return 0
	var applied := 0
	for op in ops:
		if typeof(op) != TYPE_DICTIONARY:
			continue
		var cell_arr = op.get("cell", null)
		var mat_desc = op.get("material", null)
		if typeof(cell_arr) != TYPE_ARRAY or (cell_arr as Array).size() < 3 or typeof(mat_desc) != TYPE_DICTIONARY:
			continue
		var cell := Vector3i(int(cell_arr[0]), int(cell_arr[1]), int(cell_arr[2]))
		if not world.has(cell):
			continue
		var rec: Dictionary = world[cell]
		var material: Dictionary = rec.get("material", {})
		for k in mat_desc:
			material[k] = mat_desc[k]
		rec["material"] = material
		var n = rec.get("node", null)
		if n is MeshInstance3D and is_instance_valid(n):
			_apply_material(n, material)
			applied += 1
	return applied


func _palette_index(name: String) -> int:
	for i in palette.size():
		if String(palette[i]["name"]) == name and String((palette[i] as Dictionary).get("kind", "block")) == "block":
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
		"world": "starter",
		"blocks": blocks,
	}


# ══ BENCH ═════════════════════════════════════════════════════════════════════════════════════════════
# --bench: print startup + memory numbers as one JSON line, then quit (headless-safe). --eager adds a
# force-load of EVERY manifest asset first — the "what if everything loaded at startup" comparison that
# quantifies what lazy loading saves.
func _bench_requested() -> bool:
	return "--bench" in OS.get_cmdline_user_args() or "--bench" in OS.get_cmdline_args()


func _run_bench(t0: int) -> void:
	var eager := ("--eager" in OS.get_cmdline_user_args()) or ("--eager" in OS.get_cmdline_args())
	if eager:
		for id in assets.manifest:
			assets.request_sync(String(id))
	else:
		# Lazy mode still waits for the starting world's preload set (the honest "ready to build" time).
		var deadline := Time.get_ticks_msec() + 30000
		while assets.pending_count() > 0 and Time.get_ticks_msec() < deadline:
			await get_tree().process_frame
	var report := {
		"mode": "eager" if eager else "lazy",
		"startup_ms": Time.get_ticks_msec() - t0,
		"manifest_assets": (assets.manifest as Dictionary).size(),
		"assets_loaded": assets.loaded_count(),
		"blocks": world.size(),
		"objects": objects.size(),
		"mem_static_mb": snappedf(float(OS.get_static_memory_usage()) / 1048576.0, 0.1),
	}
	print("[sandbox_bench] %s" % JSON.stringify(report))
	get_tree().quit(0)


# ══ HEADLESS PROOF ════════════════════════════════════════════════════════════════════════════════════
# --shot: render the seeded build to a proof PNG (docs/sandbox_creative.png), then quit. Runs windowed
# (a real viewport is needed to grab pixels); the caller supplies a window via the normal scene launch.
func _take_shot() -> void:
	_did_shot = true
	# GUARD (found by the sandbox-live-verify adversarial pass, 2026-07-02): under --headless there is
	# no renderer, so `await RenderingServer.frame_post_draw` below never fires and the process HANGS
	# forever instead of writing a proof. Fail fast + loud with a nonzero exit so callers notice.
	if _headless:
		print("[sandbox_creative] --shot needs a display (no renderer under --headless; run without --headless). Quitting with exit 2.")
		get_tree().quit(2)
		return
	# --inv: open the creative inventory before the grab, to prove the MC inventory panel renders.
	var inv := ("--inv" in OS.get_cmdline_user_args()) or ("--inv" in OS.get_cmdline_args())
	var out_path := SHOT_PATH
	if inv and not _headless and _inv_panel != null:
		_toggle_inventory()
		out_path = "res://docs/sandbox_creative_inventory.png"
	# Wait for the world's lazy asset loads so the proof shows the real models, not placeholders.
	var deadline := Time.get_ticks_msec() + 20000
	while assets.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	# Let the scene light + render a few frames before grabbing.
	for _i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://docs")
	img.save_png(out_path)
	print("[sandbox_creative] proof written: %s  (%d blocks, %d objects)" % [out_path, world.size(), objects.size()])
	get_tree().quit(0)


func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()


func _mtime(path: String) -> int:
	if not FileAccess.file_exists(path):
		return -1
	return int(FileAccess.get_modified_time(ProjectSettings.globalize_path(path)))
