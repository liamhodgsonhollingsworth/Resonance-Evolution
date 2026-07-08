extends SceneTree
## HEADLESS SELF-TEST for the VISI-SONOR BACKEND REWIRE (REQ 4), WITHOUT a window.
##
##   <godot> --headless --path godot -s res://headless_visisonor_rewire_test.gd
##
## Judge PASS by the sentinel "RESULT: ALL PASS" (NOT the exit code — Godot's is unreliable headless).
##
## Liam (REQ 4): the backend rewiring of lamp<->lighting nodes must EXIST + be tested (the UI is LATER).
## This drives the REAL DemoInteractions controller and proves rewire_fixture() repoints a lamp's LIGHTING
## feature at RUNTIME, as pure DATA, and that the change is visible in the LIVE output:
##   (1) lamp_a (addr 0, biggest) is initially bound to a BASS feature (low/sub) — the size-sort default;
##   (2) BEFORE rewire it TRACKS BASS: brighter on a bass frame than a treble frame;
##   (3) rewire_fixture("r:lamp_a_light/light", "treble") repoints the binding to the treble frame key
##       (resolved via PrimFeaturePick's canonical vocabulary — reused, not reinvented);
##   (4) AFTER rewire it TRACKS TREBLE (not bass): now brighter on a treble frame than a bass frame — both
##       in the device.set_led RECEIPT and on the live Light3D — proving the rewire changed the live output.
##
## Reuses the bass/treble band-frame injection pattern from headless_visisonor_demo_test.

const DemoScript := preload("res://aperture/demo_interactions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")

const LAMP_A := "r:lamp_a_light/light"

var _fail := 0

# Clearly bass-dominant vs treble-dominant frames (same shape as the visisonor demo test).
var _bass := { "signal.band.low": 0.95, "signal.band.mid": 0.1, "signal.band.high": 0.05,
	"signal.band.sub": 0.9, "signal.band.lowmid": 0.2, "signal.band.highmid": 0.05, "signal.energy": 0.6 }
var _treble := { "signal.band.low": 0.05, "signal.band.mid": 0.1, "signal.band.high": 0.95,
	"signal.band.sub": 0.05, "signal.band.lowmid": 0.1, "signal.band.highmid": 0.9, "signal.energy": 0.6 }

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	await _test_rewire()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)


func _test_rewire() -> void:
	DeviceActions.unregister_device_ops_host()
	var demo = DemoScript.new()
	get_root().add_child(demo)
	await process_frame
	await process_frame
	_check("demo built the room + visi-sonor layer", demo.room != null and is_instance_valid(demo.room))

	# (1) lamp_a starts bound to a bass feature (low/sub) — the size-sort default (big lamp -> low band).
	var initial: String = demo.fixture_feature_key(LAMP_A)
	_check("(1) lamp_a is initially bound to a BASS feature (low/sub): " + initial,
		initial.findn("low") >= 0 or initial.findn("sub") >= 0)

	# (2) BEFORE rewire: lamp_a tracks BASS — brighter (receipt luminance) on a bass frame than a treble one.
	var recv_bass_before := _drive_and_receipt(demo, _bass)
	var recv_treble_before := _drive_and_receipt(demo, _treble)
	_check("(2) BEFORE rewire lamp_a tracks BASS (brighter on bass than treble)",
		_lum(recv_bass_before) > _lum(recv_treble_before) + 0.02)

	# (3) REWIRE the backend: repoint lamp_a from bass -> treble at runtime (pure data, no code change).
	demo.rewire_fixture(LAMP_A, "treble")
	var rewired: String = demo.fixture_feature_key(LAMP_A)
	_check("(3) rewire_fixture repointed the binding to the treble frame key (signal.band.high)",
		rewired == "signal.band.high")

	# (4) AFTER rewire: lamp_a now tracks TREBLE (NOT bass) — the LIVE output flipped, in both the receipt
	# and the live Light3D energy.
	var recv_treble_after := _drive_and_receipt(demo, _treble)
	var e_treble_light: float = _lamp_energy(demo)
	var recv_bass_after := _drive_and_receipt(demo, _bass)
	var e_bass_light: float = _lamp_energy(demo)
	_check("(4) AFTER rewire lamp_a tracks TREBLE in the receipt (brighter on treble than bass)",
		_lum(recv_treble_after) > _lum(recv_bass_after) + 0.02)
	_check("(4) AFTER rewire lamp_a's LIVE Light3D is brighter on a treble frame than a bass frame",
		e_treble_light > e_bass_light + 1.0)
	# The flip is genuine: what USED to be the bright frame (bass) is now the dim one.
	_check("(4) the rewire FLIPPED the response (bass went from brightest to dimmer than treble)",
		_lum(recv_bass_after) < _lum(recv_treble_after))

	demo.queue_free()
	DeviceActions.unregister_device_ops_host()


# --- helpers ---------------------------------------------------------------------------------------

## Drive one band frame through the whole light show and return lamp_a's (addr 0) device.set_led receipt.
func _drive_and_receipt(demo, frame: Dictionary) -> Dictionary:
	demo.drive_visisonor(frame)
	return demo.led_receipt(0)

## lamp_a's live Light3D energy right now (read after a drive_visisonor).
func _lamp_energy(demo) -> float:
	var light = demo._resolve_fixture_light(LAMP_A)
	return light.light_energy if light != null else 0.0

## Luminance of a device.set_led receipt (r,g,b).
func _lum(receipt: Dictionary) -> float:
	return 0.2126 * float(receipt.get("r", 0.0)) + 0.7152 * float(receipt.get("g", 0.0)) + 0.0722 * float(receipt.get("b", 0.0))
