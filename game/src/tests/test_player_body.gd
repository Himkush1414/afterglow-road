extends TestCase
## PlayerBody on a synthetic rig (Hips, Chest, Head bones; a skin head, a
## skin chest and a garment chest mesh): head meshes only on the head layer
## and hidden from the camera, body shader materials (double-sided
## garments), camera-relative matrices free of world positions, placement at
## the motor with the view's yaw, chest pitch after the animation, head eye
## input, arm retract from the forward wall cast.

const DT := 1.0 / 60.0
const HEAD_SEGMENTS: Array = ["head"]

var _root: Node3D
var _motor: PlayerMotor
var _cam: PlayerCamera
var _body: PlayerBody


func before_each() -> void:
	_root = Node3D.new()
	tree.root.add_child(_root)
	_motor = PlayerMotor.new()
	_root.add_child(_motor)
	_cam = PlayerCamera.new()
	_cam.reads_input = false
	_root.add_child(_cam)
	_body = PlayerBody.new()
	_root.add_child(_body)


func after_each() -> void:
	_root.free()


func _rig_scene(with_head := true) -> PackedScene:
	var rig := Node3D.new()
	rig.name = "Rig"
	var skel := Skeleton3D.new()
	skel.name = "GeneralSkeleton"
	rig.add_child(skel)
	skel.owner = rig
	skel.unique_name_in_owner = true
	var bones := [["Hips", -1, Vector3(0, 1.0, 0)], ["Chest", 0, Vector3(0, 0.2, 0)]]
	if with_head:
		bones.append(["Head", 1, Vector3(0, 0.4, 0)])
	for b: Array in bones:
		var i := skel.get_bone_count()
		skel.add_bone(b[0])
		skel.set_bone_parent(i, b[1])
		skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, b[2]))
	skel.reset_bone_poses()
	for mesh_name: String in ["skin_head", "skin_chest", "shirt_chest"]:
		var m := MeshInstance3D.new()
		m.name = mesh_name
		m.mesh = BoxMesh.new()
		m.mesh.surface_set_material(0, StandardMaterial3D.new())
		skel.add_child(m)
		m.owner = rig
	var scene := PackedScene.new()
	scene.pack(rig)
	rig.free()
	return scene


func _library() -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for clip: String in PlayerAnimator.clip_names():
		var a := Animation.new()
		a.length = 0.5
		var t := a.add_track(Animation.TYPE_ROTATION_3D)
		a.track_set_path(t, NodePath("%GeneralSkeleton:Hips"))
		a.rotation_track_insert_key(t, 0.0, Quaternion.IDENTITY)
		lib.add_animation(clip, a)
	return lib


func _setup(with_head := true) -> bool:
	var movement := ContentDB.tuning("movement")
	if not check(_motor.setup(movement), ", ".join(_motor.errors)):
		return false
	if not check(_cam.setup(_motor, ContentDB.tuning("camera")), ", ".join(_cam.errors)):
		return false
	return _body.setup(
		_motor,
		_cam,
		_rig_scene(with_head),
		_library(),
		movement,
		ContentDB.tuning("body"),
		HEAD_SEGMENTS
	)


func _mesh(mesh_name: String) -> MeshInstance3D:
	return _body.rig.find_child(mesh_name, true, false) as MeshInstance3D


func test_refuses_a_rig_without_head() -> void:
	check(not _setup(false), "refused")
	check(not _body.errors.is_empty(), "names the problem")


func test_head_layer_hidden_from_the_camera() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	var head := PlayerBody.head_layer_mask()
	check_eq(_mesh("skin_head").layers, head, "head mesh only on the head layer")
	check_eq(_mesh("skin_chest").layers, 1, "body mesh on the default layer")
	check_eq(_mesh("shirt_chest").layers, 1, "garment on the default layer")
	check_eq(_cam.cull_mask & head, 0, "camera does not draw the head layer")
	check(_cam.cull_mask & 1 != 0, "camera still draws the default layer")


func test_body_shader_materials() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	var shirt := _mesh("shirt_chest").get_active_material(0) as ShaderMaterial
	var skin := _mesh("skin_chest").get_active_material(0) as ShaderMaterial
	if not check(shirt != null and skin != null, "body shader on every surface"):
		return
	check_eq(shirt.shader, PlayerBody.BODY_DOUBLE_SHADER, "garment draws both faces")
	check_eq(skin.shader, PlayerBody.BODY_SHADER, "skin culls back faces")
	check_eq(skin.get_shader_parameter("albedo"), Color.WHITE, "colour copied")


func test_view_local_is_camera_relative_and_origin_free() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	_cam.yaw = 0.4
	_cam.pitch = -0.3
	_motor.global_position = Vector3(1, 0.5, -2)
	_cam.update_view(DT)
	_body.update_body()
	var mesh := _mesh("skin_chest")
	var mat := mesh.get_active_material(0) as ShaderMaterial
	var near: Projection = mat.get_shader_parameter("view_local")
	var want := Projection(_cam.global_transform.affine_inverse() * mesh.global_transform)
	var err := 0.0
	for c in 4:
		err = maxf(err, (near[c] - want[c]).length())
	check(err < 1e-5, "equals camera-inverse x mesh near the origin (error %s)" % err)
	_motor.global_position = Vector3(4090, 300, 4090)  # the map corner
	_cam.update_view(DT)
	_body.update_body()
	var far: Projection = mat.get_shader_parameter("view_local")
	check(far == near, "bit-identical at the map corner")


func test_follows_the_motor_with_the_view_yaw() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	check(_body.top_level, "top level")
	check_eq(_body.physics_interpolation_mode, Node.PHYSICS_INTERPOLATION_MODE_OFF, "no interp")
	check(_body.process_priority > _cam.process_priority, "runs after the camera")
	_motor.global_position = Vector3(3, 0.5, -2)
	_cam.yaw = 0.7
	_body.update_body()
	check_near(_body.global_position.distance_to(Vector3(3, 0.5, -2)), 0.0, 1e-5, "at the motor")
	var view_fwd := Basis(Vector3.UP, 0.7) * Vector3.FORWARD
	var body_fwd := _body.global_basis * Vector3.BACK  # bodies face +Z
	check_near(body_fwd.distance_to(view_fwd), 0.0, 1e-5, "faces the view: %s" % body_fwd)


func test_chest_pitch_follows_the_view() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	var skel := _body.skeleton
	var chest := skel.find_bone("Chest")
	# Modified poses last only until the skin is drawn: read them as the
	# modifier finishes, on real frames (the body updates in _process).
	var leans: Array[float] = []
	_body.spine.modification_processed.connect(
		func() -> void:
			var up := skel.get_bone_global_pose(chest).basis * Vector3.UP
			leans.append(rad_to_deg(atan2(up.z, up.y)))
	)
	var share := float(ContentDB.tuning("body").chest_pitch_share)
	_cam.pitch = deg_to_rad(-60.0)
	for i in 3:  # several frames: the turn must not pile up
		await tree.process_frame
	if not check(leans.size() >= 2, "modifier ran each frame: %d" % leans.size()):
		return
	check_near(leans[-1], 60.0 * share, 0.1, "leans forward by the share of the pitch")
	check_near(leans[-2], 60.0 * share, 0.1, "same lean the frame before")
	_cam.pitch = 0.0
	await tree.process_frame
	await tree.process_frame
	check_near(leans[-1], 0.0, 0.1, "upright at level view")


func test_head_offset_uses_this_frame() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	check(_cam.head_offset.is_valid(), "camera reads the head")
	_motor.global_position = Vector3(10, 2, 5)  # moved; body not placed yet
	var head: Vector3 = _cam.head_offset.call()
	check_near(head.distance_to(Vector3(0, 1.6, 0)), 0.0, 1e-4, "head above the motor: %s" % head)


func test_wall_cast_sets_the_arm_retract() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	var cfg := ContentDB.tuning("body")
	var cast_m := float(cfg.wall_cast_m)
	var radius := float(cfg.wall_cast_radius_m)
	_motor.process_mode = Node.PROCESS_MODE_DISABLED  # no falling
	_motor.global_position = Vector3.ZERO
	var wall := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 3, 0.2)
	shape.shape = box
	wall.add_child(shape)
	_root.add_child(wall)
	var chest_y := 1.2  # synthetic rig: Hips 1.0 + Chest 0.2
	for d: float in [cast_m * 2.0, 0.4, radius * 0.5]:
		# wall face d metres in front of the chest (yaw 0 faces -Z)
		wall.global_position = Vector3(0, chest_y, -(d + 0.1))
		await tree.physics_frame
		await tree.physics_frame
		_body.update_retract()
		var want := clampf(1.0 - maxf(0.0, d - radius) / cast_m, 0.0, 1.0)
		check_near(
			_body.arm_retract, want, 0.02, "wall %.2f m: retract %.3f" % [d, _body.arm_retract]
		)
	wall.global_position = Vector3(0, chest_y, -0.5)  # 0.4 m ahead, outside the sphere
	await tree.physics_frame
	await tree.physics_frame
	_cam.yaw = PI  # turn away: the wall is behind
	_body.update_retract()
	check_near(_body.arm_retract, 0.0, 1e-6, "nothing ahead after turning")


func test_body_turn_keeps_the_head_facing_ahead() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	var skel := _body.skeleton
	var head := skel.find_bone("Head")
	var faces: Array[Vector3] = []
	_body.spine.modification_processed.connect(
		func() -> void:
			var b := skel.global_basis * skel.get_bone_global_pose(head).basis
			faces.append(b * Vector3.BACK)  # bodies face +Z
	)
	_body.turn_offset = deg_to_rad(60.0)
	for i in 3:
		await tree.process_frame
	if not check(faces.size() >= 1, "modifier ran"):
		return
	var rig_fwd := _body.global_basis * Vector3.BACK
	var view_fwd := Basis(Vector3.UP, _cam.yaw) * Vector3.FORWARD
	check_near(rad_to_deg(rig_fwd.angle_to(view_fwd)), 60.0, 0.5, "body turned 60 degrees")
	check_near(rad_to_deg(faces[-1].angle_to(view_fwd)), 0.0, 0.5, "head still faces the view")


func test_lean_moves_the_eye_forward() -> void:
	if not check(_setup(), ", ".join(_body.errors)):
		return
	_cam.update_view(DT)
	var before := _cam.global_position
	_cam.lean_m = 0.3
	_cam.update_view(DT)
	var fwd := Basis(Vector3.UP, _cam.yaw) * Vector3.FORWARD
	check_near((_cam.global_position - before).dot(fwd), 0.3, 1e-4, "eye 0.3 m further ahead")
