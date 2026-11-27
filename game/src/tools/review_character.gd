extends SceneTree
## Review frames of a player body model (needs a display or a software
## renderer): front and side views, orthographic, with skin segments under a
## garment hidden as in the game (a mesh <garment>_<segment> hides
## skin_<segment>) and each garment tinted in its own grey.
## Usage: godot -s res://src/tools/review_character.gd -- FILE.glb OUT_PREFIX
## Writes OUT_PREFIX_front.png and OUT_PREFIX_side.png.

const SKIN := "skin_"
const SKIN_COLOR := Color(0.78, 0.66, 0.58)
const GARMENT_SHADES: Array[Color] = [
	Color(0.35, 0.42, 0.55), Color(0.3, 0.3, 0.28), Color(0.5, 0.36, 0.25), Color(0.55, 0.55, 0.5)
]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		printerr("usage: -- FILE.glb OUT_PREFIX")
		quit(2)
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(args[0], state) != OK:
		printerr("not a readable glTF: %s" % args[0])
		quit(1)
		return
	var scene := doc.generate_scene(state)
	root.add_child(scene)
	var meshes := scene.find_children("*", "MeshInstance3D", true, false)
	var covered := {}
	var garments: Array[String] = []
	for m: MeshInstance3D in meshes:
		var n := String(m.name)
		if not n.begins_with(SKIN):
			var cut := n.find("_")
			covered[SKIN + n.substr(cut + 1)] = true
			if not garments.has(n.substr(0, cut)):
				garments.append(n.substr(0, cut))
	var top := 0.0
	for m: MeshInstance3D in meshes:
		var n := String(m.name)
		m.visible = not covered.has(n)
		var mat := StandardMaterial3D.new()
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		if n.begins_with(SKIN):
			mat.albedo_color = SKIN_COLOR
		else:
			var g := garments.find(n.substr(0, n.find("_")))
			mat.albedo_color = GARMENT_SHADES[g % GARMENT_SHADES.size()]
			mat.roughness = 0.9
		m.material_override = mat
		top = maxf(top, (m.global_transform * m.get_aabb()).end.y)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.2, 0.22, 0.25)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.45, 0.45, 0.45)
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30, 20, 0)
	root.add_child(sun)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = top * 1.1
	root.add_child(cam)
	for view: Array in [["front", Vector3(0, 0, 4)], ["side", Vector3(4, 0, 0)]]:
		cam.position = Vector3(0, top * 0.5, 0) + (view[1] as Vector3)
		cam.look_at(Vector3(0, top * 0.5, 0))
		for f in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := "%s_%s.png" % [args[1], view[0]]
		root.get_texture().get_image().save_png(path)
		print("saved %s" % path)
	quit(0)
