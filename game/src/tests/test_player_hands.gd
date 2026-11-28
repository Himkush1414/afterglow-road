extends TestCase
## PlayerHands on a synthetic arm rig (shoulders at chest height, upper arm
## 0.30 m, forearm 0.25 m along x): reach within 2 cm of a target and back,
## one signal per reach, held item on the right hand with its grip at the
## pose offset, left hand on the grip_l marker in two-handed poses.

const DT := 1.0 / 60.0
const HAND_TOL_M := 0.02


## Reads bone positions after every other modifier of the frame (modified
## poses last only until the skin is drawn).
class PoseReader:
	extends SkeletonModifier3D
	var at := {}

	func _process_modification_with_delta(_delta: float) -> void:
		var sk := get_skeleton()
		for bone: String in ["RightHand", "LeftHand"]:
			at[bone] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(bone)).origin


var _root: Node3D
var _skel: Skeleton3D
var _hands: PlayerHands
var _cfg := {}
var _reader: PoseReader


func before_each() -> void:
	_root = Node3D.new()
	tree.root.add_child(_root)
	_skel = Skeleton3D.new()
	_skel.name = "GeneralSkeleton"
	_root.add_child(_skel)
	var bones := [
		["Hips", -1, Vector3(0, 1.0, 0)],
		["Chest", 0, Vector3(0, 0.4, 0)],
		["RightUpperArm", 1, Vector3(-0.2, 0, 0)],
		["RightLowerArm", 2, Vector3(-0.3, 0, 0)],
		["RightHand", 3, Vector3(-0.25, 0, 0)],
		["LeftUpperArm", 1, Vector3(0.2, 0, 0)],
		["LeftLowerArm", 5, Vector3(0.3, 0, 0)],
		["LeftHand", 6, Vector3(0.25, 0, 0)],
	]
	for b: Array in bones:
		var i := _skel.get_bone_count()
		_skel.add_bone(b[0])
		_skel.set_bone_parent(i, b[1])
		_skel.set_bone_rest(i, Transform3D(Basis.IDENTITY, b[2]))
	_skel.reset_bone_poses()
	_hands = PlayerHands.new()
	_root.add_child(_hands)
	_cfg = ContentDB.tuning("hands").duplicate(true)


func after_each() -> void:
	_root.free()
	_reader = null


## Global position of a bone as the modifiers leave it, a frame from now.
func _hand_after_frame(bone: String) -> Vector3:
	if _reader == null:
		_reader = PoseReader.new()
		_skel.add_child(_reader)  # after the hands' IK nodes
	await tree.process_frame
	await tree.process_frame
	return _reader.at.get(bone, Vector3.INF)


func test_setup_names_missing_bones_and_keys() -> void:
	check(not _hands.setup(_skel, {}), "refused without tuning")
	check(_hands.errors.size() >= 3, "names each key: %s" % ", ".join(_hands.errors))
	var bare := Skeleton3D.new()
	_root.add_child(bare)
	check(not _hands.setup(bare, _cfg), "refused without arm bones")


func test_reach_hits_the_target_and_returns() -> void:
	if not check(_hands.setup(_skel, _cfg), ", ".join(_hands.errors)):
		return
	await tree.process_frame
	var rest: Vector3 = await _hand_after_frame("RightHand")
	var target := Vector3(-0.35, 1.25, -0.3)  # 0.45 m from the shoulder: reachable
	var count := [0]
	_hands.reached.connect(func() -> void: count[0] += 1)
	check(_hands.reach(target), "reach starts")
	check(not _hands.reach(target), "a second reach is refused while one runs")
	var waited := 0.0
	while count[0] == 0 and waited < 2.0:
		await tree.process_frame
		waited += _hands.get_process_delta_time()
	check_eq(count[0], 1, "reached once")
	# The frame that signalled contact ran its IK at full influence; the
	# reader holds that pose now (the return starts on the next frame).
	var at: Vector3 = _reader.at.get("RightHand", Vector3.INF)
	check(at.distance_to(target) < HAND_TOL_M, "hand within 2 cm: %.4f m" % at.distance_to(target))
	var reach_s := float(_cfg.reach_s)
	check(waited < reach_s + 0.2, "out in about reach_s: %.3f s" % waited)
	while _hands.is_reaching() and waited < 3.0:
		await tree.process_frame
		waited += _hands.get_process_delta_time()
	var back: Vector3 = await _hand_after_frame("RightHand")
	check(
		back.distance_to(rest) < 0.001, "back to the animated pose: %.4f m" % back.distance_to(rest)
	)
	check_eq(count[0], 1, "still one signal after the return")


func test_hold_places_the_grip_at_the_pose_offset() -> void:
	_cfg.held_offsets["small_1h"] = [0.05, 0.0, -0.02, 0.0, 90.0, 0.0]
	if not check(_hands.setup(_skel, _cfg), ", ".join(_hands.errors)):
		return
	var item := Node3D.new()
	var grip := Node3D.new()
	grip.name = PlayerHands.GRIP_R
	grip.position = Vector3(0, 0.1, 0)
	item.add_child(grip)
	check(not _hands.hold(item, "no_such_pose"), "unknown pose refused")
	check(_hands.hold(item, "small_1h"), "held")
	await tree.process_frame
	var hand := _skel.global_transform * _skel.get_bone_global_pose(_skel.find_bone("RightHand"))
	var want := hand * Vector3(0.05, 0.0, -0.02)
	check_near(grip.global_position.distance_to(want), 0.0, 1e-4, "grip at the offset")
	check(_hands.release() == item, "release returns the item")
	check(_hands.held == null and item.get_parent() == null, "hand is empty")
	item.free()


func test_two_handed_pose_puts_the_left_hand_on_grip_l() -> void:
	_cfg.held_offsets["tool_2h"] = [0.3, 0.0, -0.3, 0.0, 0.0, 0.0]
	if not check(_hands.setup(_skel, _cfg), ", ".join(_hands.errors)):
		return
	var item := Node3D.new()
	var grip_l := Node3D.new()
	grip_l.name = PlayerHands.GRIP_L
	grip_l.position = Vector3(0.3, 0, 0)  # 0.46 m from the left shoulder
	item.add_child(grip_l)
	check(_hands.hold(item, "tool_2h"), "held two-handed")
	await tree.process_frame
	var left: Vector3 = await _hand_after_frame("LeftHand")
	var d := left.distance_to(grip_l.global_position)
	check(d < HAND_TOL_M, "left hand on grip_l: %.4f m" % d)
	var one := Node3D.new()
	var grip_l2 := Node3D.new()
	grip_l2.name = PlayerHands.GRIP_L
	one.add_child(grip_l2)
	check(_hands.hold(one, "small_1h"), "one-handed pose")
	check_eq((_skel.get_node("LeftArmIK") as TwoBoneIK3D).influence, 0.0, "left hand free")
	item.free()
