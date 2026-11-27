extends SceneTree
## Review frames of a retargeted clip on an imported player body (needs a
## display or a software renderer): the clip from an imported animation
## source (or an AnimationLibrary resource) is posed at the given shares of
## its length and rendered from the side and the front, with skin under a
## garment hidden as in the game.
## Usage: godot -s res://src/tools/review_animation.gd -- BODY ANIMS CLIP OUT_PREFIX [share ...]
## BODY and ANIMS are res:// paths; writes OUT_PREFIX_<share>_side.png and _front.png.

const SKIN := "skin_"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 4:
		printerr("usage: -- BODY ANIMS CLIP OUT_PREFIX [share ...]")
		quit(2)
		return
	var body: Node3D = (load(args[0]) as PackedScene).instantiate()
	root.add_child(body)
	_hide_covered(body)
	var library := _library(args[1])
	if library == null or not library.has_animation(args[2]):
		printerr("no clip %s in %s" % [args[2], args[1]])
		quit(1)
		return
	var player := AnimationPlayer.new()
	body.add_child(player)
	player.root_node = NodePath("..")
	player.add_animation_library("", library)
	var shares: Array[float] = [0.0, 0.25, 0.5, 0.75]
	if args.size() > 4:
		shares.clear()
		for a in args.slice(4):
			shares.append(float(a))
	_stage()
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 2.0
	root.add_child(cam)
	player.play(args[2])
	var length := library.get_animation(args[2]).length
	for share in shares:
		player.seek(share * length, true)
		player.pause()
		for view: Array in [["side", Vector3(4, 0, 0)], ["front", Vector3(0, 0, 4)]]:
			cam.position = Vector3(0, 0.95, 0) + (view[1] as Vector3)
			cam.look_at(Vector3(0, 0.95, 0))
			for f in 3:
				await process_frame
			await RenderingServer.frame_post_draw
			var path := "%s_%.2f_%s.png" % [args[3], share, view[0]]
			root.get_texture().get_image().save_png(path)
			print("saved %s" % path)
	quit(0)


func _library(path: String) -> AnimationLibrary:
	var res := load(path)
	if res is AnimationLibrary:
		return res
	if res is PackedScene:
		var scene := (res as PackedScene).instantiate()
		var players := scene.find_children("*", "AnimationPlayer", true, false)
		if not players.is_empty():
			return (players[0] as AnimationPlayer).get_animation_library("")
	return null


func _hide_covered(body: Node) -> void:
	var meshes := body.find_children("*", "MeshInstance3D", true, false)
	var covered := {}
	for m: MeshInstance3D in meshes:
		var n := String(m.name)
		if not n.begins_with(SKIN):
			covered[SKIN + n.substr(n.find("_") + 1)] = true
	for m: MeshInstance3D in meshes:
		m.visible = not covered.has(String(m.name))
		var mat := StandardMaterial3D.new()
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var skin := String(m.name).begins_with(SKIN)
		mat.albedo_color = Color(0.78, 0.66, 0.58) if skin else Color(0.4, 0.45, 0.55)
		m.material_override = mat


func _stage() -> void:
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
	var floor := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(4, 4)
	floor.mesh = plane
	root.add_child(floor)
