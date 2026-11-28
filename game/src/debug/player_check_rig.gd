class_name PlayerCheckRig
extends Node3D
## The player's motor, camera and body on a lit ground plane, for render
## checks of the body (needs a display). Built from the body scene and clip
## library named on the command line (--body, --clips) and the content's
## tuning and customization data.

var motor: PlayerMotor
var cam: PlayerCamera
var body: PlayerBody
var sun: DirectionalLight3D
var errors: PackedStringArray = []


## Builds everything under this node; false with `errors`.
func build(args: Dictionary) -> bool:
	var body_scene := load(String(args.get("body", ""))) as PackedScene
	var clips := load(String(args.get("clips", ""))) as AnimationLibrary
	var cust: Variant = ContentDB.file_data("customization.json")
	if body_scene == null or clips == null or not cust is Dictionary:
		errors.append("needs --body <scene> --clips <library> and customization.json")
		return false
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-35.0, 0.0, 0.0)  # light travels toward -Z
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.3, 0.35, 0.4)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.25, 0.25, 0.25)
	add_child(env)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(60.0, 60.0)
	ground.mesh = plane
	add_child(ground)
	motor = PlayerMotor.new()
	add_child(motor)
	motor.process_mode = Node.PROCESS_MODE_DISABLED  # stands still on the plane
	cam = PlayerCamera.new()
	cam.reads_input = false
	add_child(cam)
	body = PlayerBody.new()
	add_child(body)
	var movement := ContentDB.tuning("movement")
	var ok := motor.setup(movement) and cam.setup(motor, ContentDB.tuning("camera"))
	ok = (
		ok
		and body.setup(
			motor,
			cam,
			body_scene,
			clips,
			movement,
			ContentDB.tuning("body"),
			(cust as Dictionary).get("head_segments", []),
			(cust as Dictionary).get("head_meshes", [])
		)
	)
	if not ok:
		errors.append_array(motor.errors + cam.errors + body.errors)
		return false
	cam.current = true
	return true


## Renders one frame after the scene settles; saves it under `dir` when set.
func shot(frame_name: String, dir: String, settle_frames := 4) -> Image:
	for i in settle_frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if dir != "":
		img.save_png(dir.path_join(frame_name + ".png"))
	return img


## Command-line pairs "--key value" after "--".
static func args() -> Dictionary:
	var out := {}
	var a := OS.get_cmdline_user_args()
	for i in range(0, a.size() - 1):
		if a[i].begins_with("--"):
			out[a[i].substr(2)] = a[i + 1]
	return out


## Pixels whose colour passes `test` (a Callable(Color) -> bool).
static func count(img: Image, test: Callable) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if test.call(img.get_pixel(x, y)):
				n += 1
	return n
