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

## The body model was replaced (swap_rig): users of the skeleton re-attach.
signal rig_changed

## After PlayerCamera (-30), before the mirror camera (10 §2 rule 11).
const PROCESS_PRIORITY := -20
## Render layer (1-based) of the head meshes (10 §2 rule 4).
const HEAD_LAYER := 2
const KEYS: Array[String] = ["chest_pitch_share", "wall_cast_m", "wall_cast_radius_m"]
const SKIN_PREFIX := "skin_"
const EYES_MESH := "eyes"
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
## Extra rig yaw in radians (the mirror screen's body turn); the head is
## turned back by the same angle so it keeps facing the view.
var turn_offset := 0.0

var _head_bone := -1
var _chest_bone := -1
var _cast_query: PhysicsShapeQueryParameters3D
var _cast_m := 0.0
## Body meshes and their body-shader materials (one per surface).
var _meshes: Array[MeshInstance3D] = []
var _materials: Array[Array] = []
var _library: AnimationLibrary
var _movement := {}
var _cfg := {}
var _head_segments: Array = []
var _head_meshes: Array = []
var _rig_path := ""


## Builds the rig from `rig_scene` (a body scene holding %GeneralSkeleton)
## following `body` and `camera`; `movement`, `cfg`: the "movement" and
## "body" tuning groups; `head_segments`: segment names whose meshes are
## head meshes; `head_meshes`: mesh names or name prefixes (ending in "_")
## that are head meshes too (eyes, hair). False with `errors`.
func setup(
	body: PlayerMotor,
	camera: PlayerCamera,
	rig_scene: PackedScene,
	library: AnimationLibrary,
	movement: Dictionary,
	cfg: Dictionary,
	head_segments: Array,
	head_meshes: Array = []
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
	_library = library
	_movement = movement
	_cfg = cfg
	_head_segments = head_segments
	_head_meshes = head_meshes
	top_level = true
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	process_priority = PROCESS_PRIORITY
	_cast_m = float(cfg.wall_cast_m)
	var sphere := SphereShape3D.new()
	sphere.radius = float(cfg.wall_cast_radius_m)
	_cast_query = PhysicsShapeQueryParameters3D.new()
	_cast_query.shape = sphere
	_cast_query.exclude = [motor.get_rid()]
	view.cull_mask &= ~head_layer_mask()
	view.head_offset = head_offset
	if not _build_rig(rig_scene):
		return false
	update_body()
	return true


## Replaces the body model (another body type) keeping everything else;
## emits rig_changed (hands and other users of the skeleton re-attach).
func swap_rig(rig_scene: PackedScene) -> bool:
	errors.clear()
	if rig_scene == null:
		errors.append("body: no rig scene")
		return false
	if rig != null:
		remove_child(rig)
		rig.queue_free()
	if animator != null:
		remove_child(animator)
		animator.queue_free()
	if not _build_rig(rig_scene):
		return false
	update_body()
	rig_changed.emit()
	return true


func _build_rig(rig_scene: PackedScene) -> bool:
	rig = rig_scene.instantiate() as Node3D
	_rig_path = rig_scene.resource_path
	add_child(rig)
	var found := rig.find_children("*", "Skeleton3D", true, false)
	skeleton = found[0] as Skeleton3D if not found.is_empty() else null
	_head_bone = skeleton.find_bone("Head") if skeleton else -1
	if skeleton == null or _head_bone < 0:
		errors.append("body: rig has no skeleton with a Head bone")
		return false
	_chest_bone = skeleton.find_bone("Chest")
	_meshes.clear()
	_materials.clear()
	_set_layers()
	spine = SpinePitch.new()
	skeleton.add_child(spine)
	if not spine.setup(float(_cfg.chest_pitch_share)):
		errors.append("body: rig has no Chest bone")
		return false
	animator = PlayerAnimator.new()
	add_child(animator)
	if not animator.setup(motor, _library, rig, _movement):
		errors.append_array(animator.errors)
		return false
	return true


## Applies `look` (an Appearance dictionary, already validated) with the
## customization data `cust` (11 §3-§4): body type (rig swap), build and
## face shape keys, skin, eye, hair and outfit tints, the chosen hair and
## facial hair only, skin hidden under garments. Returns the missing
## resources (empty when everything was found).
func apply_appearance(look: Dictionary, cust: Dictionary) -> PackedStringArray:
	var missing: PackedStringArray = []
	var path := String((cust.get("body_scenes", {}) as Dictionary).get(look.body, ""))
	if path != _rig_path:
		var scene := load(path) as PackedScene if ResourceLoader.exists(path) else null
		if scene == null:
			missing.append("body scene for %s" % look.body)
		elif not swap_rig(scene):
			missing.append_array(errors)
	var build_key := String((cust.builds as Dictionary).get(look.build, ""))
	var face_key := "face_%d" % (int(look.face) + 1)
	var hair_mesh := "hair_" + String(look.hair)
	var beard_mesh := "facial_hair_" + String(look.facial_hair)
	var hair_tint := Color.from_string(
		String(cust.hair_colours[int(look.hair_colour)]), Color.WHITE
	)
	var skin_tint := Color.from_string(String(cust.skin_tones[int(look.skin)]), Color.WHITE)
	var eye_tint := Color.from_string(String(cust.eye_colours[int(look.eye_colour)]), Color.WHITE)
	var garments := {}
	var outfit: Array = cust.outfit
	for i in outfit.size():
		var g: Dictionary = outfit[i]
		var idx := (
			int((look.outfit_colours as PackedInt32Array)[i])
			if i < look.outfit_colours.size()
			else 0
		)
		garments[String(g.garment)] = Color.from_string(String(g.colours[idx]), Color.WHITE)
	var found := {"build": build_key == "", "face": int(look.face) == 0}
	var names := {}
	for i in _meshes.size():
		var m := _meshes[i]
		var n := String(m.name)
		names[n] = true
		for k: int in m.mesh.get_blend_shape_count():
			var key := String(m.mesh.get_blend_shape_name(k))
			if key.begins_with("build_"):
				m.set_blend_shape_value(k, 1.0 if key == build_key else 0.0)
				found.build = found.build or key == build_key
			elif key.begins_with("face_"):
				m.set_blend_shape_value(k, 1.0 if key == face_key else 0.0)
				found.face = found.face or key == face_key
		var tint := Color.WHITE
		var has_tint := true
		if n.begins_with(SKIN_PREFIX):
			tint = skin_tint
		elif n == EYES_MESH:
			tint = eye_tint
		elif n.begins_with("facial_hair_"):
			m.visible = n == beard_mesh
			tint = hair_tint
		elif n.begins_with("hair_"):
			m.visible = n == hair_mesh
			tint = hair_tint
		else:
			has_tint = false
			for g: String in garments:
				if n.begins_with(g + "_"):
					tint = garments[g]
					has_tint = true
		if has_tint:
			for mat: ShaderMaterial in _materials[i]:
				mat.set_shader_parameter("albedo", tint)
	if not found.build:
		missing.append("shape key %s" % build_key)
	if not found.face:
		missing.append("shape key %s" % face_key)
	if String(look.hair) != Appearance.NONE and not names.has(hair_mesh):
		missing.append("mesh %s" % hair_mesh)
	if String(look.facial_hair) != Appearance.NONE and not names.has(beard_mesh):
		missing.append("mesh %s" % beard_mesh)
	_hide_covered_skin(garments.keys())
	return missing


## Skin segments under a visible garment mesh <garment>_<segment> are hidden
## (11 §4: nothing clips).
func _hide_covered_skin(garments: Array) -> void:
	var visible_parts := {}
	for m in _meshes:
		for g: String in garments:
			if m.visible and String(m.name).begins_with(g + "_"):
				visible_parts[String(m.name).substr(g.length() + 1)] = true
	for m in _meshes:
		var n := String(m.name)
		if n.begins_with(SKIN_PREFIX):
			m.visible = not visible_parts.has(n.substr(SKIN_PREFIX.length()))


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
	spine.head_turn = -turn_offset
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
	return Basis(Vector3.UP, view.yaw + PI + turn_offset)


func _set_layers() -> void:
	for node in rig.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var n := String(mesh.name)
		var head := false
		for seg: String in _head_segments:
			head = head or n.ends_with("_" + seg)
		for name_or_prefix: String in _head_meshes:
			if name_or_prefix.ends_with("_"):
				head = head or n.begins_with(name_or_prefix)
			else:
				head = head or n == name_or_prefix
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
