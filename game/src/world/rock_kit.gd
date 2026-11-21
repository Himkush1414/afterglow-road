class_name RockKit
extends RefCounted
## Meshes, collision shapes and the material of rock objects (cliff faces,
## boulders), shared by all regions. Meshes come from
## <content>/assets/models/rocks/rock_<type>.glb; when one is missing (the
## sample content) a primitive slab of a cliff face's size stands in. The
## material uses the terrain's steepest slope layer (rock), so cliffs and
## rocky ground match.

const MODEL_DIR := "assets/models/rocks"
const MODEL_PREFIX := "rock_"
const SHADER := "res://shaders/rock.gdshader"
## Stand-in slab: a cliff face's size (05 §5.1), base at y 0, facing +Z.
const STAND_IN_M := Vector3(8.0, 6.0, 0.6)
## A face stands this far off the slope along its normal, so the terrain's
## own curvature between texel centres does not swallow it.
const FACE_LIFT_M := 0.4

static var _shared: RockKit

var _meshes := {}
var _shapes := {}
var _material: ShaderMaterial


static func shared() -> RockKit:
	if _shared == null:
		_shared = RockKit.new()
	return _shared


func mesh(type_id: String) -> Mesh:
	if not _meshes.has(type_id):
		_meshes[type_id] = _load_mesh(type_id)
	return _meshes[type_id]


func shape(type_id: String) -> Shape3D:
	if not _shapes.has(type_id):
		_shapes[type_id] = mesh(type_id).create_trimesh_shape()
	return _shapes[type_id]


func material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = load(SHADER)
		var slopes: Array = ContentDB.tuning("terrain").get("slope_layers", [])
		var layer: String = slopes[-1].layer if not slopes.is_empty() else ""
		var base := (
			"%s/%s/%s%s" % [ContentDB.root, Terrain.TEXTURE_DIR, Terrain.TEXTURE_PREFIX, layer]
		)
		var textured := (
			layer != ""
			and ResourceLoader.exists(base + "_ah.png")
			and ResourceLoader.exists(base + "_nra.png")
		)
		_material.set_shader_parameter("textured", textured)
		if textured:
			_material.set_shader_parameter("albedo_height", _mipmapped(base + "_ah.png"))
			_material.set_shader_parameter("normal_rough_ao", _mipmapped(base + "_nra.png"))
	return _material


static func model_path(type_id: String) -> String:
	return "%s/%s/%s%s.glb" % [ContentDB.root, MODEL_DIR, MODEL_PREFIX, type_id]


func _load_mesh(type_id: String) -> Mesh:
	var path := model_path(type_id)
	if ResourceLoader.exists(path):
		var scene := (load(path) as PackedScene).instantiate()
		var found := _first_mesh(scene)
		scene.free()
		if found != null:
			return found
		Log.error("rocks", "%s has no mesh" % path)
	return _stand_in()


static func _first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return (node as MeshInstance3D).mesh
	for child in node.get_children():
		var m := _first_mesh(child)
		if m != null:
			return m
	return null


static func _stand_in() -> Mesh:
	var box := BoxMesh.new()
	box.size = STAND_IN_M
	var st := SurfaceTool.new()
	st.create_from(box, 0)
	var shifted := st.commit_to_arrays()
	var verts: PackedVector3Array = shifted[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] += Vector3(0.0, STAND_IN_M.y * 0.5, 0.0)
	shifted[Mesh.ARRAY_VERTEX] = verts
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, shifted)
	return out


static func _mipmapped(path: String) -> ImageTexture:
	var img := (load(path) as Texture2D).get_image()
	if img.is_compressed():
		img.decompress()
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
