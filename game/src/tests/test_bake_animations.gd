extends TestCase
## Key-pose spline of the clip bake: loops wrap around, one-shots are
## clamped and their last frame lands on the last key.

const Bake := preload("res://src/tools/bake_animations.gd")

var _keys: Array = [
	{"t": 0.0, "v": Vector3.ZERO},
	{"t": 0.5, "v": Vector3(10, 0, 0)},
	{"t": 1.0, "v": Vector3(0, 20, 0)},
]


func _value(key: Dictionary) -> Vector3:
	return key.v


func test_one_shot_ends_on_the_last_key() -> void:
	var frames := 18
	check_near(Bake._share(frames - 1, frames, false), 1.0, 1e-6, "last frame share")
	var last := Bake._spline(_keys, Bake._share(frames - 1, frames, false), _value, false)
	check_near(last.distance_to(Vector3(0, 20, 0)), 0.0, 1e-4, "last frame on the last key")
	var first := Bake._spline(_keys, 0.0, _value, false)
	check_near(first.length(), 0.0, 1e-4, "first frame on the first key")
	var mid := Bake._spline(_keys, 0.5, _value, false)
	check_near(mid.distance_to(Vector3(10, 0, 0)), 0.0, 1e-4, "passes through the middle key")


func test_one_shot_does_not_wrap() -> void:
	# Just after the start, a clamped spline leaves the first key toward the
	# second only; a wrapping one is pulled by the last key (y = 20).
	var clamped := Bake._spline(_keys, 0.05, _value, false)
	var wrapped := Bake._spline(_keys, 0.05, _value, true)
	check(absf(clamped.y) < 0.5, "clamped start keeps y near 0: %s" % clamped)
	check(absf(wrapped.y - clamped.y) > 0.5, "the looping spline differs: %s" % wrapped)


func test_loop_share_stops_short_of_the_end() -> void:
	check_near(Bake._share(39, 40, true), 39.0 / 40.0, 1e-6, "loop share")
	check_near(Bake._share(0, 40, true), 0.0, 1e-6, "loop starts at 0")


func test_key_rotates_about_the_body_axes_of_the_base_pose() -> void:
	# Two bones: an arm resting along +x, hung down in the base clip by its
	# parent; a key of -90 degrees about x must swing it to face forward (+z)
	# whatever its rest frame.
	var rests := {
		"Chest": {"parent": "", "rest": Quaternion.IDENTITY},
		"LeftUpperArm": {"parent": "Chest", "rest": Quaternion.IDENTITY},
	}
	var anim := Animation.new()
	anim.length = 2.0 / 30.0
	anim.loop_mode = Animation.LOOP_LINEAR
	var hang := Quaternion(Vector3.FORWARD, deg_to_rad(90.0))  # +x arm turned to point down
	for bone: String in ["Chest", "LeftUpperArm"]:
		var t := anim.add_track(Animation.TYPE_ROTATION_3D)
		anim.track_set_path(t, NodePath("%GeneralSkeleton:" + bone))
		var q := hang if bone == "LeftUpperArm" else Quaternion.IDENTITY
		anim.rotation_track_insert_key(t, 0.0, q)
		anim.rotation_track_insert_key(t, 1.0 / 30.0, q)
	var arm_down := Bake.base_global(anim, rests, "LeftUpperArm", 0.0) * Vector3.RIGHT
	check_near(arm_down.distance_to(Vector3.DOWN), 0.0, 1e-4, "base pose: arm down %s" % arm_down)
	var pose_set := {"keys": [{"t": 0.0, "bones": {"LeftUpperArm": [-90, 0, 0]}}]}
	Bake.add_pose_keys(anim, pose_set, false, rests)
	var arm := Bake.base_global(anim, rests, "LeftUpperArm", 0.0) * Vector3.RIGHT
	check_near(arm.distance_to(Vector3.BACK), 0.0, 1e-4, "keyed: arm forward (+z) %s" % arm)
