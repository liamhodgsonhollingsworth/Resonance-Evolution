class_name FpsController
extends CharacterBody3D
## A minimal first-person walk/look controller — IN-HOUSE, written from scratch for clean
## licensing (no vendored third-party controller; the project's O'Saasy/MIT posture stays
## uncomplicated). ~90 lines, no dependencies beyond Godot's CharacterBody3D + a child Camera3D.
##
## Controls: WASD move, mouse look, Space jump, Shift sprint, Esc release mouse, click recapture.
## It is a plain navigation primitive — it touches NONE of the runtime/primitive/Context seam;
## it only moves a body + camera so a human can look at whatever the renderer delegate spawned.

const InputGate := preload("res://walkabout/input_gate.gd")

@export var mouse_sensitivity: float = 0.0025
@export var walk_speed: float = 4.0
@export var sprint_speed: float = 7.0
@export var jump_velocity: float = 4.5
@export var gravity: float = 14.0

var _camera: Camera3D
var _pitch: float = 0.0   # accumulated look pitch (radians), clamped to avoid flipping

func _ready() -> void:
	# Find or create the look camera as a child at eye height.
	_camera = _find_camera(self)
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		_camera.position = Vector3(0, 1.6, 0)
		add_child(_camera)
	# Capture the mouse only when there's a real window (skip headless/CI so _ready never aborts).
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _find_camera(n: Node) -> Camera3D:
	for c in n.get_children():
		if c is Camera3D:
			return c
	return null

func _unhandled_input(event: InputEvent) -> void:
	# While a text field (note box / any LineEdit) is focused, the keyboard + look belong to it -
	# do not turn the camera (Liam 2026-07-05: typing must not drive the environment).
	if InputGate.text_input_active(get_viewport()):
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Yaw turns the body; pitch tilts only the camera (so movement stays level).
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		_camera.rotation.x = _pitch
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	# RAW-input gate (Liam 2026-07-05 defect: "space still makes me jump when typing"). Input.is_key_
	# pressed() below reads the physical keyboard and ignores set_input_as_handled(), so the ONLY way to
	# stop movement/jump while a text field owns focus is to check for it explicitly and zero the body.
	if InputGate.text_input_active(get_viewport()):
		velocity.x = 0.0
		velocity.z = 0.0
		if not is_on_floor():
			velocity.y -= gravity * delta
		move_and_slide()
		return
	# Gravity + jump.
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif Input.is_key_pressed(KEY_SPACE):
		velocity.y = jump_velocity

	# Horizontal movement from WASD, relative to where the body faces.
	var input_dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): input_dir.z -= 1.0
	if Input.is_key_pressed(KEY_S): input_dir.z += 1.0
	if Input.is_key_pressed(KEY_A): input_dir.x -= 1.0
	if Input.is_key_pressed(KEY_D): input_dir.x += 1.0
	var dir := (transform.basis * input_dir).normalized()
	var speed := sprint_speed if Input.is_key_pressed(KEY_SHIFT) else walk_speed
	velocity.x = dir.x * speed
	velocity.z = dir.z * speed

	move_and_slide()
