class_name PlayerHands
extends Node
## The player's hands on the body skeleton (10 §2 rule 5): a held item hangs
## from the right-hand bone with a per-held_pose offset (its grip_r marker
## at that offset); in two-handed poses the left hand is put on the item's
## grip_l marker by two-bone IK; a reach moves the right hand to a target by
## IK over reach_s (smoothstep), emits `reached` at contact (the action
## happens then) and returns over reach_s. IK blends over the animated pose
## by its influence. Each arm's IK bends its elbow toward a pole below,
## outside and behind the shoulder (TwoBoneIK3D does nothing without a pole
## node in 4.7). Numbers: the "hands" tuning group.

## The right hand touches the reach target.
signal reached

const KEYS: Array[String] = ["reach_s", "held_offsets", "two_handed_poses"]
const RIGHT_ARM: Array[String] = ["RightUpperArm", "RightLowerArm", "RightHand"]
const LEFT_ARM: Array[String] = ["LeftUpperArm", "LeftLowerArm", "LeftHand"]
const GRIP_R := "grip_r"
const GRIP_L := "grip_l"
## Elbow pole from the shoulder, skeleton space (bodies face +Z): outward,
## down, behind, metres.
const POLE_OUT_M := 0.2
const POLE_DOWN_M := 0.5
const POLE_BACK_M := 0.4

var errors: PackedStringArray = []
var skeleton: Skeleton3D
## The item in the right hand, or null.
var held: Node3D
var held_pose := ""

var _cfg := {}
var _right_ik: TwoBoneIK3D
var _left_ik: TwoBoneIK3D
var _reach_target: Node3D
var _attach: BoneAttachment3D
## Reach: 0 idle, 1 going out, 2 coming back; _t in 0..1 within the phase.
var _phase := 0
var _t := 0.0


## Works on `skel` (a humanoid profile skeleton) with the "hands" tuning
## group; false with `errors`.
func setup(skel: Skeleton3D, cfg: Dictionary) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("hands: missing %s" % key)
	if skel == null:
		errors.append("hands: no skeleton")
	else:
		for bone: String in RIGHT_ARM + LEFT_ARM:
			if skel.find_bone(bone) < 0:
				errors.append("hands: skeleton has no %s" % bone)
	if not errors.is_empty():
		return false
	skeleton = skel
	_cfg = cfg
	_reach_target = Node3D.new()
	_reach_target.name = "ReachTarget"
	_reach_target.top_level = true
	skeleton.add_child(_reach_target)
	_attach = BoneAttachment3D.new()
	_attach.name = "RightHandAttachment"
	skeleton.add_child(_attach)
	_attach.bone_name = RIGHT_ARM[2]
	_right_ik = _arm_ik("RightArmIK", RIGHT_ARM, _reach_target)
	_left_ik = _arm_ik("LeftArmIK", LEFT_ARM, null)
	return true


## Starts a reach to `target` (global); false while a reach is under way.
func reach(target: Vector3) -> bool:
	if _phase != 0:
		return false
	_reach_target.global_position = target
	_phase = 1
	_t = 0.0
	return true


## True while a reach is going out or coming back.
func is_reaching() -> bool:
	return _phase != 0


## Puts `item` in the right hand in `pose` (a held_pose id); false with
## `errors` for an unknown pose. A held item is released first.
func hold(item: Node3D, pose: String) -> bool:
	errors.clear()
	var offsets: Dictionary = _cfg.held_offsets
	if not offsets.has(pose):
		errors.append("hands: no held offset for pose '%s'" % pose)
		return false
	release()
	var o: Array = offsets[pose]
	var rot := Vector3(float(o[3]), float(o[4]), float(o[5])) * (PI / 180.0)
	var offset := Transform3D(Basis.from_euler(rot), Vector3(float(o[0]), float(o[1]), float(o[2])))
	var grip_r := item.find_child(GRIP_R, true, false) as Node3D
	var grip := _local_to(item, grip_r) if grip_r else Transform3D.IDENTITY
	item.transform = offset * grip.affine_inverse()
	_attach.add_child(item)
	held = item
	held_pose = pose
	var grip_l := item.find_child(GRIP_L, true, false) as Node3D
	if grip_l and pose in (_cfg.two_handed_poses as Array):
		_left_ik.set_target_node(0, _left_ik.get_path_to(grip_l))
		_left_ik.influence = 1.0
	return true


## Lets go of the held item (it is removed from the hand and returned).
func release() -> Node3D:
	var item := held
	if item != null:
		_attach.remove_child(item)
	held = null
	held_pose = ""
	_left_ik.influence = 0.0
	_left_ik.set_target_node(0, NodePath())
	return item


func _process(delta: float) -> void:
	if _phase != 0:
		advance(delta)


## Moves the reach on by `delta` seconds (called from _process).
func advance(delta: float) -> void:
	_t = minf(1.0, _t + delta / float(_cfg.reach_s))
	var s := smoothstep(0.0, 1.0, _t)
	_right_ik.influence = s if _phase == 1 else 1.0 - s
	if _t < 1.0:
		return
	if _phase == 1:
		_phase = 2
		_t = 0.0
		reached.emit()
	else:
		_phase = 0
		_right_ik.influence = 0.0


func _arm_ik(ik_name: String, bones: Array[String], target: Node3D) -> TwoBoneIK3D:
	var shoulder := skeleton.get_bone_global_rest(skeleton.find_bone(bones[0])).origin
	var pole := Node3D.new()
	pole.name = ik_name + "Pole"
	pole.position = (shoulder + Vector3(signf(shoulder.x) * POLE_OUT_M, -POLE_DOWN_M, -POLE_BACK_M))
	skeleton.add_child(pole)
	var ik := TwoBoneIK3D.new()
	ik.name = ik_name
	skeleton.add_child(ik)
	ik.set_setting_count(1)
	ik.set_pole_node(0, ik.get_path_to(pole))
	ik.set_root_bone_name(0, bones[0])
	ik.set_middle_bone_name(0, bones[1])
	ik.set_end_bone_name(0, bones[2])
	if target != null:
		ik.set_target_node(0, ik.get_path_to(target))
	ik.influence = 0.0
	return ik


## `node`'s transform relative to `ancestor`, from local transforms.
static func _local_to(ancestor: Node, node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != ancestor and n is Node3D:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
