extends Node
## Ground-cover streaming in the game (06 §B2, T-06-10): starts the game
## with the local content, stands a camera at eye height on map point
## (x, z) looking along +x, waits until the ground cover around it is built,
## then moves the camera `STEP_M` per frame along +x for `FRAMES` frames,
## crossing cells. Reports the longest worker build of one cell (limit
## 4 ms) and the longest main-thread GrassField update (limit 1 ms), and
## saves a frame at the start when an output path is given. Needs a display:
##   tools/godot.sh res://scenes/debug/grass_stream_check.tscn \
##       -- <map x> <map z> [preset] [frame.png]
## Prints the numbers, then RESULT PASS or FAIL (exit 0 or 1).

const SAVES := "user://grass_check_saves"
const EYE_M := 1.62
const STEP_M := 1.0
const FRAMES := 160
const BUILD_LIMIT_USEC := 4000
const UPDATE_LIMIT_USEC := 1000


## Runs from the tree root: starting the game replaces the current scene.
class Runner:
	extends Node

	func _ready() -> void:
		_run.call_deferred()

	func _run() -> void:
		if DisplayServer.get_name() == "headless":
			printerr("grass stream check: needs a display (run without --headless)")
			get_tree().quit(3)
			return
		var args := OS.get_cmdline_user_args()
		if args.size() < 2:
			printerr("grass stream check: needs -- <map x> <map z> [preset] [frame.png]")
			get_tree().quit(2)
			return
		var preset := args[2] if args.size() > 2 else "desk_high"
		if not Quality.apply(preset, get_tree().root):
			get_tree().quit(2)
			return
		SaveGame.saves_dir = SAVES
		if await App.start_game("slot_1", true) != OK:
			printerr("grass stream check: the game did not start")
			get_tree().quit(2)
			return
		var game := Game.current
		var grass := game.grass_field
		if grass == null or grass.draws.is_empty():
			printerr("grass stream check: no ground cover (grass tuning or models missing)")
			get_tree().quit(2)
			return
		game.clock.paused = true
		# The check drives the updates itself, one per frame, paused or not.
		grass.set_process(false)
		var at := game.world.map_to_world(Vector3(float(args[0]), 0.0, float(args[1])))
		var cam := Camera3D.new()
		cam.fov = 70.0
		cam.far = 65000.0
		game.add_child(cam)
		cam.make_current()
		_place(game, cam, at)
		for i in 600:
			_close_pause_menu(game)
			grass.update(cam.global_position)
			await get_tree().process_frame
			if grass.is_settled():
				break
		print("settled with %d plants in %d cells" % [grass.instances, grass.added_cells().size()])
		if args.size() > 3:
			for i in 600:
				if not App.loading.visible:
					break
				_close_pause_menu(game)
				grass.update(cam.global_position)
				await get_tree().process_frame
			for i in 3:
				await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(args[3])
			print("frame saved: %s" % args[3])
		grass.worst_update_usec = 0
		var most := 0
		for f in FRAMES:
			at.x += STEP_M
			_place(game, cam, at)
			_close_pause_menu(game)
			grass.update(cam.global_position)
			await get_tree().process_frame
			most = maxi(most, grass.instances)
		var build_ok := grass.worst_build_usec <= BUILD_LIMIT_USEC
		var update_ok := grass.worst_update_usec <= UPDATE_LIMIT_USEC
		print("walked %.0f m: up to %d plants" % [FRAMES * STEP_M, most])
		print(
			(
				"worst cell build %.2f ms (limit 4)%s"
				% [grass.worst_build_usec / 1000.0, _flag(build_ok)]
			)
		)
		print(
			(
				"worst main-thread update %.2f ms (limit 1)%s"
				% [grass.worst_update_usec / 1000.0, _flag(update_ok)]
			)
		)
		var ok := build_ok and update_ok
		print("RESULT %s" % ("PASS" if ok else "FAIL"))
		get_tree().quit(0 if ok else 1)

	func _close_pause_menu(game: Game) -> void:
		var menu := game.get_node_or_null("UI/PauseMenu")
		if menu and menu.visible:
			menu.close()

	func _place(game: Game, cam: Camera3D, at: Vector3) -> void:
		var eye := Vector3(at.x, game.world.height_at(at.x, at.z) + EYE_M, at.z)
		cam.look_at_from_position(eye, eye + Vector3(1.0, -0.15, 0.0))

	static func _flag(ok: bool) -> String:
		return "" if ok else "  <-- FAIL"


func _ready() -> void:
	get_tree().root.add_child.call_deferred(Runner.new())
