class_name HumanoidBones
extends RefCounted
## Names of the player skeleton's bones (the game-engine rig of the body
## generator, 22 §4) for each bone of SkeletonProfileHumanoid.

## Profile bone without its Left/Right prefix -> rig bone without _l/_r.
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
## Extra deform bones of the player skeleton (two per forearm), with their
## parent.
const TWIST := {
	"lowerarm_twist_01_l": "lowerarm_l",
	"lowerarm_twist_02_l": "lowerarm_l",
	"lowerarm_twist_01_r": "lowerarm_r",
	"lowerarm_twist_02_r": "lowerarm_r",
}


## The rig bone for a profile bone name, or "" when the rig has none.
static func rig_bone(profile_bone: String) -> String:
	if CENTRE_MAP.has(profile_bone):
		return CENTRE_MAP[profile_bone]
	for side: String in ["Left", "Right"]:
		if profile_bone.begins_with(side):
			var rest := profile_bone.substr(side.length())
			if SIDE_MAP.has(rest):
				return "%s_%s" % [SIDE_MAP[rest], "l" if side == "Left" else "r"]
	return ""


## A BoneMap onto SkeletonProfileHumanoid for `skeleton`, and the required
## profile bones it could not map: [BoneMap, PackedStringArray].
static func bone_map(skeleton: Skeleton3D) -> Array:
	var profile := SkeletonProfileHumanoid.new()
	var map := BoneMap.new()
	map.profile = profile
	var missing := PackedStringArray()
	for i in profile.bone_size:
		var name := profile.get_bone_name(i)
		var target := rig_bone(name)
		if target != "" and skeleton.find_bone(target) >= 0:
			map.set_skeleton_bone_name(name, target)
		elif profile.is_required(i):
			missing.append(name)
	return [map, missing]
