class_name PlayerBody
extends Node3D
## The player's one full-body rig (10 §2 rules 1, 3, 4, 11): the imported
## body scene, top_level with no physics interpolation of its own, placed
## every rendered frame (after PlayerCamera) at the motor's interpolated
## position with the view's render-rate yaw, animated by PlayerAnimator,
## its chest pitched by a share of the view pitch (SpinePitch, after the
## animation). Meshes of the head segments are only on the head render
## layer, which the first-person camera does not draw; mirrors and lights
## still do. Garment materials draw both faces (open ends, Q-124).
## Numbers: the "body" tuning group; head segments: customization.json.

## After PlayerCamera (-30), before the mirror camera (10 §2 rule 11).
const PROCESS_PRIORITY := -20
## Render layer (1-based) of the head meshes (10 §2 rule 4).
const HEAD_LAYER := 2
const KEYS: Array[String] = ["chest_pitch_share"]
const SKIN_PREFIX := "skin_"

var errors: PackedStringArray = []
var motor: PlayerMotor
var view: PlayerCamera
var rig: Node3D
var skeleton: Skeleton3D
var animator: PlayerAnimator
var spine: SpinePitch

var _head_bone := -1


## Builds the rig from `rig_scene` (a body scene holding %GeneralSkeleton)
## following `body` and `camera`; `movement`, `cfg`: the "movement" and
## "body" tuning groups; `head_segments`: segment names whose meshes are
## head meshes. False with `errors`.
func setup(
	body: PlayerMotor,
	camera: PlayerCamera,
	rig_scene: PackedScene,
	library: AnimationLibrary,
	movement: Dictionary,
	cfg: Dictionary,
	head_segments: Array
) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("body: missing %s" % key)
	if body == null or camera == null or rig_scene == null:
		errors.append("body: needs a motor, a camera and a rig scene")
	if not errors.is_empty():
		return false
	motor = body
	view = camera
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = PROCESS_PRIORITY
	rig = rig_scene.instantiate() as Node3D
	add_child(rig)
	var found := rig.find_children("*", "Skeleton3D", true, false)
	skeleton = found[0] as Skeleton3D if not found.is_empty() else null
	_head_bone = skeleton.find_bone("Head") if skeleton else -1
	if skeleton == null or _head_bone < 0:
		errors.append("body: rig has no skeleton with a Head bone")
		return false
	_set_layers(head_segments)
	view.cull_mask &= ~head_layer_mask()
	view.head_origin = head_origin
	spine = SpinePitch.new()
	skeleton.add_child(spine)
	if not spine.setup(float(cfg.chest_pitch_share)):
		errors.append("body: rig has no Chest bone")
		return false
	animator = PlayerAnimator.new()
	add_child(animator)
	if not animator.setup(motor, library, rig, movement):
		errors.append_array(animator.errors)
		return false
	update_body()
	return true


## Bit mask of the head render layer.
static func head_layer_mask() -> int:
	return 1 << (HEAD_LAYER - 1)


func _process(_delta: float) -> void:
	if motor != null:
		update_body()


## Places the rig for this rendered frame and passes on the view pitch.
func update_body() -> void:
	global_transform = _frame()
	spine.pitch = view.pitch


## The head bone's origin (global) for this frame's body placement, so the
## camera, which runs first, does not read last frame's position.
func head_origin() -> Vector3:
	var rig_local := global_transform.affine_inverse() * skeleton.global_transform
	return _frame() * (rig_local * skeleton.get_bone_global_pose(_head_bone).origin)


## Rig placement: the motor's interpolated position, the view's yaw (the
## bodies face +Z, yaw 0 faces -Z).
func _frame() -> Transform3D:
	var base := motor.get_global_transform_interpolated().origin
	return Transform3D(Basis(Vector3.UP, view.yaw + PI), base)


func _set_layers(head_segments: Array) -> void:
	for node in rig.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var head := false
		for seg: String in head_segments:
			head = head or String(mesh.name).ends_with("_" + seg)
		mesh.layers = head_layer_mask() if head else 1
		if not String(mesh.name).begins_with(SKIN_PREFIX):
			_double_sided(mesh)


func _double_sided(mesh: MeshInstance3D) -> void:
	if mesh.mesh == null:
		return
	for s in mesh.mesh.get_surface_count():
		var mat := mesh.get_active_material(s) as BaseMaterial3D
		if mat == null:
			continue
		var copy := mat.duplicate() as BaseMaterial3D
		copy.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh.set_surface_override_material(s, copy)
