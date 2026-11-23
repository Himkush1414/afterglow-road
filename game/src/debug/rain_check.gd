extends Node3D
## Rain volume and splashes (08 §4.5, A-17): the game's Rain volume (content
## tuning, preset streak count) falls on an open-sided room with a 6 x 6 m
## roof 3 m up. Each bright pixel is projected to the floor.
## With collisions (default on Forward+): from an eye under the roof, rain
## seen over the floor under the roof stays at most 1/200 of the rain seen
## outside it (calm and with wind); splashes alone: none under the roof;
## then from an eye 5 m up outside the roof (reached by moving the camera,
## so the height field must follow it), none past the splash radius.
## Fallback (default on Mobile): under the roof nothing is drawn; from the
## eye 5 m up outside, rain is drawn and splashes lie within the radius.
## Needs a display:
##   tools/godot.sh res://scenes/debug/rain_check.tscn [--rendering-method mobile] \
##       -- [--collide | --fallback] [--streaks 3000] [--out <dir>]
## Prints one line per part, then RESULT PASS or FAIL (exit 0 or 1).

const ROOF_HALF := 3.0
const MARGIN := 0.4
const WINDS := [0.0, 8.0]
const UNDER := [Vector3(-2.0, 1.6, 0.0), Vector3(4.0, 0.0, 0.0)]
const HIGH := [Vector3(10.0, 5.0, 0.0), Vector3(16.0, 0.0, 0.0)]

var _cam: Camera3D
var _out := ""
var _bad := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		printerr("rain check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color.BLACK
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 1.2
	add_child(env)
	add_child(_box(Vector3(0, -0.05, 0), Vector3(60, 0.1, 60)))
	add_child(_box(Vector3(0, 3.0, 0), Vector3(ROOF_HALF * 2.0, 0.2, ROOF_HALF * 2.0)))
	add_child(_roof_body())
	var wind := Wind.new()
	add_child(wind)
	wind.configure(ContentDB.tuning("wind"))
	wind.set_process(false)
	wind.gust = 0.0
	var rain := Rain.new()
	add_child(rain)
	if not rain.configure(ContentDB.tuning("rain")):
		printerr("rain check: %s" % ", ".join(rain.errors))
		get_tree().quit(2)
		return
	var method := RenderingServer.get_current_rendering_method()
	var collide := method == "forward_plus"
	if "--collide" in args:
		collide = true
	elif "--fallback" in args:
		collide = false
	rain.wind = wind
	rain.ground_of = func(_p: Vector3) -> float: return 0.0
	rain.intensity = 1.0
	rain.build_volume(int(_arg(args, "--streaks", "3000")), collide)
	var mat := (rain.particles.draw_pass_1 as QuadMesh).material as ShaderMaterial
	mat.set_shader_parameter("alpha", 1.0)  # full streaks so they read as bright pixels
	var smat := (rain.splashes.draw_pass_1 as QuadMesh).material as ShaderMaterial
	_cam = Camera3D.new()
	_cam.fov = 100.0
	add_child(_cam)
	_out = _arg(args, "--out", "")
	_view(UNDER)
	_cam.make_current()
	print("mode: %s" % ("collisions" if collide else "fallback"))
	if collide:
		for w: float in WINDS:
			wind.dir = Vector2(0.0, 1.0)  # across the view, so slanted drops pass the roof edge
			wind.base = w
			rain.particles.restart()
			var c := await _shots("rain_w%d" % int(w), Vector3.ZERO, INF)
			_report(
				c.z > 200 and c.x <= c.z / 200,
				"wind %.0f m/s: rain over the floor outside %d, under the roof %d" % [w, c.z, c.x]
			)
	else:
		var c := await _shots("rain_under", Vector3.ZERO, INF)
		_report(
			c == Vector3i.ZERO and not rain.particles.visible,
			"under the roof: drawn %s, bright points %d" % [rain.particles.visible, c.x + c.z]
		)
		_view(HIGH)
		c = await _shots("rain_high", Vector3.ZERO, INF)
		_report(c.z > 200 and rain.particles.visible, "outside: rain over the floor %d" % c.z)
	# Splashes alone (streaks hidden). The high eye keeps a droplet's height
	# from stretching its floor point outward.
	mat.set_shader_parameter("alpha", 0.0)
	smat.set_shader_parameter("alpha", 1.0)
	wind.base = 0.0
	var rcfg := ContentDB.tuning("rain")
	var radius := float(rcfg.splash_radius_m)
	# Highest a droplet is drawn: start (one drop step after the bounce of a
	# splash drop), rise and size.
	var start := 0.0
	if collide:
		start = float(rcfg.fall_ms) * float(rcfg.splash_bounce) / rain.splash_drops.fixed_fps
	var rise := start + pow(float(rcfg.splash_speed_ms), 2.0) / 19.6 + float(rcfg.splash_size_m)
	if collide:
		_view(UNDER)
		var c := await _shots("splash_under", Vector3.ZERO, INF)
		_report(
			c.z > 50 and c.x == 0,
			"splashes from under the roof: seen %d, under the roof %d" % [c.z, c.x]
		)
	_view(HIGH)
	var eye: Vector3 = HIGH[0]
	var reach := radius * eye.y / (eye.y - rise) + 0.25
	var s := await _shots("splash_high", eye, reach)
	_report(
		s.z > 50 and s.y == 0,
		"splashes from 5 m up: near %d, past %.1f m (radius %.0f m) %d" % [s.z, reach, radius, s.y]
	)
	print("RESULT %s (%s)" % ["PASS" if _bad == 0 else "FAIL", method])
	get_tree().quit(0 if _bad == 0 else 1)


func _view(v: Array) -> void:
	_cam.look_at_from_position(v[0], v[1])


## Waits 60 frames, then counts the floor points of 5 frames: x under the
## roof; y farther than a finite `reach` from `eye`; z the rest.
func _shots(tag: String, eye: Vector3, reach: float) -> Vector3i:
	for f in 60:
		await get_tree().process_frame
	var res := Vector3i.ZERO
	for shot in 5:
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		if shot == 0 and _out != "":
			var method := RenderingServer.get_current_rendering_method()
			img.save_png(_out.path_join("%s_%s.png" % [tag, method]))
		for p: Vector3 in _floor_points(img):
			if absf(p.x) < ROOF_HALF - MARGIN and absf(p.z) < ROOF_HALF - MARGIN:
				res.x += 1
			elif is_finite(reach) and Vector2(p.x, p.z).distance_to(Vector2(eye.x, eye.z)) > reach:
				res.y += 1
			else:
				res.z += 1
	return res


func _report(ok: bool, line: String) -> void:
	_bad += int(not ok)
	print("%s%s" % [line, "" if ok else "  FAIL"])


## Floor points (y 0) behind every second bright pixel below the horizon.
func _floor_points(img: Image) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			if img.get_pixel(x, y).r < 0.4:
				continue
			var o := _cam.project_ray_origin(Vector2(x, y))
			var d := _cam.project_ray_normal(Vector2(x, y))
			if d.y < -0.01:
				pts.append(o + d * (-o.y / d.y))
	return pts


func _box(pos: Vector3, size: Vector3) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.04, 0.04)
	b.material = mat
	m.mesh = b
	m.position = pos
	return m


## The roof as a static world body (layer 2) for rain exposure.
func _roof_body() -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = 1 << 1
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(ROOF_HALF * 2.0, 0.2, ROOF_HALF * 2.0)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0.0, 3.0, 0.0)
	return body


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
