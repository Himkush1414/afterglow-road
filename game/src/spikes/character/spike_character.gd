extends SceneTree
## Spike P1-07 (assumption A-07): load the exported character glTF, map its
## skeleton onto SkeletonProfileHumanoid and check that every required
## profile bone is mapped to an existing bone with a skinned mesh attached.
## Usage: godot -s res://src/spikes/character/spike_character.gd -- FILE.glb [OUT.png]
## With OUT.png (needs a display) a front view is saved.
## Prints RESULT PASS / FAIL.

## Profile bone -> exported bone, for the game-engine rig naming.
const SIDE_MAP := {
	"Shoulder": "clavicle",
	"UpperArm": "upperarm",
	"LowerArm": "lowerarm",
	"Hand": "hand",
	"ThumbMetacarpal": "thumb_01",
	"ThumbProximal": "thumb_02",
	"ThumbDistal": "thumb_03",
	"IndexProximal": "index_01",
	"IndexIntermediate": "index_02",
	"IndexDistal": "index_03",
	"MiddleProximal": "middle_01",
	"MiddleIntermediate": "middle_02",
	"MiddleDistal": "middle_03",
	"RingProximal": "ring_01",
	"RingIntermediate": "ring_02",
	"RingDistal": "ring_03",
	"LittleProximal": "pinky_01",
	"LittleIntermediate": "pinky_02",
	"LittleDistal": "pinky_03",
	"UpperLeg": "thigh",
	"LowerLeg": "calf",
	"Foot": "foot",
	"Toes": "ball",
}
const CENTRE_MAP := {
	"Root": "Root",
	"Hips": "pelvis",
	"Spine": "spine_01",
	"Chest": "spine_02",
	"UpperChest": "spine_03",
	"Neck": "neck_01",
	"Head": "head",
}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: -- FILE.glb [OUT.png]")
		quit(2)
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(args[0], state)
	if err != OK:
		push_error("glTF load failed: %d" % err)
		quit(1)
		return
	var scene := doc.generate_scene(state)
	root.add_child(scene)
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	var meshes := scene.find_children("*", "MeshInstance3D", true, false)
	if skeletons.size() != 1:
		print("expected one skeleton, found %d" % skeletons.size())
		print("RESULT FAIL")
		quit(1)
		return
	var skel: Skeleton3D = skeletons[0]
	var skinned := 0
	for m: MeshInstance3D in meshes:
		if m.skin != null and m.get_node_or_null(m.skeleton) == skel:
			skinned += 1

	var profile := SkeletonProfileHumanoid.new()
	var bone_map := BoneMap.new()
	bone_map.profile = profile
	var missing_required: Array[String] = []
	var unmapped_optional: Array[String] = []
	for i in profile.bone_size:
		var pname := profile.get_bone_name(i)
		var target := _target(pname)
		if target != "" and skel.find_bone(target) >= 0:
			bone_map.set_skeleton_bone_name(pname, target)
		elif profile.is_required(i):
			missing_required.append(pname)
		else:
			unmapped_optional.append(pname)

	var head_y := skel.get_bone_global_rest(skel.find_bone("head")).origin.y
	var top := _mesh_top(meshes)
	print(
		(
			"skeleton bones %d, skinned meshes %d of %d, profile bones %d"
			% [skel.get_bone_count(), skinned, meshes.size(), profile.bone_size]
		)
	)
	print("missing required: %s" % str(missing_required))
	print("unmapped optional: %s" % str(unmapped_optional))
	print("head bone rest height %.3f m, mesh top %.3f m" % [head_y, top])

	if args.size() > 1:
		await _shot(args[1], top)

	var ok := missing_required.is_empty() and skinned > 0
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _target(profile_bone: String) -> String:
	if CENTRE_MAP.has(profile_bone):
		return CENTRE_MAP[profile_bone]
	for side: String in ["Left", "Right"]:
		if profile_bone.begins_with(side):
			var rest := profile_bone.substr(side.length())
			if SIDE_MAP.has(rest):
				return "%s_%s" % [SIDE_MAP[rest], "l" if side == "Left" else "r"]
	return ""


func _mesh_top(meshes: Array[Node]) -> float:
	var top := -INF
	for m: MeshInstance3D in meshes:
		var aabb := m.global_transform * m.get_aabb()
		top = maxf(top, aabb.end.y)
	return top


func _shot(path: String, height: float) -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.2, 0.22, 0.25)
	env.environment.ambient_light_color = Color(0.5, 0.5, 0.5)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, 20, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = height * 1.15
	cam.position = Vector3(0, height * 0.5, 4)
	root.add_child(cam)
	for f in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
