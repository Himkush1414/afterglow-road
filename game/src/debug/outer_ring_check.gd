extends Node3D
## T-05-9: from the eye at each named place, eight level views (45° apart,
## 60° wide) with a magenta clear colour; any magenta pixel below the
## horizon is a gap the outer ring, the terrain or the sea should close.
## The horizon is the true one: the dip below eye level of the sea horizon
## seen from the eye's height on a round earth (Q-91); the camera is level.
## Needs a display:
##   tools/godot.sh res://scenes/debug/outer_ring_check.tscn \
##       [--rendering-method mobile] -- --places <id,id> [--eye 1.62] [--out <abs dir>]
## Places come from world/pois.json. Prints one line per view, then
## RESULT PASS or FAIL (exit code 0 or 1).

const CLEAR := Color(1.0, 0.0, 1.0)
const VIEWS := 8
const FOV_DEG := 60.0
const FAR_M := 65000.0
const SETTLE_FRAMES := 3
## Mean earth radius (dip of the sea horizon).
const EARTH_R_M := 6371000.0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		printerr("outer ring check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var vp := get_viewport()
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false
	var world := WorldData.new()
	add_child(world)
	var terrain := Terrain.new()
	add_child(terrain)
	var water := Water.new()
	add_child(water)
	var ring := OuterRing.new()
	add_child(ring)
	var layers: Array = ContentDB.tuning("terrain").get("layers", [])
	var ok := world.load_dir(WorldData.default_dir())
	ok = ok and terrain.setup(world) and water.setup(world)
	ok = ok and ring.setup(world, layers, terrain.layer_means)
	if not ok:
		printerr(
			(
				"outer ring check: %s"
				% ", ".join(world.errors + terrain.errors + water.errors + ring.errors)
			)
		)
		get_tree().quit(2)
		return
	water.build(terrain.height_texture())
	var places := places_at(world, _arg(args, "--places", "").split(",", false))
	if places.is_empty():
		printerr("outer ring check: no --places found in pois.json")
		get_tree().quit(2)
		return
	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = FOV_DEG
	cam.near = 0.1
	cam.far = FAR_M
	add_child(cam)
	cam.make_current()
	_add_light_and_clear()
	var eye := float(_arg(args, "--eye", "1.62"))
	var out := _arg(args, "--out", "")
	var method := RenderingServer.get_current_rendering_method()
	var total := 0
	for id: String in places:
		var p: Vector3 = places[id]
		var at := world.map_to_world(Vector3(p.x, p.y + eye, p.z))  # y: final height from pois.json
		for v in VIEWS:
			cam.global_transform = Transform3D(Basis(Vector3.UP, -TAU * v / VIEWS), at)
			for f in SETTLE_FRAMES:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			var gaps := count_below(img, horizon_row(img, eye + p.y))
			total += gaps
			print(
				(
					"%s heading %3d deg: %d magenta pixels below the horizon"
					% [id, v * 360 / VIEWS, gaps]
				)
			)
			if out != "":
				DirAccess.make_dir_recursive_absolute(out)
				img.save_png(out.path_join("outer_%s_%s_%03d.png" % [method, id, v * 360 / VIEWS]))
	print(
		(
			"ring triangles %d; RESULT %s (%d pixels, %s)"
			% [ring.triangles, "PASS" if total == 0 else "FAIL", total, method]
		)
	)
	get_tree().quit(0 if total == 0 else 1)


## Map positions of the listed places in pois.json.
static func places_at(world: WorldData, ids: PackedStringArray) -> Dictionary:
	var out := {}
	var doc: Variant = JSON.parse_string(world.read_text("pois.json"))
	if not doc is Dictionary:
		return out
	for p: Dictionary in doc.get("pois", []):
		if p.id in ids:
			out[p.id] = Vector3(float(p.x), float(p.y), float(p.z))
	return out


## First image row below the true horizon for an eye `height_m` above the
## sea (level camera, FOV_DEG across the width).
static func horizon_row(img: Image, height_m: float) -> int:
	var dip := sqrt(2.0 * maxf(height_m, 0.0) / EARTH_R_M)
	var focal := img.get_width() * 0.5 / tan(deg_to_rad(FOV_DEG) * 0.5)
	return img.get_height() / 2 + ceili(focal * tan(dip)) + 1


## Magenta pixels from row `top` down.
static func count_below(img: Image, top: int) -> int:
	var n := 0
	for y in range(top, img.get_height()):
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.9 and c.b > 0.9 and c.g < 0.1:
				n += 1
	return n


func _add_light_and_clear() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -20.0, 0.0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = CLEAR
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	add_child(env)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
