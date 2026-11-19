extends SceneTree
## Spike P1-06, fire part: flame cards with an eroding-noise shader, ember
## particles and a flickering omni light, on both renderers.
## Checks: the flame shows a white-yellow core and red tips; leaning with a
## world wind direction moves the flame top downwind; embers are drawn above
## the flame; the light energy stays within base ±25 % and is not constant.
## Reports the frame time with the fire on and off.
## Needs a display. Prints RESULT PASS / FAIL. SPIKE_OUT names a folder for
## one PNG per renderer (default: user://).

const HEIGHT := 0.7
const CARDS := 3
const EMBERS := 80
const LIGHT_COLOR := Color("ff7a2a")
const LIGHT_RANGE := 9.0
const LIGHT_ENERGY := 3.0
const FAST_AMP := 0.15
const FAST_HZ := 10.0
const SLOW_AMP := 0.10
const SLOW_HZ := 1.0

var _fast := FastNoiseLite.new()
var _slow := FastNoiseLite.new()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_fast.seed = 1
	_slow.seed = 2
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0, 0, 0)
	env.environment.ambient_light_color = Color(0.02, 0.02, 0.03)
	root.add_child(env)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.22, 0.2)
	plane.material = gm
	ground.mesh = plane
	root.add_child(ground)
	var fire := Node3D.new()
	root.add_child(fire)
	var mat := await _flame_material()
	for i in CARDS:
		var card := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(HEIGHT * 0.7, HEIGHT)
		q.material = mat
		card.mesh = q
		card.position = Vector3(0, HEIGHT * 0.5, 0)
		card.rotation.y = PI * i / CARDS
		fire.add_child(card)
	var embers := _embers()
	fire.add_child(embers)
	var light := OmniLight3D.new()
	light.light_color = LIGHT_COLOR
	light.omni_range = LIGHT_RANGE
	light.light_energy = LIGHT_ENERGY
	light.shadow_enabled = true
	light.position = Vector3(0, HEIGHT * 0.6, 0)
	fire.add_child(light)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 0.9, 2.2), Vector3(0, 0.6, 0))
	for f in 90:
		await process_frame
		light.light_energy = _flicker(Time.get_ticks_msec() / 1000.0)

	var img := await _grab()
	var out := OS.get_environment("SPIKE_OUT")
	img.save_png(
		(out if out != "" else "user://").path_join(
			"fire_%s.png" % RenderingServer.get_current_rendering_method()
		)
	)
	# Measure on frames without the lit ground (it is orange too).
	ground.visible = false
	light.visible = false
	img = await _grab()
	var flame_rect := _screen_rect(cam, Vector3(-0.4, 0.0, 0), Vector3(0.4, HEIGHT, 0), img)
	var core := _count(img, flame_rect, func(c: Color) -> bool: return c.r > 0.95 and c.g > 0.8)
	var tips := _count(
		img, flame_rect, func(c: Color) -> bool: return c.r > 0.3 and c.g < 0.5 * c.r and c.b < 0.2
	)
	var above := _screen_rect(cam, Vector3(-1, HEIGHT + 0.1, 0), Vector3(1, 2.5, 0), img)
	var ember_px := _count(
		img, above, func(c: Color) -> bool: return c.r > 0.5 and c.g < 0.8 * c.r and c.b < 0.3
	)
	var x_calm := _top_centroid_x(img, flame_rect)
	mat.set_shader_parameter("lean", 0.35)
	var img_lean := await _grab()
	var x_lean := _top_centroid_x(img_lean, flame_rect)
	mat.set_shader_parameter("lean", 0.0)
	ground.visible = true
	light.visible = true

	var energies: Array[float] = []
	for i in 600:  # 10 s sampled at 60 Hz
		energies.append(_flicker(i / 60.0))
	var e_min: float = energies.min()
	var e_max: float = energies.max()
	var flicker_ok := (
		e_min >= LIGHT_ENERGY * 0.75
		and e_max <= LIGHT_ENERGY * 1.25
		and e_max - e_min > LIGHT_ENERGY * 0.1
	)

	var on := await _frame_times(light, 240)
	fire.visible = false
	var off := await _frame_times(null, 240)
	fire.visible = true

	print(
		(
			"%s / %s: core px %d, red tip px %d, ember px %d, top centroid x calm %.1f lean %.1f"
			% [
				RenderingServer.get_current_rendering_method(),
				RenderingServer.get_video_adapter_name(),
				core,
				tips,
				ember_px,
				x_calm,
				x_lean
			]
		)
	)
	print(
		(
			"light energy %.2f..%.2f (base %.2f); frame median fire on %.2f ms, off %.2f ms"
			% [e_min, e_max, LIGHT_ENERGY, on, off]
		)
	)
	var ok := core > 50 and tips > 50 and ember_px > 5 and x_lean > x_calm + 3.0 and flicker_ok
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


## Light energy: base × (1 + 15 % noise at 10 Hz + 10 % noise at 1 Hz).
func _flicker(t: float) -> float:
	var fast := _fast.get_noise_1d(t * FAST_HZ * 100.0)
	var slow := _slow.get_noise_1d(t * SLOW_HZ * 100.0)
	return LIGHT_ENERGY * (1.0 + FAST_AMP * clampf(fast, -1, 1) + SLOW_AMP * clampf(slow, -1, 1))


func _flame_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/spikes/fire/flame.gdshader")
	for k: String in ["noise_a", "noise_b"]:
		var tex := NoiseTexture2D.new()
		tex.width = 128
		tex.height = 128
		tex.seamless = true
		tex.noise = FastNoiseLite.new()
		tex.noise.seed = 11 if k == "noise_a" else 23
		await tex.changed
		mat.set_shader_parameter(k, tex)
	mat.set_shader_parameter("flame_height", HEIGHT)
	return mat


func _embers() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = EMBERS
	p.lifetime = 2.0
	p.preprocess = 2.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.15
	pm.direction = Vector3.UP
	pm.spread = 15.0
	pm.initial_velocity_min = 0.6
	pm.initial_velocity_max = 1.2
	pm.gravity = Vector3(0.2, 0.3, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 2.0
	pm.turbulence_influence_min = 0.05
	pm.turbulence_influence_max = 0.15
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.025, 0.025)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.0, 0.45, 0.1)
	q.material = m
	p.draw_pass_1 = q
	p.position = Vector3(0, HEIGHT * 0.5, 0)
	return p


func _grab() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _frame_times(light: OmniLight3D, frames: int) -> float:
	var times: Array[float] = []
	var last := Time.get_ticks_usec()
	for f in frames:
		await process_frame
		if light:
			light.light_energy = _flicker(Time.get_ticks_msec() / 1000.0)
		var now := Time.get_ticks_usec()
		times.append((now - last) / 1000.0)
		last = now
	times.sort()
	return times[times.size() / 2]


## Screen rectangle of two world points, in image pixels. unproject_position
## returns logical viewport units (the stretch base size), not window pixels.
func _screen_rect(cam: Camera3D, a: Vector3, b: Vector3, img: Image) -> Rect2i:
	var k := Vector2(img.get_size()) / root.get_visible_rect().size
	var pa := cam.unproject_position(a) * k
	var pb := cam.unproject_position(b) * k
	var r := Rect2(pa, Vector2.ZERO).expand(pb)
	return Rect2i(r).intersection(Rect2i(Vector2i.ZERO, img.get_size()))


func _count(img: Image, rect: Rect2i, pred: Callable) -> int:
	var n := 0
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if pred.call(img.get_pixel(x, y)):
				n += 1
	return n


## Mean x of bright pixels in the upper half of the rectangle widened by
## its own width on both sides (the leaning top may leave it).
func _top_centroid_x(img: Image, rect: Rect2i) -> float:
	var wide := (
		Rect2i(rect.position - Vector2i(rect.size.x, 0), Vector2i(rect.size.x * 3, rect.size.y / 2))
		. intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	)
	var sum := 0.0
	var n := 0
	for y in range(wide.position.y, wide.end.y):
		for x in range(wide.position.x, wide.end.x):
			var c := img.get_pixel(x, y)
			if c.r > 0.3 and c.b < 0.3:
				sum += x
				n += 1
	return sum / n if n > 0 else 0.0
