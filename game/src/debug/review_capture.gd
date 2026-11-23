extends Node
## Review frames for the owner (25 §5): captures one named set of the
## optional "review" tuning group. The game starts a new game in a throwaway
## save folder, applies the set's quality preset for the renderer, and a
## camera stands at the set's place (eye height, heading, pitch, field of
## view). For each weather state of the set (one game day each) the weather
## is forced a blend early and its next roll held back, then the clock is
## set to each time and one frame is saved as
## <set>_<renderer>_<HHMM>_<weather>.png.
## Needs a display:
##   tools/godot.sh [--rendering-method mobile] res://scenes/debug/review_capture.tscn \
##       -- --set <name> --out <abs dir>
## Prints one line per frame, then RESULT PASS or FAIL (exit 0 or 1).

const SAVES := "user://review_saves"
const SETTLE_FRAMES := 60


class Runner:
	extends Node
	var set_name := ""
	var out := ""

	func _ready() -> void:
		_run.call_deferred()

	func _run() -> void:
		var sets: Dictionary = ContentDB.tuning("review").get("sets", {})
		if not sets.has(set_name) or out == "":
			printerr("review capture: unknown set '%s' or no --out" % set_name)
			get_tree().quit(2)
			return
		var cfg: Dictionary = sets[set_name]
		var method := RenderingServer.get_current_rendering_method()
		var preset := str((cfg.presets as Dictionary).get(method, ""))
		if preset != "" and not Quality.apply(preset, get_tree().root):
			get_tree().quit(2)
			return
		DirAccess.make_dir_recursive_absolute(out)
		SaveGame.saves_dir = SAVES
		if await App.start_game("slot_1", true) != OK:
			printerr("review capture: the game did not start")
			get_tree().quit(2)
			return
		var game := Game.current
		var cam := _camera(game, cfg)
		if cam == null:
			printerr("review capture: place '%s' not found" % cfg.place)
			get_tree().quit(2)
			return
		var blend := float(ContentDB.tuning("weather").blend_gmin)
		var day := 1
		var saved := 0
		for w: String in cfg.weathers:
			day += 1
			for t: String in cfg.times:
				var parts := t.split(":")
				var gmin := (day - 1) * GameClock.GMIN_PER_DAY + int(parts[0]) * 60 + int(parts[1])
				game.clock.paused = true
				if not game.weather.force(w, gmin - blend - 1.0):
					printerr("review capture: unknown weather '%s'" % w)
					get_tree().quit(2)
					return
				game.weather.next_change_gmin = INF  # no roll while the clock jumps
				game.clock.set_now(gmin)
				for f in SETTLE_FRAMES:
					await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var img := get_viewport().get_texture().get_image()
				var file := "%s_%s_%s_%s.png" % [set_name, method, t.replace(":", ""), w]
				if img.save_png(out.path_join(file)) == OK:
					saved += 1
				print("%s (%s, preset %s)" % [file, game.weather.state, preset])
		var want: int = (cfg.weathers as Array).size() * (cfg.times as Array).size()
		print(
			(
				"RESULT %s (%d of %d frames, %s)"
				% ["PASS" if saved == want else "FAIL", saved, want, method]
			)
		)
		get_tree().quit(0 if saved == want else 1)

	func _camera(game: Game, cfg: Dictionary) -> Camera3D:
		var doc: Variant = JSON.parse_string(
			game.world.read_text("pois.json") if game.world.has_layer("pois.json") else ""
		)
		if not doc is Dictionary:
			return null
		for p: Dictionary in doc.get("pois", []):
			if p.id != cfg.place:
				continue
			var at := game.world.map_to_world(Vector3(float(p.x), 0.0, float(p.z)))
			at.y = game.world.height_at(at.x, at.z) + float(cfg.eye_m)
			var cam := Camera3D.new()
			cam.fov = float(cfg.fov_deg)
			cam.far = 65000.0
			game.add_child(cam)
			var h := deg_to_rad(float(cfg.heading_deg))
			var pitch := deg_to_rad(float(cfg.pitch_deg))
			var look := Vector3(sin(h) * cos(pitch), sin(pitch), -cos(h) * cos(pitch))
			cam.look_at_from_position(at, at + look)
			cam.make_current()
			return cam
		return null


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("review capture: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var args := OS.get_cmdline_user_args()
	var runner := Runner.new()
	runner.set_name = _arg(args, "--set", "")
	runner.out = _arg(args, "--out", "")
	# Kept outside the current scene, which the game scene replaces.
	get_tree().root.add_child.call_deferred(runner)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
