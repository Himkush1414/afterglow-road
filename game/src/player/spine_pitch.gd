class_name SpinePitch
extends SkeletonModifier3D
## Shares the view pitch with the spine (10 §2 rule 3): after the animation,
## the Chest bone turns about the body's side axis (skeleton x) by `share` x
## `pitch`; looking down leans the chest forward. `head_turn` (radians) turns
## the Head bone about the body's vertical axis afterwards: the mirror screen
## turns the body and sets minus that angle, so the head keeps facing ahead.

## View pitch in radians (positive looks up), set every frame.
var pitch := 0.0
var share := 0.0
var head_turn := 0.0

var _chest := -1
var _head := -1


## False when the skeleton has no Chest bone.
func setup(chest_share: float) -> bool:
	share = chest_share
	_chest = get_skeleton().find_bone("Chest") if get_skeleton() else -1
	_head = get_skeleton().find_bone("Head") if get_skeleton() else -1
	return _chest >= 0


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	if skel == null or _chest < 0:
		return
	# Body axes: x toward the left hand, y up, z forward; a positive turn
	# about x moves the top forward, so looking up (pitch > 0) leans back.
	var turn := Quaternion(Vector3.RIGHT, -pitch * share)
	var g := skel.get_bone_global_pose(_chest).basis.get_rotation_quaternion()
	var local := skel.get_bone_pose_rotation(_chest)
	skel.set_bone_pose_rotation(_chest, local * (g.inverse() * turn * g))
	if _head >= 0 and head_turn != 0.0:
		var yaw := Quaternion(Vector3.UP, head_turn)
		var gh := skel.get_bone_global_pose(_head).basis.get_rotation_quaternion()
		var lh := skel.get_bone_pose_rotation(_head)
		skel.set_bone_pose_rotation(_head, lh * (gh.inverse() * yaw * gh))
