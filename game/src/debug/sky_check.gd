extends Node3D
## T-08-7 and the blend half of the sky: renders reference frames of the sky
## (SkyDome + SkyLights on the content's clock and sky tuning) at the listed
## clock times, counts engine errors while doing so, and checks that the
## shader's blend between two minutes lines up with ShaderClock.
## Needs a display:
##   tools/godot.sh res://scenes/debug/sky_check.tscn [--rendering-method mobile] \
##       -- [--times HH:MM,...] [--day 1] [--radiance 128] [--out <abs dir>]
## Prints one line per frame (with the longest frame while it settled),
## then RESULT PASS or FAIL (exit code 0 or 1).

const DEFAULT_TIMES := "00:00,03:00,06:00,09:00,12:00,15:00,18:00,21:00"
const SETTLE_FRAMES := 40
const FOV_DEG := 70.0
## The blend test: two zenith colours BLEND_S apart, read halfway.
const BLEND_S := 4.0
const BLEND_TOL := 0.1


class ErrorCount:
	extends Logger
	var errors := 0
	var first := ""

	func _log_error(
		function: String,
		file: String,
		line: int,
		code: String,
		rationale: String,
		_editor_notify: bool,
		error_type: int,
		_script_backtraces: Array[ScriptBacktrace]
	) -> void:
		if error_type == ERROR_TYPE_WARNING:
			return
		errors += 1
		if first == "":
			first = "%s (%s:%d %s) %s" % [code, file, line, function, rationale]

	func _log_message(_message: String, _error: bool) -> void:
		pass


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		printerr("sky check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var log := ErrorCount.new()
	OS.add_logger(log)
	var clock := GameClock.new()
	add_child(clock)
	clock.configure(ContentDB.tuning("clock"))
	clock.paused = true
	var lights := SkyLights.new()
	add_child(lights)
	var dome := SkyDome.new()
	add_child(dome)
	var radiance := int(_arg(args, "--radiance", "128"))
	if not lights.setup(clock, ContentDB.tuning("sky")) or not dome.setup(clock, lights, radiance):
		printerr("sky check: %s" % ", ".join(lights.errors + dome.errors))
		get_tree().quit(2)
		return
	var cam := Camera3D.new()
	cam.fov = FOV_DEG
	cam.position = Vector3(0.0, 1.6, 0.0)
	add_child(cam)
	cam.make_current()
	_add_props(cam)
	var vp := get_viewport()
	var out := _arg(args, "--out", "")
	var method := RenderingServer.get_current_rendering_method()
	var day := int(_arg(args, "--day", "1"))
	var bad := 0
	for t: String in _arg(args, "--times", DEFAULT_TIMES).split(",", false):
		var hm := t.split(":")
		var gmin := (day - 1) * GameClock.GMIN_PER_DAY + int(hm[0]) * 60 + int(hm[1])
		clock.set_now(gmin)
		lights.apply(gmin)
		dome.show_minute(int(gmin))
		dome.show_minute(int(gmin))  # prev = next: no blend in the frame
		var hours := gmin / 60.0
		var sun_e := clock.sun_elevation_deg(fmod(hours, 24.0))
		var p := clock.moon_phase(gmin)
		var az := (
			clock.sun_azimuth_deg(fmod(hours, 24.0))
			if sun_e > -6.0
			else clock.moon_azimuth_deg(fmod(hours, 24.0), p)
		)
		cam.basis = Basis.from_euler(Vector3(deg_to_rad(12.0), deg_to_rad(-az), 0.0))
		var longest := 0.0
		for f in SETTLE_FRAMES:
			var t0 := Time.get_ticks_usec()
			await RenderingServer.frame_post_draw
			longest = maxf(longest, (Time.get_ticks_usec() - t0) / 1000.0)
		var img := vp.get_texture().get_image()
		var top := img.get_pixel(img.get_width() / 2, 2)
		print(
			(
				"%s sun %.1f deg, moon phase %.2f, facing %.0f deg: zenith-ward pixel %s, longest frame %.1f ms"
				% [t, sun_e, p, az, top.to_html(false), longest]
			)
		)
		if out != "":
			DirAccess.make_dir_recursive_absolute(out)
			img.save_png(out.path_join("sky_%s_%s.png" % [method, t.replace(":", "")]))
	await ShaderClock.measure(self)
	var w := await _blend_halfway(dome, cam, vp, float(_arg(args, "--blend-s", str(BLEND_S))))
	var blend_ok := absf(w - 0.5) <= BLEND_TOL
	bad += int(not blend_ok)
	print("blend halfway: %.3f (want 0.5 +- %.2f)%s" % [w, BLEND_TOL, "" if blend_ok else "  FAIL"])
	OS.remove_logger(log)
	bad += int(log.errors > 0)
	print(
		(
			"engine errors: %d%s"
			% [log.errors, "" if log.errors == 0 else "  FAIL (first: %s)" % log.first]
		)
	)
	print("RESULT %s (%s, radiance %d)" % ["PASS" if bad == 0 else "FAIL", method, radiance])
	get_tree().quit(0 if bad == 0 else 1)


## Sets the zenith to blend from black to white over BLEND_S seconds,
## starting BLEND_S / 2 before now (ShaderClock), and returns the linear
## zenith value seen straight up (0.5 when the clocks agree).
func _blend_halfway(dome: SkyDome, cam: Camera3D, vp: Viewport, blend_s: float) -> float:
	var m := dome.material
	m.set_shader_parameter("prev_zenith", Color.BLACK)
	m.set_shader_parameter("next_zenith", Color.WHITE)
	for key: String in ["prev_sun_dir", "next_sun_dir", "prev_moon_dir", "next_moon_dir"]:
		m.set_shader_parameter(key, Vector3.DOWN)
	m.set_shader_parameter("prev_stars", 0.0)
	m.set_shader_parameter("next_stars", 0.0)
	cam.basis = Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	await RenderingServer.frame_post_draw
	m.set_shader_parameter("blend_s", blend_s)
	m.set_shader_parameter("blend_t0", ShaderClock.now() - blend_s * 0.5)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	return img.get_pixel(img.get_width() / 2, img.get_height() / 2).srgb_to_linear().r


## A ground plane, and a chrome ball in front of the camera that shows the
## sky's reflection (the radiance map).
func _add_props(cam: Camera3D) -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	var grey := StandardMaterial3D.new()
	grey.albedo_color = Color(0.35, 0.37, 0.33)
	ground.material_override = grey
	add_child(ground)
	var ball := MeshInstance3D.new()
	ball.mesh = SphereMesh.new()
	var chrome := StandardMaterial3D.new()
	chrome.metallic = 1.0
	chrome.roughness = 0.15
	ball.material_override = chrome
	ball.position = Vector3(1.2, -0.9, -4.0)
	cam.add_child(ball)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
