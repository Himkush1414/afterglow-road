extends TestCase
## Mirror (10 §3.2): the near rectangle of the mirror camera is the quad for
## any eye in front (corners at the view's corners, left-right swapped),
## near plane floor, viewport size and aspect, cull mask, update rate, and
## the live / crack states.

var _root: Node3D
var _mirror: Mirror


func before_each() -> void:
	_root = Node3D.new()
	tree.root.add_child(_root)
	_mirror = Mirror.new()
	_mirror.width_m = 0.6
	_mirror.height_m = 1.2
	_root.add_child(_mirror)


func after_each() -> void:
	_root.free()


func _setup(size := 256, hz := 60.0) -> bool:
	return check(
		_mirror.configure(ContentDB.tuning("mirror"), size, hz, false), ", ".join(_mirror.errors)
	)


## Normalised device coordinates of `p` seen by the mirror camera.
func _ndc(p: Vector3) -> Vector2:
	var cam := _mirror.camera
	var clip := (
		cam.get_camera_projection()
		* Vector4(
			(cam.global_transform.affine_inverse() * p).x,
			(cam.global_transform.affine_inverse() * p).y,
			(cam.global_transform.affine_inverse() * p).z,
			1.0
		)
	)
	return Vector2(clip.x, clip.y) / clip.w


func test_refuses_missing_keys() -> void:
	check(not _mirror.configure({}, 256, 60.0, false), "refused")
	check(_mirror.errors.size() >= 4, "names each key")


func test_near_rectangle_is_the_quad() -> void:
	if not _setup():
		return
	_mirror.global_transform = Transform3D(
		Basis.from_euler(Vector3(0.1, 0.7, 0.0)), Vector3(2, 1.5, -3)
	)
	var a := _mirror.axes()
	var n := a[0]
	var r := a[1]
	var u := a[2]
	var c := _mirror.global_position
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	for trial in 10:
		var eye := (
			c
			+ n * rng.randf_range(0.3, 4.0)
			+ r * rng.randf_range(-2.0, 2.0)
			+ u * rng.randf_range(-1.0, 1.0)
		)
		_mirror.place_camera(eye)
		# the quad's right edge (+r) appears on the left of the reflection
		var corners := {
			Vector2(-1, 1): c + r * 0.3 + u * 0.6,
			Vector2(1, 1): c - r * 0.3 + u * 0.6,
			Vector2(-1, -1): c + r * 0.3 - u * 0.6,
			Vector2(1, -1): c - r * 0.3 - u * 0.6,
		}
		for want: Vector2 in corners:
			worst = maxf(worst, (_ndc(corners[want]) - want).length())
	check(worst < 1e-3, "quad corners on the view corners (worst %s)" % worst)


func test_near_plane_floor() -> void:
	if not _setup():
		return
	var n := _mirror.axes()[0]
	_mirror.place_camera(_mirror.global_position + n * 0.02)
	check_near(_mirror.camera.near, Mirror.MIN_NEAR_M, 1e-6, "near never below the floor")
	_mirror.place_camera(_mirror.global_position + n * 1.5)
	check_near(_mirror.camera.near, 1.5, 1e-5, "near = distance")


func test_viewport_size_and_masks() -> void:
	if not _setup(256):
		return
	check_eq(_mirror.viewport.size, Vector2i(128, 256), "tall mirror keeps its aspect")
	check_eq(Mirror.viewport_size(256, 1.2, 0.6), Vector2i(256, 128), "wide mirror")
	var surface_bit := 1 << (Mirror.SURFACE_LAYER - 1)
	check_eq(_mirror.surface.layers, surface_bit, "surface on the mirror layer")
	check_eq(_mirror.camera.cull_mask & surface_bit, 0, "camera skips mirror surfaces")
	check(_mirror.camera.cull_mask & PlayerBody.head_layer_mask() != 0, "camera sees the head")
	check(_mirror.camera.cull_mask & 1 != 0, "camera sees the world")
	check_near(_mirror.camera.far, float(ContentDB.tuning("mirror").far_desktop_m), 1e-6, "far")


func test_update_rate() -> void:
	if not _setup(256, 15.0):
		return
	var eye := _mirror.global_position + _mirror.axes()[0]
	check_eq(
		_mirror.viewport.render_target_update_mode, SubViewport.UPDATE_DISABLED, "dull: no render"
	)
	_mirror.set_live(true)
	var renders := 0
	for i in 60:  # one second at 60 frames per second
		_mirror.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_mirror.update_view(eye, 1.0 / 60.0)
		if _mirror.viewport.render_target_update_mode == SubViewport.UPDATE_ONCE:
			renders += 1
	check(renders >= 14 and renders <= 16, "about 15 renders a second: %d" % renders)
	var every := Mirror.new()
	_root.add_child(every)
	every.configure(ContentDB.tuning("mirror"), 256, 60.0, false)
	every.set_live(true)
	every.update_view(eye, 1.0 / 60.0)
	check_eq(every.viewport.render_target_update_mode, SubViewport.UPDATE_ALWAYS, "every frame")


func test_crack_states() -> void:
	if not _setup():
		return
	var cfg := ContentDB.tuning("mirror")
	_mirror.set_live(true)
	_mirror.impact(float(cfg.crack_impact_j) - 1.0)
	check_eq(_mirror.state, Mirror.State.INTACT, "a light impact does nothing")
	_mirror.impact(float(cfg.crack_impact_j))
	check_eq(_mirror.state, Mirror.State.CRACKED, "impact at the threshold cracks")
	check(_mirror.live, "a cracked mirror stays live")
	var mat := _mirror.surface.material_override as ShaderMaterial
	check(mat.get_shader_parameter("cracked"), "crack overlay on")
	_mirror.hit()
	check_eq(_mirror.state, Mirror.State.SHATTERED, "second hit shatters")
	check(not _mirror.live and not _mirror.surface.visible, "shattered: no surface, not live")
	_mirror.set_live(true)
	check(not _mirror.live, "never live again")
