extends Node3D
## Rain ripples on water (08 §4.5): a still water plane with both water
## shaders (phone and desktop) and the base waves frozen (wind 0) is seen
## from above under a low sun. Two dry frames must be the same; with full
## rain the surface must change (ripples); the ripple share follows the
## intensity (half rain changes less than full rain).
## Needs a display:
##   tools/godot.sh res://scenes/debug/ripple_check.tscn [--rendering-method mobile] \
##       -- [--out <dir>]
## Prints one line per shader, then RESULT PASS or FAIL (exit 0 or 1).

const SHADERS := ["res://shaders/water.gdshader", "res://shaders/water_desktop.gdshader"]
const MIN_CHANGE := 0.004

var _out := ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("ripple check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	_out = args[i + 1] if i >= 0 and i + 1 < args.size() else ""
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.6, 0.7, 0.8)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.3, 0.3, 0.3)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-20.0, 30.0, 0.0)
	add_child(sun)
	var rain := Rain.new()
	add_child(rain)
	if not rain.configure(ContentDB.tuning("rain")):
		printerr("ripple check: %s" % ", ".join(rain.errors))
		get_tree().quit(2)
		return
	var plane := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(40.0, 40.0)
	plane.mesh = mesh
	plane.position = Vector3(0.0, 5.0, 0.0)
	add_child(plane)
	var cam := Camera3D.new()
	add_child(cam)
	cam.look_at_from_position(Vector3(0.0, 12.0, 6.0), Vector3(0.0, 5.0, 0.0))
	cam.make_current()
	var bad := 0
	for path: String in SHADERS:
		var mat := ShaderMaterial.new()
		mat.shader = load(path)
		mat.set_shader_parameter("wind_speed", 0.0)
		plane.material_override = mat
		rain.set_from_weather({"rain": 0.0})
		var dry_a := await _frame("dry", path)
		var dry_b := await _frame("dry2", path)
		rain.set_from_weather({"rain": 0.5})
		var half := await _frame("half", path)
		rain.set_from_weather({"rain": 1.0})
		var wet := await _frame("wet", path)
		var still := _diff(dry_a, dry_b)
		var d_half := _diff(dry_a, half)
		var d_wet := _diff(dry_a, wet)
		var ok := still < MIN_CHANGE * 0.1 and d_wet > MIN_CHANGE and d_half < d_wet
		bad += int(not ok)
		print(
			(
				"%s: dry vs dry %.5f, half rain %.5f, full rain %.5f%s"
				% [path.get_file(), still, d_half, d_wet, "" if ok else "  FAIL"]
			)
		)
	rain.set_from_weather({"rain": 0.0})
	var method := RenderingServer.get_current_rendering_method()
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)


func _frame(tag: String, path: String) -> Image:
	for f in 20:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if _out != "":
		var method := RenderingServer.get_current_rendering_method()
		img.save_png(
			_out.path_join("ripple_%s_%s_%s.png" % [path.get_file().get_basename(), tag, method])
		)
	return img


## Mean absolute difference of the red channel over every fourth pixel.
static func _diff(a: Image, b: Image) -> float:
	var sum := 0.0
	var n := 0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			sum += absf(a.get_pixel(x, y).r - b.get_pixel(x, y).r)
			n += 1
	return sum / maxf(n, 1)
