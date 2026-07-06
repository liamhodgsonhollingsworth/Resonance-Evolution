extends RefCounted
## INPUT GATE — one shared, reusable predicate every input reader consults so keystrokes never leak
## into gameplay while the player is typing or an overlay owns the keyboard (Liam 2026-07-05 defects):
##   • "when writing a note, the controls still influence the environment, so pressing space still
##      makes me jump when typing" — movement is polled with Input.is_key_pressed(), which reads the
##      RAW keyboard and IGNORES set_input_as_handled(); nothing but an explicit check stops it. This
##      helper IS that check: `text_input_active()` is true whenever a LineEdit / TextEdit / SpinBox
##      (or any control that eats keyboard input) holds GUI focus, so a movement reader can early-out.
##   • ESC-bubbling: a same-window scene's TransitionOverlay treats ESC as "leave to the room". While a
##      note box / inventory is open, ESC must instead close THAT and stay. `scene_holds_esc()` asks
##      the running scene whether it wants ESC (it exposes `wants_esc()` when an overlay is open), so
##      the overlay defers instead of yanking the player out (defects "escape when writing a note ...
##      go back to the aperture" + "leaving inventory ... escape still takes me back to the room").
##
## Pure static predicates, preload()ed by PATH (no class_name — mistake #046). No state, no nodes.

## True when a keyboard-consuming Control (text field) currently owns GUI focus in `viewport`, so a
## RAW-input movement/action reader should suppress itself this frame. Robust to headless (no viewport
## → false) and to any focus owner that declares it is an editable/range control.
static func text_input_active(viewport: Viewport) -> bool:
	if viewport == null:
		return false
	var focus := viewport.gui_get_focus_owner()
	if focus == null:
		return false
	# The concrete text controls the game uses for notes / search / spin fields.
	if focus is LineEdit or focus is TextEdit or focus is SpinBox or focus is CodeEdit:
		return true
	# Anything else focus-taking that declares it edits text/values while focused.
	if focus.focus_mode == Control.FOCUS_NONE:
		return false
	return focus is Range or ("editable" in focus)


## True when the currently-running scene wants to keep ESC for itself this frame (a note box or
## inventory is open, so ESC should close THAT, not leave the scene). A scene opts in by exposing a
## `wants_esc()` method returning true while any of its ESC-closable overlays is open. Scenes without
## the method (or headless) return false, so behaviour degrades to "ESC leaves" exactly as before.
## A focused text field also counts as holding ESC (ESC should cancel the field, never leave).
static func scene_holds_esc(tree: SceneTree) -> bool:
	if tree == null:
		return false
	if tree.root != null and text_input_active(tree.root):
		return true
	# The GLOBAL F1 note box (GizmoNote autoload) is a keyboard overlay that lives ABOVE every scene;
	# its LineEdit may release focus in the same ESC frame it closes, so check its own open flag too so
	# the overlay reliably defers (fixes "escape when writing a note ... go back to the aperture room").
	var gn := tree.root.get_node_or_null("/root/GizmoNote") if tree.root != null else null
	if gn != null and gn.has_method("holds_esc") and bool(gn.call("holds_esc")):
		return true
	var scene := tree.current_scene
	if scene == null:
		return false
	return scene.has_method("wants_esc") and bool(scene.call("wants_esc"))
