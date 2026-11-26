extends Node
## Vegetation scene budgets (23 §4, P5-10): starts the game with the local
## content and a quality preset, stands a camera at eye height on map point
## (x, z), waits until loading, ground cover and trees are settled, and
## reads the frame counters (draw calls and triangles of the main and the
## shadow passes) looking toward four headings. Prints each heading and the
## share of the ground cover, the trees and each tree tier (near T0, near
## T1, near T0 and T1 shadow casters, mid-tier chunks, billboard tiles) in the
## heaviest one, and checks
## each counter's largest value against the budget of the renderer:
## Forward+ uses the desktop budget, Mobile the phone budget. Needs a display:
##   tools/godot.sh [--rendering-method mobile] res://scenes/debug/veg_budget_check.tscn \
##       -- <preset> <map x> <map z> [frame.png]
## Prints the numbers, then RESULT PASS or FAIL (exit 0 or 1).

const SAVES := "user://veg_budget_saves"
const EYE_M := 1.62
## [draw calls, main-pass triangles, shadow-pass triangles] (23 §4).
const DESKTOP := [2000, 3000000, 2500000]
const PHONE := [450, 450000, 250000]
## Tree tier groups whose share is reported (see Runner._tier_of).
const TIERS := ["near_t0", "near_t1", "near_t0_shadow", "near_t1_shadow", "mid", "tile"]


## Runs from the tree root: starting the game replaces the current scene.
class Runner:
	extends Node

	func _ready() -> void:
		_run.call_deferred()

	func _run() -> void:
		if DisplayServer.get_name() == "headless":
			printerr("veg budget check: needs a display (run without --headless)")
			get_tree().quit(3)
			return
		var args := OS.get_cmdline_user_args()
		if args.size() < 3 or not Quality.apply(args[0], get_tree().root):
			printerr("veg budget check: needs -- <preset> <map x> <map z> [frame.png]")
			get_tree().quit(2)
			return
		# Own folder per run: checks may run side by side.
		SaveGame.saves_dir = "%s_%d" % [SAVES, OS.get_process_id()]
		if await App.start_game("slot_1", true) != OK:
			printerr("veg budget check: the game did not start")
			get_tree().quit(2)
			return
		var game := Game.current
		game.clock.paused = true
		var at := game.world.map_to_world(Vector3(float(args[1]), 0.0, float(args[2])))
		at.y = game.world.height_at(at.x, at.z) + EYE_M
		var cam := Camera3D.new()
		cam.fov = 70.0
		cam.far = 65000.0
		game.add_child(cam)
		cam.make_current()
		cam.look_at_from_position(at, at + Vector3(0.0, 0.0, -1.0))
		for i in 3000:
			_close_pause_menu(game)
			await get_tree().process_frame
			var grass_done := game.grass_field == null or game.grass_field.is_settled()
			if not App.loading.visible and grass_done and game.tree_field.is_settled():
				break
		var mobile := RenderingServer.get_current_rendering_method() == "mobile"
		var budget: Array = PHONE if mobile else DESKTOP
		var worst := [0, 0, 0]
		var worst_heading := 0
		var score := -1
		for heading: int in [0, 90, 180, 270]:
			var h := deg_to_rad(heading)
			cam.look_at_from_position(at, at + Vector3(sin(h), -0.05, -cos(h)))
			var c := await _counters(game)
			print(
				(
					"heading %3d: %d draw calls, %d triangles, shadow %d triangles"
					% [heading, c[0], c[1], c[2]]
				)
			)
			if c[1] + c[2] > score:
				score = c[1] + c[2]
				worst_heading = heading
			for k in 3:
				worst[k] = maxi(worst[k], c[k])
		if args.size() > 3:
			var h := deg_to_rad(worst_heading)
			cam.look_at_from_position(at, at + Vector3(sin(h), -0.05, -cos(h)))
			await _counters(game)
			get_viewport().get_texture().get_image().save_png(args[3])
			print("frame saved: %s" % args[3])
		var h := deg_to_rad(worst_heading)
		cam.look_at_from_position(at, at + Vector3(sin(h), -0.05, -cos(h)))
		var full := await _counters(game)
		if game.grass_field != null:
			game.grass_field.visible = false
			var g := await _counters(game)
			game.grass_field.visible = true
			print(
				"ground cover share: %d draw calls, %d triangles" % [full[0] - g[0], full[1] - g[1]]
			)
		game.tree_field.visible = false
		var t := await _counters(game)
		game.tree_field.visible = true
		print(
			(
				"tree share: %d draw calls, %d triangles, shadow %d triangles"
				% [full[0] - t[0], full[1] - t[1], full[2] - t[2]]
			)
		)
		for tier: String in TIERS:
			var hidden: Array[Node3D] = []
			for node in game.tree_field.find_children("*", "Node3D", true, false):
				var n := node as Node3D
				if n.visible and _tier_of(n) == tier:
					n.visible = false
					hidden.append(n)
			var s := await _counters(game)
			for n in hidden:
				n.visible = true
			print(
				(
					"tree tier %s: %d nodes, %d draw calls, %d triangles, shadow %d triangles"
					% [tier, hidden.size(), full[0] - s[0], full[1] - s[1], full[2] - s[2]]
				)
			)
		var bad := 0
		for k in 3:
			var ok: bool = worst[k] <= budget[k]
			bad += int(not ok)
			print(
				(
					"%s: %d (budget %d)%s"
					% [
						["draw calls", "main triangles", "shadow triangles"][k],
						worst[k],
						budget[k],
						_flag(ok)
					]
				)
			)
		print("RESULT %s" % ("PASS" if bad == 0 else "FAIL"))
		get_tree().quit(0 if bad == 0 else 1)

	## [draw calls, main triangles, shadow triangles] of a settled frame.
	func _counters(game: Game) -> Array:
		for i in 4:
			_close_pause_menu(game)
			await RenderingServer.frame_post_draw
		var vp := get_viewport().get_viewport_rid()
		var info := func(kind: int, what: int) -> int:
			return RenderingServer.viewport_get_render_info(vp, kind, what)
		return [
			info.call(
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
				RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME
			),
			info.call(
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
			),
			info.call(
				RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
				RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME
			),
		]

	func _close_pause_menu(game: Game) -> void:
		var menu := game.get_node_or_null("UI/PauseMenu")
		if menu and menu.visible:
			menu.close()

	## The tier group of a TreeField node by its name (TreeField names them
	## Near_<model>_<t0|t1|t0_shadow|t1_shadow>_<n>, Mid_<model>, Tile_<x>_<z>), or "".
	static func _tier_of(n: Node3D) -> String:
		var name := String(n.name)
		if name.begins_with("Mid_"):
			return "mid"
		if name.begins_with("Tile_"):
			return "tile"
		if not name.begins_with("Near_"):
			return ""
		var parts := name.split("_")
		if parts.size() >= 4 and parts[parts.size() - 2] == "shadow":
			return "near_%s_shadow" % parts[parts.size() - 3]
		return "near_" + parts[parts.size() - 2] if parts.size() >= 4 else ""

	static func _flag(ok: bool) -> String:
		return "" if ok else "  <-- FAIL"


func _ready() -> void:
	get_tree().root.add_child.call_deferred(Runner.new())
