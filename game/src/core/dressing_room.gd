class_name DressingRoom
extends Node3D
## New-game dressing room (11 §5.1): a small dark room with a tall mirror
## lit by one warm light, the player in first person in front of it and the
## mirror screen. Every change is applied to the body at once; turning and
## leaning drive the body and the eye. Confirm starts the new game in
## App.pending_slot with the chosen look; Cancel returns to the title. The
## body scenes and the clip library come from customization.json.

const MIRROR_W := 0.9
const MIRROR_H := 1.9
## The player stands this far in front of the glass, metres.
const STAND_M := 1.3
## How fast the eye moves when leaning, m/s.
const LEAN_MS := 1.0

var motor: PlayerMotor
var cam: PlayerCamera
var body: PlayerBody
var mirror: Mirror
var mirrors: MirrorSystem
var screen: MirrorScreen
var errors: PackedStringArray = []

var _cust := {}
var _lean_eye_m := 0.6


## Whether the content holds what the room needs.
static func can_open() -> bool:
	var cust: Variant = ContentDB.file_data("customization.json")
	if not cust is Dictionary:
		return false
	var c: Dictionary = cust
	return not (c.get("body_scenes", {}) as Dictionary).is_empty() and c.has("clip_library")


func _ready() -> void:
	if not build():
		Log.error("dressing room", "; ".join(errors))
		App.start_game.call_deferred(App.pending_slot, true)


## Builds the room, the player and the screen; false with `errors`.
func build() -> bool:
	_cust = ContentDB.file_data("customization.json")
	var mirror_cfg := ContentDB.tuning("mirror")
	_lean_eye_m = float(mirror_cfg.get("lean_eye_m", 0.6))
	_room()
	mirror = Mirror.new()
	mirror.width_m = MIRROR_W
	mirror.height_m = MIRROR_H
	add_child(mirror)
	mirror.position = Vector3(0, MIRROR_H * 0.5 + 0.1, 0)  # faces +Z, into the room
	var size: Variant = Quality.value("mirror_size")
	if not mirror.configure(
		mirror_cfg, int(size) if size else 1024, 60.0, OS.has_feature("mobile")
	):
		errors.append_array(mirror.errors)
		return false
	motor = PlayerMotor.new()
	add_child(motor)
	motor.process_mode = Node.PROCESS_MODE_DISABLED  # stands still
	cam = PlayerCamera.new()
	add_child(cam)
	body = PlayerBody.new()
	add_child(body)
	var mv := ContentDB.tuning("movement")
	if not motor.setup(mv) or not cam.setup(motor, ContentDB.tuning("camera")):
		errors.append_array(motor.errors + cam.errors)
		return false
	motor.global_position = Vector3(0, 0, STAND_M)
	cam.yaw = 0.0  # faces -Z: the mirror
	cam.current = true
	var look := Appearance.default_of(_cust)
	var scene := load(String(_cust.body_scenes[look.body])) as PackedScene
	var clips := load(String(_cust.clip_library)) as AnimationLibrary
	var ok := body.setup(
		motor,
		cam,
		scene,
		clips,
		mv,
		ContentDB.tuning("body"),
		_cust.get("head_segments", []),
		_cust.get("head_meshes", [])
	)
	if not ok:
		errors.append_array(body.errors)
		return false
	mirrors = MirrorSystem.new()
	add_child(mirrors)
	mirrors.setup(cam, mirror_cfg, null)
	mirrors.add_mirror(mirror)
	var layer := CanvasLayer.new()
	add_child(layer)
	screen = (load("res://ui/mirror_screen.tscn") as PackedScene).instantiate()
	layer.add_child(screen)
	screen.confirmed.connect(_on_confirmed)
	screen.cancelled.connect(_on_cancelled)
	screen.open(_cust, look, MirrorScreen.Mode.NEW_GAME, apply_look)
	apply_look(look)
	return true


## Applies `look` to the body (called after every change on the screen).
func apply_look(look: Dictionary) -> void:
	for m: String in body.apply_appearance(look, _cust):
		Log.warn("appearance", "missing %s" % m)


func _process(delta: float) -> void:
	if screen == null or screen.state != MirrorScreen.State.OPEN:
		return
	body.turn_offset = screen.turn_angle()
	var glass := mirror.distance_to_eye(cam.global_position) + cam.lean_m
	var target := maxf(0.0, glass - _lean_eye_m) if screen.leaning else 0.0
	cam.lean_m = move_toward(cam.lean_m, target, LEAN_MS * delta)


func _on_confirmed(look: Dictionary) -> void:
	App.start_game(App.pending_slot, true, look)


func _on_cancelled() -> void:
	App.show_title()


func _room() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.02, 0.02, 0.02)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.06, 0.05, 0.05)
	add_child(env)
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.12, 0.11, 0.1)
	for spec: Array in [
		[Vector3(6, 0.1, 6), Vector3(0, -0.05, 1.5)],
		[Vector3(6, 3, 0.1), Vector3(0, 1.5, -0.1)],
		[Vector3(0.1, 3, 6), Vector3(-2.5, 1.5, 1.5)],
		[Vector3(0.1, 3, 6), Vector3(2.5, 1.5, 1.5)],
		[Vector3(6, 3, 0.1), Vector3(0, 1.5, 3.5)],
	]:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = spec[0]
		box.mesh = mesh
		box.position = spec[1]
		box.material_override = dark
		add_child(box)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.78, 0.55)
	light.light_energy = 2.0
	light.omni_range = 5.0
	light.shadow_enabled = true
	light.position = Vector3(0.6, 2.3, 0.9)
	add_child(light)
