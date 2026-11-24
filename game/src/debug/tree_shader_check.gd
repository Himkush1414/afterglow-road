extends Node
## Tree materials (06 §A3): renders one tree model with foliage.gdshader and
## its billboard with impostor.gdshader and checks
## - hand-over: the same mesh drawn as tier k and tier k + 1 at the boundary
##   between them covers what one tier alone covers (complementary dither),
##   for the boundaries T0/T1, T1/T2 and T2/T3;
## - ranges: a tier draws nothing well outside its range;
## - billboard: the quad faces the camera from four sides (same coverage);
## and saves a frame of the tiers side by side when an output path is given.
## Needs a display and local tree models and textures:
##   tools/godot.sh [--rendering-method mobile] res://scenes/debug/tree_shader_check.tscn \
##       -- <tree id> <bark set> <leaf set> [<frame.png>]
## Prints one line per case, then RESULT PASS or FAIL (exit 0 or 1).

const SIZE := 384
const FOV := 8.0
## Test ranges (metres), not a preset: [T0 end, T1 end, T2 end, T3 end].
const TIERS := [40.0, 120.0, 450.0, 2400.0]
const HANDOVER_TOL := 0.03
const FACING_TOL := 0.10
const MODEL_DIR := "assets/models/trees"
const TEXTURE_DIR := "assets/texture_sets/trees/hi"
const BACKGROUND := Color(1.0, 0.0, 1.0)

var _vp: SubViewport
var _cam: Camera3D
var _root: Node3D
var _id := ""
var _bark := ""
var _leaf := ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("tree shader check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var args := OS.get_cmdline_user_args()
	var cfg := ContentDB.tuning("trees")
	if args.size() < 3 or cfg.is_empty():
		printerr("tree shader check: needs -- <tree id> <bark set> <leaf set> and the trees group")
		get_tree().quit(2)
		return
	_id = args[0]
	_bark = args[1]
	_leaf = args[2]
	var tree_def := ContentDB.entry("trees", _id)
	TreeShading.push(cfg, TIERS)
	_setup()
	var meshes := _tier_meshes()
	if meshes.size() != 3 or tree_def.is_empty():
		printerr("tree shader check: no model or definition for %s" % _id)
		get_tree().quit(2)
		return
	var height := float(tree_def.height_m)
	var flex := TreeShading.flex(cfg, String(tree_def.species))
	var bad := 0
	# Hand-over T0/T1 and T1/T2 with the same mesh in both tiers.
	for k in 2:
		var boundary: float = TIERS[k]
		var both := await _coverage(
			[
				_tree(meshes[k + 1], k, height, flex, boundary),
				_tree(meshes[k + 1], k + 1, height, flex, boundary),
			],
			boundary,
			height
		)
		# Reference: the same view with tier k ending 30 m earlier, so only
		# tier k + 1 draws the tree.
		var shifted := TIERS.duplicate()
		shifted[k] = boundary - 30.0
		TreeShading.push(cfg, shifted)
		var one := await _coverage(
			[_tree(meshes[k + 1], k + 1, height, flex, boundary)], boundary, height
		)
		TreeShading.push(cfg, TIERS)
		bad += _report("hand-over T%d/T%d at %.0f m" % [k, k + 1, boundary], both, one)
	# Hand-over T2/T3: the billboard against itself is covered by the T3 check;
	# here T2 and T3 at their boundary must together cover what T3 covers past it.
	var b23: float = TIERS[2]
	var billboard := _billboard(flex)
	var t23 := await _coverage(
		[_tree(meshes[2], 2, height, flex, b23), billboard.call(b23, 0.0)], b23, height
	)
	var shifted23 := TIERS.duplicate()
	shifted23[2] = b23 - 30.0
	TreeShading.push(cfg, shifted23)
	var t3 := await _coverage([billboard.call(b23, 0.0)], b23, height)
	TreeShading.push(cfg, TIERS)
	print("hand-over T2/T3 at %.0f m: %d px together, %d px billboard alone" % [b23, t23, t3])
	bad += int(t23 == 0 or t3 == 0)
	# Ranges: T0 past its end and T2 well inside T1 draw nothing.
	var t0_far := await _coverage([_tree(meshes[0], 0, height, flex, 80.0)], 80.0, height)
	var t2_near := await _coverage([_tree(meshes[2], 2, height, flex, 60.0)], 60.0, height)
	var ranges_ok := t0_far == 0 and t2_near == 0
	bad += int(not ranges_ok)
	print("ranges: T0 at 80 m %d px, T2 at 60 m %d px%s" % [t0_far, t2_near, _flag(ranges_ok)])
	# Billboard facing: the same coverage seen from four sides.
	var seen: Array = []
	for side in 4:
		seen.append(
			await _coverage(
				[billboard.call(600.0, side * PI * 0.5)], 600.0, height, side * PI * 0.5
			)
		)
	var lo: float = seen.min()
	var hi: float = seen.max()
	var facing_ok := lo > 0 and (hi - lo) / hi <= FACING_TOL
	bad += int(not facing_ok)
	print("billboard from 4 sides: %s px%s" % [str(seen), _flag(facing_ok)])
	if args.size() >= 4:
		await _frame(meshes, height, flex, billboard, args[3])
	var method := RenderingServer.get_current_rendering_method()
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)


func _setup() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(SIZE, SIZE)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.5, 0.5)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 30.0, 0.0)
	_vp.add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = FOV
	_cam.far = 4000.0
	_vp.add_child(_cam)
	_root = Node3D.new()
	_vp.add_child(_root)
	add_child(_vp)


func _tier_meshes() -> Array:
	var path := (ContentDB.root as String).path_join(MODEL_DIR).path_join("tree_%s_1.glb" % _id)
	if not ResourceLoader.exists(path):
		return []
	var node := (load(path) as PackedScene).instantiate()
	var out: Array = []
	for tier in 3:
		for child in node.find_children("*_t%d" % tier, "MeshInstance3D", true, false):
			out.append((child as MeshInstance3D).mesh)
	node.free()
	return out


func _material(tier: int, leaves: bool, height: float, flex: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/foliage.gdshader")
	var dir := (ContentDB.root as String).path_join(TEXTURE_DIR)
	var stem := "tree_%s_%s" % [_leaf, "leaves_ca"] if leaves else "tree_%s_%s" % [_bark, "bark_ah"]
	var nra := (
		"tree_%s_%s" % [_leaf, "leaves_nra"] if leaves else "tree_%s_%s" % [_bark, "bark_nra"]
	)
	m.set_shader_parameter("albedo_tex", load(dir.path_join(stem + ".png")))
	m.set_shader_parameter("normal_rough_ao", load(dir.path_join(nra + ".png")))
	m.set_shader_parameter("tier", tier)
	m.set_shader_parameter("leaves", leaves)
	m.set_shader_parameter("height_m", height)
	m.set_shader_parameter("flex", flex)
	return m


## A tree tier at `distance` m straight ahead of the camera.
func _tree(mesh: Mesh, tier: int, height: float, flex: float, distance: float) -> Node3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	for s in mesh.get_surface_count():
		mi.set_surface_override_material(s, _material(tier, s == 1, height, flex))
	mi.position = Vector3(0.0, 0.0, -distance)
	return mi


## Callable(distance, yaw) -> the billboard of the model at `distance` m, its
## quad turned by `yaw` (the shader must turn it back to face the camera).
func _billboard(flex: float) -> Callable:
	var manifest_path := (ContentDB.root as String).path_join(MODEL_DIR).path_join(
		"tree_models.json"
	)
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
	var entry: Dictionary = manifest.models["tree_%s_1" % _id]
	var quad := ArrayMesh.new()
	var a := []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = PackedVector3Array(
		[Vector3(-0.5, 0, 0), Vector3(0.5, 0, 0), Vector3(0.5, 1, 0), Vector3(-0.5, 1, 0)]
	)
	a[Mesh.ARRAY_TEX_UV] = PackedVector2Array(
		[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	)
	a[Mesh.ARRAY_NORMAL] = PackedVector3Array(
		[Vector3.BACK, Vector3.BACK, Vector3.BACK, Vector3.BACK]
	)
	a[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	var m := ShaderMaterial.new()
	m.shader = load("res://shaders/impostor.gdshader")
	var dir := (ContentDB.root as String).path_join(TEXTURE_DIR)
	m.set_shader_parameter("atlas_ca", load(dir.path_join("tree_billboards_ca.png")))
	m.set_shader_parameter("atlas_n", load(dir.path_join("tree_billboards_n.png")))
	m.set_shader_parameter("atlas_grid", float(manifest.grid))
	var flexes := PackedFloat32Array()
	flexes.resize(64)
	flexes[int(entry.cell)] = flex
	m.set_shader_parameter("cell_flex", flexes)
	var side := float(entry.side_m)
	var bottom := float(entry.bottom_m)
	return func(distance: float, yaw: float) -> Node3D:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = quad
		mm.instance_count = 1
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(side, side, side))
		mm.set_instance_transform(0, Transform3D(basis, Vector3(0.0, bottom, -distance)))
		mm.set_instance_custom_data(0, Color(0.0, 0.0, 0.0, float(entry.cell)))
		var node := MultiMeshInstance3D.new()
		node.multimesh = mm
		node.material_override = m
		return node


## Non-background pixels with `nodes` shown, camera at 1.6 m looking at the
## tree's middle at `distance`; nodes are freed afterwards. `orbit` turns the
## camera around the tree (radians), keeping the distance.
func _coverage(nodes: Array, distance: float, height: float, orbit := 0.0) -> int:
	var target := Vector3(0.0, height * 0.5, -distance)
	var eye := target + Vector3(sin(orbit), 0.0, cos(orbit)) * distance
	eye.y = 1.6
	_cam.look_at_from_position(eye, target)
	TreeShading.set_camera(eye)
	for n: Node3D in nodes:
		_root.add_child(n)
	for i in 3:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	for n: Node3D in nodes:
		n.queue_free()
	await get_tree().process_frame
	var count := 0
	for y in SIZE:
		for x in SIZE:
			var c := img.get_pixel(x, y)
			if absf(c.r - 1.0) + c.g + absf(c.b - 1.0) > 0.05:
				count += 1
	return count


func _report(what: String, both: int, one: int) -> int:
	var ok := one > 0 and absf(both - one) <= HANDOVER_TOL * one
	print("%s: %d px together, %d px one tier%s" % [what, both, one, _flag(ok)])
	return int(not ok)


## T0, T1, T2 and the billboard side by side, each at the middle of its range.
func _frame(meshes: Array, height: float, flex: float, billboard: Callable, path: String) -> void:
	var img := Image.create(SIZE * 4, SIZE, false, Image.FORMAT_RGBA8)
	var at := [20.0, 80.0, 300.0, 900.0]
	for k in 4:
		var node: Node3D = (
			_tree(meshes[k], k, height, flex, at[k]) if k < 3 else billboard.call(at[k], 0.0)
		)
		var target := Vector3(0.0, height * 0.5, -at[k])
		_cam.look_at_from_position(Vector3(0.0, 1.6, 0.0), target)
		_cam.fov = rad_to_deg(2.0 * atan(height * 0.7 / at[k]))
		TreeShading.set_camera(Vector3(0.0, 1.6, 0.0))
		_root.add_child(node)
		for i in 3:
			await RenderingServer.frame_post_draw
		var shot := _vp.get_texture().get_image()
		shot.convert(Image.FORMAT_RGBA8)
		img.blit_rect(shot, Rect2i(0, 0, SIZE, SIZE), Vector2i(k * SIZE, 0))
		node.queue_free()
		await get_tree().process_frame
	_cam.fov = FOV
	img.save_png(path)
	print("frame: %s" % path)


func _flag(ok: bool) -> String:
	return "" if ok else "  FAIL"
