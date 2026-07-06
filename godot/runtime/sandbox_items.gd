extends RefCounted
## HELD-ITEM SEAM — what you HOLD decides what clicking does.
##
## Spec (Liam, 2026-07-03 verbatim):
##   "The default when you are not interacting with anything is that you should have standard
##    minecraft controls ... Right click places things, left click destroys. Middle click grabs
##    the thing you are looking at currently ... The other features like rotating/scaling/
##    manipulating or using context menus should be nodes that I can use, items that I can hold
##    in my hand and right/left clicking using those items has different behavior than usual."
##
## THE SEAM (why this file exists as DATA, not branches in the controller):
##   The controller (sandbox_creative.gd) never hard-codes what a click does. It asks the ACTIVE
##   HELD ITEM. An item is a DATA descriptor with an optional behavior handler:
##       { kind, name, tool?:"sticky_note", ... }
##   The EMPTY HAND is itself an item (`EMPTY`) whose handler is the Minecraft default:
##       primary  (LEFT click)  -> destroy the targeted thing
##       secondary(RIGHT click) -> place the active hotbar block/asset
##       middle   (MIDDLE click)-> pick the looked-at thing into the hand
##   A TOOL item (the sticky note today; the wand later) overrides any of these hooks and can
##   draw a WHILE-HELD preview (the sticky note's little orb at the aimed point).
##
##   This is the engine's data-behavior idiom (the same shape as sandbox_behaviors.gd and the
##   GraphRuntime primitive registry): a new tool is ONE registry entry + its handler object;
##   the controller's click code never changes. The future wand (rotate/scale/manipulate) is a
##   NEW handler dropped in here — exactly the plug point the spec asks for.
##
## HANDLER CONTRACT (duck-typed; a handler is any object exposing the hooks it wants to override):
##   func primary(ctrl) -> void        # LEFT click while this item is held
##   func secondary(ctrl) -> void      # RIGHT click while this item is held
##   func middle(ctrl) -> void         # MIDDLE click while this item is held
##   func while_held(ctrl, delta) -> void   # per-frame (draw a preview, etc.)
##   func on_select(ctrl) -> void      # this item just became the held item
##   func on_deselect(ctrl) -> void    # a different item was just selected
##   Any hook a handler does NOT define falls through to the MC default (see resolve()).
##   `ctrl` is the sandbox controller; handlers call its small documented API (place/destroy/pick,
##   raycast, etc.) — they never reach into its internals beyond that surface.
##
## No class_name (mistake #046): consumers preload() this file by path.

const StickyNote := preload("res://runtime/sticky_note.gd")
const ManipulationWand := preload("res://runtime/manipulation_wand.gd")

## Marker payloads a palette/hotbar entry can carry in its `tool` field. Empty/absent => a plain
## block or asset (no tool behavior — the MC defaults apply).
const TOOL_STICKY_NOTE := "sticky_note"
const TOOL_WAND := "wand"                   # the PRECISE move + rotate manipulation tool (Liam item 3)

## The tools that appear in the inventory as HOLDABLE ITEMS (beyond blocks + assets). Each is a
## palette-entry template; the controller appends these into the palette under a "Tools" tab.
## kind:"tool" so placement/removal code skips them (they are not placed — they ACT on click).
static func tool_palette_entries() -> Array:
	return [
		{
			"kind": "tool",
			"name": "Sticky Note",
			"tool": TOOL_STICKY_NOTE,
			"shape": "",
			"params": {},
			# a warm orange so it reads as the sticky note in the flat-colour fallback + hotbar tint
			"material": { "albedo": [0.98, 0.62, 0.12] },
			"category": "Tools",
		},
		{
			"kind": "tool",
			"name": "Manipulation Wand",
			"tool": TOOL_WAND,
			"shape": "",
			"params": {},
			# a cool cyan so the wand reads distinctly from the orange sticky note in the hotbar
			"material": { "albedo": [0.25, 0.75, 0.95] },
			"category": "Tools",
		},
	]


## Build the handler object for an item entry. Blocks/assets/empty-hand => null (MC defaults).
## A tool entry => its handler (stateful per-controller, so one instance is made and reused).
static func make_handler(entry: Dictionary) -> Object:
	if String(entry.get("kind", "block")) != "tool":
		return null
	match String(entry.get("tool", "")):
		TOOL_STICKY_NOTE:
			return StickyNote.new()
		TOOL_WAND:
			return ManipulationWand.new()
		_:
			return null


## Is this entry a holdable TOOL (vs a placeable block/asset)?
static func is_tool_entry(entry: Dictionary) -> bool:
	return String(entry.get("kind", "block")) == "tool"
