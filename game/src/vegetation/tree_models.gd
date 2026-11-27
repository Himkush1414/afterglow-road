class_name TreeModels
extends RefCounted
## The tree models and billboard material of a TreeField (06 §A3): reads the
## models manifest and atlas written by the asset tools, loads each model's
## tier meshes with their foliage materials, and makes the billboard
## material. Without manifest or atlas (sample content) every tree type gets
## one flat stand-in quad.

const MODEL_DIR := "assets/models/trees"
const TEXTURE_DIR := "assets/textures/trees"
const MANIFEST := "tree_models.json"
const SHADER := "res://shaders/impostor.gdshader"
const FOLIAGE := "res://shaders/foliage.gdshader"
const CELLS := 64
const T0 := TreeField.T0
const T1 := TreeField.T1
const T2 := TreeField.T2
const STAND_IN_COLOR := Color(0.25, 0.32, 0.2)

var errors: PackedStringArray = []
## Per tree type: [[cell, side_m, bottom_m, model index or -1] per variant].
var variants: Array = []
## Per model (index from variants): {"stem", "height_m", "meshes": [T0, T1, T2],
## "shadow": the T2 mesh with T1 materials, "shadow_t0": the T1 mesh with T0
## materials}.
var models: Array = []
## The billboard material (T3).
var material: ShaderMaterial

var _cfg := {}
var _textures := {}


## Fills variants, models and material for the tree types `defs` (file
## order) from the content folder `root`; `cfg`: the `trees` tuning group.
func load_all(root: String, defs: Array, cfg: Dictionary) -> void:
	_cfg = cfg
	var manifest_path := root.path_join(MODEL_DIR).path_join(MANIFEST)
	var atlas := root.path_join(TEXTURE_DIR).path_join("tree_billboards_%s.png")
	var manifest: Variant = null
	if FileAccess.file_exists(manifest_path) and ResourceLoader.exists(atlas % "ca"):
		manifest = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	material = ShaderMaterial.new()
	material.shader = load(SHADER)
	variants.clear()
	models.clear()
	var flexes := PackedFloat32Array()
	flexes.resize(CELLS)
	if manifest is Dictionary:
		var entries: Dictionary = manifest.get("models", {})
		for d: Dictionary in defs:
			var options: Array = []
			for stem: String in d.get("models", []):
				if not entries.has(stem):
					errors.append("%s: no billboard for model %s" % [MANIFEST, stem])
					continue
				var e: Dictionary = entries[stem]
				var model := _load_model(root, stem, e, d)
				options.append([int(e.cell), float(e.side_m), float(e.bottom_m), model])
				flexes[clampi(int(e.cell), 0, CELLS - 1)] = TreeShading.flex(
					_cfg, String(d.species)
				)
			variants.append(options)
		material.set_shader_parameter("atlas_ca", load(atlas % "ca"))
		material.set_shader_parameter("atlas_n", load(atlas % "n"))
		material.set_shader_parameter("atlas_grid", float(manifest.get("grid", 1)))
	else:
		for d: Dictionary in defs:
			var side := maxf(float(d.height_m), 2.0 * float(d.canopy_r_m))
			variants.append([[0, side, 0.0, -1]])
		material.set_shader_parameter("atlas_ca", _plain(STAND_IN_COLOR))
		material.set_shader_parameter("atlas_n", _plain(Color(0.5, 0.5, 1.0)))
		material.set_shader_parameter("atlas_grid", 1.0)
	material.set_shader_parameter("cell_flex", flexes)


## One surface holding all of a mesh's surfaces (bark and leaf cards share
## one material, Q-110).
static func merged_surfaces(mesh: Mesh) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in mesh.get_surface_count():
		st.append_from(mesh, s, Transform3D.IDENTITY)
	return st.commit()


## Loads a model's tier meshes and gives each tier surface its material;
## returns its index in models, or -1 (with an error) when it cannot.
func _load_model(root: String, stem: String, e: Dictionary, d: Dictionary) -> int:
	var path := root.path_join(MODEL_DIR).path_join(stem + ".glb")
	if not ResourceLoader.exists(path):
		errors.append("%s: missing" % path)
		return -1
	var node := (load(path) as PackedScene).instantiate()
	var meshes: Array = []
	for tier in 3:
		var found := node.find_children("*_t%d" % tier, "MeshInstance3D", true, false)
		meshes.append((found[0] as MeshInstance3D).mesh if not found.is_empty() else null)
	node.free()
	if meshes.has(null):
		errors.append("%s: missing a tier mesh" % path)
		return -1
	var dir := root.path_join(TEXTURE_DIR)
	var flex := TreeShading.flex(_cfg, String(d.species))
	for tier in 3:
		meshes[tier] = merged_surfaces(meshes[tier])
	# The T2 mesh again, faded as T1: the shadow caster of the T1 instances;
	# the T1 mesh again, faded as T0: the shadow caster of the T0 instances.
	var shadow: Mesh = (meshes[T2] as Mesh).duplicate()
	var shadow_t0: Mesh = (meshes[T1] as Mesh).duplicate()
	var bark: String = e.get("bark_set")
	var leaf: Variant = e.get("leaf_set")
	var targets: Array[Mesh] = [meshes[T0], meshes[T1], meshes[T2], shadow, shadow_t0]
	for tier in targets.size():
		var m := ShaderMaterial.new()
		m.shader = load(FOLIAGE)
		m.set_shader_parameter("tier", [T0, T1, T2, T1, T0][tier])
		m.set_shader_parameter("height_m", float(d.height_m))
		m.set_shader_parameter("flex", flex)
		m.set_shader_parameter("bark_albedo", _texture(dir, "tree_%s_bark_ah.png" % bark))
		m.set_shader_parameter("bark_nra", _texture(dir, "tree_%s_bark_nra.png" % bark))
		if leaf is String:
			m.set_shader_parameter("leaf_albedo", _texture(dir, "tree_%s_leaves_ca.png" % leaf))
			m.set_shader_parameter("leaf_nra", _texture(dir, "tree_%s_leaves_nra.png" % leaf))
		targets[tier].surface_set_material(0, m)
	(
		models
		. append(
			{
				"stem": stem,
				"height_m": float(d.height_m),
				"meshes": meshes,
				"shadow": shadow,
				"shadow_t0": shadow_t0,
			}
		)
	)
	return models.size() - 1


func _texture(dir: String, name: String) -> Texture2D:
	var path := dir.path_join(name)
	if not _textures.has(path):
		_textures[path] = load(path)
	return _textures[path]


static func _plain(c: Color) -> ImageTexture:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(c)
	return ImageTexture.create_from_image(img)
