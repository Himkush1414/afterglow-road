class_name Terrain
extends Node3D
## Draws the whole terrain (05 §5): CDLOD patches selected by TerrainLod, one
## MultiMeshInstance3D, heights and normals sampled in the vertex shader.
## Selection runs when the camera moved more than RESELECT_M or turned more
## than RESELECT_DEG; the shader morphs from that selection's eye and lift,
## so it agrees exactly with the selection between two runs.

const SHADER := "res://shaders/terrain.gdshader"
const RESELECT_M := 4.0
const RESELECT_DEG := 5.0
## Mesh grid; the shader folds it to fewer quads per patch.
const MESH_QUADS := 32

var lod := TerrainLod.new()
var errors: PackedStringArray = []
## Selections run so far and the instance count of the last one.
var selections := 0
var instances := 0

var _multimesh := MultiMesh.new()
var _draw: MultiMeshInstance3D
var _material := ShaderMaterial.new()
var _last_eye := Vector3(INF, INF, INF)
var _last_forward := Vector3.ZERO


## Builds the textures and the draw node from a loaded world. Returns false
## and fills `errors` when a file is missing or does not fit.
func setup(world: WorldData) -> bool:
	errors.clear()
	if not lod.setup(world):
		errors.append_array(lod.errors)
		return false
	var r0: Variant = Quality.value("terrain_r0_m")
	lod.set_ranges(float(r0) if r0 != null else TerrainLod.R0_M, TerrainLod.MORPH_START)
	var quads: Variant = Quality.value("terrain_quads")
	var normal_px := int(round(world.size_m / 4.0))
	var normals := world.read_layer("normal.bin", normal_px * normal_px * 2)
	var heights := world.read_layer("height.bin", world.samples * world.samples * 2)
	if normals.is_empty() or heights.is_empty():
		errors.append_array(world.errors)
		return false
	# The GPU texture drops the last row and column of samples (05 §5).
	var tex_px := world.samples - 1
	var rows := PackedByteArray()
	for j in tex_px:
		var src := j * world.samples * 2
		rows.append_array(heights.slice(src, src + tex_px * 2))
	var height_img := Image.create_from_data(tex_px, tex_px, false, Image.FORMAT_RG8, rows)
	var normal_img := Image.create_from_data(normal_px, normal_px, false, Image.FORMAT_RG8, normals)
	_material.shader = load(SHADER)
	_material.set_shader_parameter("height_tex", ImageTexture.create_from_image(height_img))
	_material.set_shader_parameter("normal_tex", ImageTexture.create_from_image(normal_img))
	_material.set_shader_parameter("sample_m", world.sample_m)
	_material.set_shader_parameter("origin_offset", world.origin_offset_m)
	_material.set_shader_parameter("size_m", world.size_m)
	_material.set_shader_parameter(
		"height_scale", world.height_of_code(1) - world.height_of_code(0)
	)
	_material.set_shader_parameter("height_offset", -world.height_of_code(0))
	_material.set_shader_parameter("r0", lod.r0)
	_material.set_shader_parameter("morph_start", lod.morph_start)
	_material.set_shader_parameter(
		"base_quads", float(quads) if quads != null else float(TerrainLod.PATCH_QUADS)
	)
	_multimesh.instance_count = 0
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_custom_data = true
	_multimesh.mesh = _patch_mesh()
	_multimesh.instance_count = TerrainLod.MAX_INSTANCES
	_multimesh.visible_instance_count = 0
	if _draw == null:
		_draw = MultiMeshInstance3D.new()
		add_child(_draw)
	_draw.multimesh = _multimesh
	_draw.material_override = _material
	var shadows: Variant = Quality.value("terrain_shadows")
	_draw.cast_shadow = (
		GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if shadows == null or shadows
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	)
	# The patches are placed in the shader, so the engine must not cull them.
	var lo := world.height_of_code(0)
	_draw.custom_aabb = AABB(
		Vector3(-world.origin_offset_m, lo, -world.origin_offset_m),
		Vector3(world.size_m, world.height_of_code(65535) - lo, world.size_m)
	)
	_last_eye = Vector3(INF, INF, INF)
	return true


func is_ready() -> bool:
	return _draw != null


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null and is_ready():
		update_for(cam)


## Re-selects when `cam` moved or turned past the thresholds. Returns true
## when a selection ran.
func update_for(cam: Camera3D) -> bool:
	var pos := cam.global_position
	var forward := -cam.global_basis.z
	var turned := _last_forward.angle_to(forward) > deg_to_rad(RESELECT_DEG)
	if pos.distance_to(_last_eye) <= RESELECT_M and not turned:
		return false
	_last_eye = pos
	_last_forward = forward
	instances = lod.select(pos, culling_planes(cam))
	_multimesh.visible_instance_count = instances
	if instances > 0:
		_multimesh.buffer = lod.buffer
	_material.set_shader_parameter("eye", lod.eye)
	_material.set_shader_parameter("lift", lod.lift)
	selections += 1
	return true


## The camera frustum widened so that nothing it can see before the next
## selection is culled: the field of view grows by twice the turn threshold
## and every plane moves out by the move threshold. No far plane: a turn
## reaches past it, and the GPU clips beyond it anyway.
static func culling_planes(cam: Camera3D) -> Array[Plane]:
	var size := cam.get_viewport().get_visible_rect().size
	var aspect := size.x / maxf(size.y, 1.0)
	var proj := Projection.create_perspective(
		minf(cam.fov + 2.0 * RESELECT_DEG, 179.0),
		aspect,
		cam.near,
		cam.far,
		cam.keep_aspect == Camera3D.KEEP_WIDTH
	)
	var xf := cam.global_transform
	var out: Array[Plane] = []
	for i: int in [
		Projection.PLANE_NEAR,
		Projection.PLANE_LEFT,
		Projection.PLANE_TOP,
		Projection.PLANE_RIGHT,
		Projection.PLANE_BOTTOM
	]:
		var p: Plane = xf * proj.get_projection_plane(i)
		p.d += RESELECT_M
		out.append(p)
	return out


static func _patch_mesh() -> ArrayMesh:
	var n := MESH_QUADS + 1
	var verts := PackedVector3Array()
	for z in n:
		for x in n:
			verts.append(Vector3(float(x) / MESH_QUADS, 0.0, float(z) / MESH_QUADS))
	var idx := PackedInt32Array()
	for z in MESH_QUADS:
		for x in MESH_QUADS:
			var a := z * n + x
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
