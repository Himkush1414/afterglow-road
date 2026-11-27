extends SceneTree
## Checks the player clip library of one content tree against its clip
## preset <root>/assetgen/animations.json (22 §7 T-22-6, frame counts and
## loops): every clip exists with its frame count ± 2 at the preset fps and
## its loop flag; every track targets the profile skeleton
## (%GeneralSkeleton); and every clip plays on each imported body
## <root>/assets/models/character/body_*.glb: posed half way, some bone
## turns at least 2° from its rest and every bone pose is finite.
## Usage: godot --headless -s res://src/tools/check_animations.gd -- <res:// root>
## Prints each error, then RESULT PASS / FAIL; exit code 0 / 1.

const PRESET := "assetgen/animations.json"
const BODY_DIR := "assets/models/character"
const FRAME_TOLERANCE := 2
const MIN_TURN_DEG := 2.0
const SKELETON := "%GeneralSkeleton"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: -- <res:// content root>")
		quit(2)
		return
	var errors := PackedStringArray()
	var preset: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(args[0].path_join(PRESET))
	)
	if not preset is Dictionary:
		print("%s: missing or not JSON" % PRESET)
		print("RESULT FAIL")
		quit(1)
		return
	var lib_path := args[0].path_join(String(preset.get("library", "")))
	var library := load(lib_path) as AnimationLibrary if ResourceLoader.exists(lib_path) else null
	if library == null:
		errors.append("%s: missing" % lib_path)
	else:
		_check_clips(library, preset, errors)
		for f in DirAccess.get_files_at(args[0].path_join(BODY_DIR)):
			if f.begins_with("body_") and f.ends_with(".glb"):
				_check_plays(args[0].path_join(BODY_DIR).path_join(f), library, errors)
	for e in errors:
		print(e)
	print("clips %d" % (library.get_animation_list().size() if library else 0))
	print("RESULT %s" % ("PASS" if errors.is_empty() else "FAIL"))
	quit(0 if errors.is_empty() else 1)


func _check_clips(library: AnimationLibrary, preset: Dictionary, errors: PackedStringArray) -> void:
	var fps := float(preset.get("fps", 30))
	var clips: Dictionary = preset.get("clips", {})
	for id: String in clips:
		var spec: Dictionary = clips[id]
		if not library.has_animation(id):
			errors.append("%s: missing" % id)
			continue
		var anim := library.get_animation(id)
		var frames := roundi(anim.length * fps)
		if absi(frames - int(spec.frames)) > FRAME_TOLERANCE:
			errors.append(
				"%s: %d frames, want %d ± %d" % [id, frames, spec.frames, FRAME_TOLERANCE]
			)
		var loops := anim.loop_mode != Animation.LOOP_NONE
		if loops != bool(spec.get("loop", false)):
			errors.append("%s: loop %s, want %s" % [id, loops, spec.get("loop", false)])
		for t in anim.get_track_count():
			if not String(anim.track_get_path(t)).begins_with(SKELETON + ":"):
				errors.append("%s: track %s is not on the skeleton" % [id, anim.track_get_path(t)])
				break


func _check_plays(body_path: String, library: AnimationLibrary, errors: PackedStringArray) -> void:
	var body: Node = (load(body_path) as PackedScene).instantiate()
	root.add_child(body)
	var skeletons := body.find_children("*", "Skeleton3D", true, false)
	if skeletons.size() != 1:
		errors.append("%s: %d skeletons" % [body_path, skeletons.size()])
		body.free()
		return
	var skel: Skeleton3D = skeletons[0]
	var player := AnimationPlayer.new()
	body.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("", library)
	for id in library.get_animation_list():
		skel.reset_bone_poses()
		player.play(id)
		player.seek(library.get_animation(id).length * 0.5, true)
		var turn := 0.0
		var finite := true
		for b in skel.get_bone_count():
			var pose := skel.get_bone_pose(b)
			finite = finite and pose.origin.is_finite() and pose.basis.is_finite()
			var rest := skel.get_bone_rest(b).basis.get_rotation_quaternion()
			turn = maxf(turn, rad_to_deg(rest.angle_to(pose.basis.get_rotation_quaternion())))
		player.stop()
		if not finite:
			errors.append("%s on %s: a bone pose is not finite" % [id, body_path.get_file()])
		elif turn < MIN_TURN_DEG:
			errors.append("%s on %s: no bone moves (%.2f°)" % [id, body_path.get_file(), turn])
	body.free()
