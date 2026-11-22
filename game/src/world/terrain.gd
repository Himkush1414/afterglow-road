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
## Layer textures: <content>/<TEXTURE_DIR>/<TEXTURE_PREFIX><layer>_ah.png and _nra.png.
const TEXTURE_DIR := "assets/textures/terrain"
const TEXTURE_PREFIX := "terrain_"
## Size of the shader's biome-to-layer table and its slope-layer slots.
const BIOME_IDS := 32
const SLOPE_SLOTS := 2
## Texel size of the normal and mask layers (04 §2).
const LAYER_TEXEL_M := 4.0

var lod := TerrainLod.new()
## Collision chunks around tracked bodies, and the fall-through guard
## (made by setup).
var collision: TerrainCollision
var errors: PackedStringArray = []
## Linear mean albedo per layer (empty without layer textures).
var layer_means: Array[Color] = []
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
	var normal_px := int(round(world.size_m / LAYER_TEXEL_M))
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
	if not _setup_surface(world):
		return false
	if collision == null:
		collision = TerrainCollision.new()
		add_child(collision)
	collision.setup(world)
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


## Ground wetness 0..1 from the weather (darker, smoother ground).
func set_wetness(value: float) -> void:
	_material.set_shader_parameter("wetness", clampf(value, 0.0, 1.0))


## Number of ground layers drawn (0 when the layer textures are missing).
func layer_count() -> int:
	return int(_material.get_shader_parameter("layer_count"))


## Ground surface (05 §5 fragment): biome cells, way and wet mask, far colour
## and the layer texture arrays, with the rules from the "terrain" tuning.
## A part whose file does not exist (the sample world has no mask or far
## colour; layer textures may not be generated yet) is turned off; a file
## that exists but fails its check fails the setup.
func _setup_surface(world: WorldData) -> bool:
	var cfg := ContentDB.tuning("terrain")
	var cells := world.biome_cells
	var biomes := world.read_layer("biome.bin", cells * cells)
	var mask_px := int(round(world.size_m / LAYER_TEXEL_M))
	var mask := PackedByteArray()
	if world.has_layer("mask.bin"):
		mask = world.read_layer("mask.bin", mask_px * mask_px * 4)
	if not world.errors.is_empty():
		errors.append_array(world.errors)
		return false
	_material.set_shader_parameter("biome_tex", _texture(cells, Image.FORMAT_R8, biomes))
	_material.set_shader_parameter("biome_cell_m", WorldData.BIOME_CELL_M)
	_material.set_shader_parameter("use_mask", not mask.is_empty())
	if not mask.is_empty():
		_material.set_shader_parameter("mask_tex", _texture(mask_px, Image.FORMAT_RGBA8, mask))
	var macro_path := world.folder() + "/macro.png"
	var use_macro := ResourceLoader.exists(macro_path)
	_material.set_shader_parameter("use_macro", use_macro)
	if use_macro:
		var macro := (load(macro_path) as Texture2D).get_image()
		macro.generate_mipmaps()
		_material.set_shader_parameter("macro_tex", ImageTexture.create_from_image(macro))
	var layers: Array = cfg.get("layers", [])
	var index := {}
	for i in layers.size():
		index[layers[i]] = i
	var table := PackedInt32Array()
	table.resize(BIOME_IDS)
	table.fill(-1)
	var biome_layer: Dictionary = cfg.get("biome_layer", {})
	for key: String in biome_layer:
		if int(key) < BIOME_IDS:
			table[int(key)] = index.get(biome_layer[key], -1)
	var slope_layer := PackedInt32Array([-1, -1])
	var slope_deg := PackedFloat32Array([90.0, 90.0])
	var slopes: Array = cfg.get("slope_layers", [])
	for i in mini(slopes.size(), SLOPE_SLOTS):
		slope_layer[i] = index.get(slopes[i].layer, -1)
		slope_deg[i] = float(slopes[i].deg)
	# Desktop projects the steepest slope layer (rock) triplanar; phones use XZ only.
	var desktop := RenderingServer.get_current_rendering_method() != "mobile"
	var steepest := (
		slope_layer[mini(slopes.size(), SLOPE_SLOTS) - 1] if not slopes.is_empty() else -1
	)
	layer_means.clear()
	var arrays := _layer_arrays(layers, layer_means)
	if arrays.is_empty():
		layer_means.clear()
	var p := {
		"biome_layer": table,
		"slope_layer": slope_layer,
		"slope_deg": slope_deg,
		"slope_blend_deg": float(cfg.get("slope_blend_deg", 0.0)),
		"dirt_layer": index.get(cfg.get("dirt_layer", ""), -1),
		"mud_layer": index.get(cfg.get("mud_layer", ""), -1),
		"tile_m": float(cfg.get("tile_m", 1.0)),
		"height_blend": float(cfg.get("height_blend", 0.0)),
		"macro_near_m": float(cfg.get("macro_near_m", 0.0)),
		"macro_far_m": float(cfg.get("macro_far_m", 0.0)),
		"wet_albedo": float(cfg.get("wet_albedo", 1.0)),
		"wet_roughness": float(cfg.get("wet_roughness", 1.0)),
		"triplanar_layer": steepest if desktop else -1,
		"layer_count": layers.size() if not arrays.is_empty() else 0,
	}
	for key: String in p:
		_material.set_shader_parameter(key, p[key])
	if not arrays.is_empty():
		_material.set_shader_parameter("layer_ah", arrays[0])
		_material.set_shader_parameter("layer_nra", arrays[1])
	return true


## [albedo+height array, normal+roughness+AO array], or [] when a texture is
## missing or the sizes differ.
static func _layer_arrays(layers: Array, means: Array[Color] = []) -> Array[Texture2DArray]:
	var ah: Array[Image] = []
	var nra: Array[Image] = []
	var size := Vector2i.ZERO
	for name: String in layers:
		for k in 2:
			var path := (
				"%s/%s/%s%s_%s.png"
				% [ContentDB.root, TEXTURE_DIR, TEXTURE_PREFIX, name, ["ah", "nra"][k]]
			)
			if not ResourceLoader.exists(path):
				return []
			var img := (load(path) as Texture2D).get_image()
			if img.is_compressed():
				img.decompress()
			img.convert(Image.FORMAT_RGBA8)
			if size == Vector2i.ZERO:
				size = img.get_size()
			if img.get_size() != size:
				Log.error("terrain", "%s: %s, expected %s" % [path, img.get_size(), size])
				return []
			img.generate_mipmaps()
			(ah if k == 0 else nra).append(img)
			if k == 0:
				means.append(OuterRing.mean_colour(img))
	if layers.is_empty():
		return []
	var out: Array[Texture2DArray] = []
	for images: Array[Image] in [ah, nra]:
		var arr := Texture2DArray.new()
		arr.create_from_images(images)
		out.append(arr)
	return out


static func _texture(px: int, format: int, data: PackedByteArray) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_from_data(px, px, false, format, data))


## The terrain height texture (RG8 codes) shared with the water shader.
func height_texture() -> Texture2D:
	return _material.get_shader_parameter("height_tex")


## The node that draws the patches (null before setup).
func draw_node() -> MultiMeshInstance3D:
	return _draw


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
