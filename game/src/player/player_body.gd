class_name PlayerBody
extends Node3D
## The player's one full-body rig (10 §2 rules 1, 3, 4, 11): the imported
## body scene, top_level with no physics interpolation of its own, placed
## every rendered frame (after PlayerCamera) at the motor's interpolated
## position with the view's render-rate yaw, animated by PlayerAnimator,
## its chest pitched by a share of the view pitch (SpinePitch, after the
## animation). Meshes of the head segments are only on the head render
## layer, which the first-person camera does not draw; mirrors and lights
## still do. Every surface gets the body shader (10 §2 rule 5): camera-space
## drawing for the main camera through a per-mesh view_local matrix built
## from local transforms only; garments draw both faces (open ends, Q-124).
## A sphere swept forward from the chest each physics tick gives
## `arm_retract` (10 §2 rule 6), which blends the arms toward the held-close
## pose so hands and tools stay out of walls.
## Numbers: the "body" tuning group; head segments: customization.json.

## After PlayerCamera (-30), before the mirror camera (10 §2 rule 11).
const PROCESS_PRIORITY := -20
## Render layer (1-based) of the head meshes (10 §2 rule 4).
const HEAD_LAYER := 2
const KEYS: Array[String] = ["chest_pitch_share", "wall_cast_m", "wall_cast_radius_m"]
const SKIN_PREFIX := "skin_"
const BODY_SHADER := preload("res://shaders/body.gdshader")
const BODY_DOUBLE_SHADER := preload("res://shaders/body_double.gdshader")

var errors: PackedStringArray = []
var motor: PlayerMotor
var view: PlayerCamera
var rig: Node3D
var skeleton: Skeleton3D
var animator: PlayerAnimator
var spine: SpinePitch
## 0 (nothing within the wall cast) .. 1 (touching): how far the arms pull in.
var arm_retract := 0.0

var _head_bone := -1
var _chest_bone := -1
var _cast_query: PhysicsShapeQueryParameters3D
var _cast_m := 0.0
## Body meshes and their body-shader materials (one per surface).
var _meshes: Array[MeshInstance3D] = []
var _materials: Array[Array] = []


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
	_chest_bone = skeleton.find_bone("Chest")
	_set_layers(head_segments)
	_cast_m = float(cfg.wall_cast_m)
	var sphere := SphereShape3D.new()
	sphere.radius = float(cfg.wall_cast_radius_m)
	_cast_query = PhysicsShapeQueryParameters3D.new()
	_cast_query.shape = sphere
	_cast_query.exclude = [motor.get_rid()]
	view.cull_mask &= ~head_layer_mask()
	view.head_offset = head_offset
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


func _physics_process(_delta: float) -> void:
	if motor != null and _cast_query != null:
		update_retract()


## Sweeps the wall cast from the chest along the view's yaw (physics state,
## so call it in a physics tick) and sets `arm_retract`.
func update_retract() -> void:
	var chest := Vector3(0.0, 1.0, 0.0)
	if _chest_bone >= 0:
		chest = local_transform(skeleton) * skeleton.get_bone_global_pose(_chest_bone).origin
	var start := motor.global_position + _turn() * chest
	var forward := Basis(Vector3.UP, view.yaw) * Vector3.FORWARD
	_cast_query.transform = Transform3D(Basis.IDENTITY, start)
	_cast_query.motion = forward * _cast_m
	var space := get_world_3d().direct_space_state
	var hit := space.cast_motion(_cast_query)
	var free := 1.0 if hit.is_empty() else float(hit[0])
	if free >= 1.0:
		# A sphere that starts inside a wall is not reported by the sweep.
		_cast_query.motion = Vector3.ZERO
		if not space.intersect_shape(_cast_query, 1).is_empty():
			free = 0.0
	arm_retract = clampf(1.0 - free, 0.0, 1.0)


## Places the rig for this rendered frame, passes on the view pitch and
## sets every mesh's camera-relative matrix.
func update_body() -> void:
	global_transform = Transform3D(_turn(), motor.get_global_transform_interpolated().origin)
	spine.pitch = view.pitch
	var cam_inv := Transform3D(view.global_basis, view.eye_offset).affine_inverse()
	var body := Transform3D(_turn(), Vector3.ZERO)
	for i in _meshes.size():
		var vl := Projection(cam_inv * body * local_transform(_meshes[i]))
		for mat: ShaderMaterial in _materials[i]:
			mat.set_shader_parameter("view_local", vl)


## The head bone's origin as an offset from the motor's interpolated
## position, for this frame's yaw (the camera runs first and must not read
## last frame's placement), from local transforms only.
func head_offset() -> Vector3:
	var head := skeleton.get_bone_global_pose(_head_bone).origin
	return _turn() * (local_transform(skeleton) * head)


## `node`'s transform relative to this body root, multiplied from local
## transforms (no global position enters it).
func local_transform(node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != self and n is Node3D:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	return t


## Rig yaw: the view's yaw (the bodies face +Z, yaw 0 faces -Z).
func _turn() -> Basis:
	return Basis(Vector3.UP, view.yaw + PI)


func _set_layers(head_segments: Array) -> void:
	for node in rig.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var head := false
		for seg: String in head_segments:
			head = head or String(mesh.name).ends_with("_" + seg)
		mesh.layers = head_layer_mask() if head else 1
		if mesh.mesh != null:
			_meshes.append(mesh)
			_materials.append(_body_materials(mesh))


## Swaps each surface's material for the body shader with the same colour,
## texture and roughness; garments and imported double-sided materials draw
## both faces.
func _body_materials(mesh: MeshInstance3D) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	var garment := not String(mesh.name).begins_with(SKIN_PREFIX)
	for s in mesh.mesh.get_surface_count():
		var src := mesh.get_active_material(s) as BaseMaterial3D
		var both := garment or (src != null and src.cull_mode == BaseMaterial3D.CULL_DISABLED)
		var mat := ShaderMaterial.new()
		mat.shader = BODY_DOUBLE_SHADER if both else BODY_SHADER
		if src != null:
			mat.set_shader_parameter("albedo", src.albedo_color)
			mat.set_shader_parameter("roughness", src.roughness)
			if src.albedo_texture != null:
				mat.set_shader_parameter("albedo_texture", src.albedo_texture)
		mesh.set_surface_override_material(s, mat)
		out.append(mat)
	return out
