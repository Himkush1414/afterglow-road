extends Node3D
## Fog visibility (P4-05): for each listed visibility V, SkyDome sets the fog
## and a black unshaded target at V / 3 is rendered against a white fog
## colour (linear tone mapping, no glow). The fog amount f there gives the
## visibility the render implies, V' = V × k / (3 × −ln(1 − f)), which must be
## within TOL of V. (At V itself only 5% of the contrast is left, below what
## 8-bit pixels measure well; at V / 3, 37% is left.)
## Needs a display:
##   tools/godot.sh res://scenes/debug/fog_check.tscn [--rendering-method mobile] \
##       -- [--vis 10000,1000,100]
## Prints one line per visibility, then RESULT PASS or FAIL (exit 0 or 1).

const TOL := 0.1
const SETTLE_FRAMES := 8


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		printerr("fog check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var clock := GameClock.new()
	add_child(clock)
	clock.configure(ContentDB.tuning("clock"))
	clock.paused = true
	var lights := SkyLights.new()
	add_child(lights)
	var dome := SkyDome.new()
	add_child(dome)
	var env_cfg := ContentDB.tuning("environment")
	if (
		not lights.setup(clock, ContentDB.tuning("sky"))
		or not dome.setup(clock, lights, 128, env_cfg)
	):
		printerr("fog check: %s" % ", ".join(lights.errors + dome.errors))
		get_tree().quit(2)
		return
	var noon := int(float(ContentDB.tuning("clock").solar_noon_h) * 60.0)
	clock.set_now(noon)
	var cam := Camera3D.new()
	cam.far = 50000.0
	cam.position = Vector3(0.0, 2.0, 0.0)
	add_child(cam)
	cam.make_current()
	var target := MeshInstance3D.new()
	target.mesh = QuadMesh.new()
	var black := StandardMaterial3D.new()
	black.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	black.albedo_color = Color.BLACK
	target.material_override = black
	add_child(target)
	var vp := get_viewport()
	var k := float(env_cfg.fog_k)
	var bad := 0
	for v: String in _arg(args, "--vis", "10000,1000,100").split(",", false):
		var vis := float(v)
		dome.visibility_m = vis
		dome.show_minute(noon)
		var env := dome.environment
		env.fog_light_color = Color.WHITE
		env.fog_height_density = 0.0
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		env.tonemap_exposure = 1.0
		env.glow_enabled = false
		var d := vis / 3.0
		target.position = Vector3(0.0, 2.0, -d)
		target.scale = Vector3.ONE * d * 0.2  # about 11° across
		for f in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2).srgb_to_linear()
		var fog := (c.r + c.g + c.b) / 3.0
		var implied := vis * k / (3.0 * -log(maxf(1.0 - fog, 1e-6)))
		var ok := absf(implied / vis - 1.0) <= TOL
		bad += int(not ok)
		print(
			(
				"visibility %.0f m: fog %.3f at %.0f m -> implied %.0f m (%+.1f%%)%s"
				% [vis, fog, d, implied, (implied / vis - 1.0) * 100.0, "" if ok else "  FAIL"]
			)
		)
	var method := RenderingServer.get_current_rendering_method()
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
