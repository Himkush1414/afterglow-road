extends TestCase
## MirrorSystem (10 §3.1): only the nearest mirror in range, facing the eye
## and in view is live; moving swaps it; facing away, out of range, out of
## view and shattered mirrors never are; mirror cameras get a cheap
## environment copy.

var _root: Node3D
var _cam: Camera3D
var _system: MirrorSystem


func before_each() -> void:
	_root = Node3D.new()
	tree.root.add_child(_root)
	_cam = Camera3D.new()
	_root.add_child(_cam)
	_cam.current = true
	_system = MirrorSystem.new()
	_root.add_child(_system)


func after_each() -> void:
	_root.free()


## A mirror at `pos` whose front faces `facing` (a direction).
func _mirror(pos: Vector3, facing: Vector3) -> Mirror:
	var m := Mirror.new()
	_root.add_child(m)
	m.configure(ContentDB.tuning("mirror"), 64, 60.0, false)
	m.global_transform = Transform3D(Basis.looking_at(-facing, Vector3.UP), pos)
	_system.add_mirror(m)
	return m


func _setup(env: Environment = null) -> bool:
	return check(_system.setup(_cam, ContentDB.tuning("mirror"), env), ", ".join(_system.errors))


func test_only_the_nearer_mirror_is_live_and_they_swap() -> void:
	if not _setup():
		return
	# camera at the origin looking -Z; two mirrors ahead facing it
	var near := _mirror(Vector3(-0.5, 0, -2), Vector3.BACK)
	var far := _mirror(Vector3(0.5, 0, -4), Vector3.BACK)
	_system.update(1.0 / 60.0)
	check(_system.live == near and near.live and not far.live, "the nearer is live")
	_cam.global_position = Vector3(0.5, 0, -3)  # walk forward: now 1 m from the far one
	_system.update(1.0 / 60.0)
	check(_system.live == far and far.live and not near.live, "walking past swaps them")


func test_rejected_mirrors() -> void:
	if not _setup():
		return
	var range_m := float(ContentDB.tuning("mirror").live_range_m)
	var away := _mirror(Vector3(0, 0, -2), Vector3.FORWARD)  # front faces away
	var distant := _mirror(Vector3(0, 0, -(range_m + 1.0)), Vector3.BACK)
	var behind := _mirror(Vector3(0, 0, 2), Vector3.FORWARD)  # faces the eye, behind the view
	_system.update(1.0 / 60.0)
	check(_system.live == null, "facing away, out of range, out of view: none live")
	check(not (away.live or distant.live or behind.live), "all dull")
	var ok := _mirror(Vector3(0, 0, -3), Vector3.BACK)
	ok.hit()
	ok.hit()
	_system.update(1.0 / 60.0)
	check(_system.live == null, "a shattered mirror is never live")


func test_live_camera_follows_the_eye() -> void:
	if not _setup():
		return
	var m := _mirror(Vector3(0, 0, -2), Vector3.BACK)
	_system.update(1.0 / 60.0)
	var first := m.camera.global_position
	_cam.global_position = Vector3(0.3, 0.2, -0.5)
	_system.update(1.0 / 60.0)
	var want := Vector3(0.3, 0.2, -3.5)  # the eye mirrored in the plane z = -2
	check_near(m.camera.global_position.distance_to(want), 0.0, 1e-4, "camera at the mirrored eye")
	check(first.distance_to(m.camera.global_position) > 0.1, "moved with the eye")


func test_cheap_environment() -> void:
	var env := Environment.new()
	env.ssao_enabled = true
	env.ssil_enabled = true
	env.volumetric_fog_enabled = true
	env.glow_enabled = true
	env.fog_enabled = true
	if not _setup(env):
		return
	var m := _mirror(Vector3(0, 0, -2), Vector3.BACK)
	var e := m.camera.environment
	check(e != null and e != env, "own copy")
	check(
		not (e.ssao_enabled or e.ssil_enabled or e.volumetric_fog_enabled or e.glow_enabled),
		"cheap"
	)
	check(e.fog_enabled, "plain fog kept")
	check(env.ssao_enabled and env.glow_enabled, "world environment unchanged")
