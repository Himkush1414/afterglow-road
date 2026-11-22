extends Node3D
## Cloud shadows (P4-03): (1) the shared cloud_direct_light, with no clouds,
## lights a grey plane like the built-in lighting does (mean brightness
## within MATCH_TOL); (2) seen from above at noon, the terrain under cloud
## cover has a share of clearly darker pixels (direct light × 0.5 under a
## cloud) between SHARE_MIN and SHARE_MAX of the cloudless frame.
## Needs a display:
##   tools/godot.sh res://scenes/debug/cloud_shadow_check.tscn \
##       [--rendering-method mobile] -- [--place <poi id>] [--cover 0.5] [--out <abs dir>]
## Prints the measurements, then RESULT PASS or FAIL (exit code 0 or 1).

const MATCH_TOL := 0.08
const DARKER := 0.85
const SHARE_MIN := 0.05
const SHARE_MAX := 0.95
const SETTLE_FRAMES := 30
const PROBE_SHADER := """shader_type spatial;
#include "res://shaders/common/cloud_shadow.gdshaderinc"
varying vec3 v_world;
void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	ALBEDO = vec3(0.5);
	ROUGHNESS = 0.95;
}
void light() {
	cloud_direct_light(v_world, NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL,
			ROUGHNESS, METALLIC, DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
"""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless":
		printerr("cloud shadow check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var vp := get_viewport()
	var out := _arg(args, "--out", "")
	var method := RenderingServer.get_current_rendering_method()
	var bad := 0
	var clock := GameClock.new()
	add_child(clock)
	clock.configure(ContentDB.tuning("clock"))
	clock.paused = true
	var lights := SkyLights.new()
	add_child(lights)
	var dome := SkyDome.new()
	add_child(dome)
	if not lights.setup(clock, ContentDB.tuning("sky")) or not dome.setup(clock, lights, 128):
		printerr("cloud shadow check: %s" % ", ".join(lights.errors + dome.errors))
		get_tree().quit(2)
		return
	var noon := float(ContentDB.tuning("clock").solar_noon_h) * 60.0
	clock.set_now(noon)
	lights.apply(noon)
	dome.show_minute(int(noon))
	var cam := Camera3D.new()
	cam.far = 20000.0
	add_child(cam)
	cam.make_current()

	# (1) The light model against the built-in one, no clouds.
	var built_in := StandardMaterial3D.new()
	built_in.albedo_color = Color(0.5, 0.5, 0.5).linear_to_srgb()
	built_in.roughness = 0.95
	var probe := ShaderMaterial.new()
	probe.shader = Shader.new()
	probe.shader.code = PROBE_SHADER
	var planes: Array[MeshInstance3D] = []
	for i in 2:
		var plane := MeshInstance3D.new()
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(4.0, 4.0)
		plane.mesh = mesh
		plane.material_override = built_in if i == 0 else probe
		plane.position = Vector3(-2.2 + 4.4 * i, 5000.0, 0.0)
		add_child(plane)
		planes.append(plane)
	cam.global_transform = Transform3D(
		Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0)), Vector3(0.0, 5009.0, 0.0)
	)
	var img := await _frame(vp)
	var w := img.get_width()
	var h := img.get_height()
	var left := _mean(img, Rect2i(w * 3 / 16, h * 3 / 8, w / 8, h / 4))
	var right := _mean(img, Rect2i(w * 11 / 16, h * 3 / 8, w / 8, h / 4))
	var ratio := right / maxf(left, 1e-4)
	var match_ok := absf(ratio - 1.0) <= MATCH_TOL
	bad += int(not match_ok)
	print(
		(
			"light model: built-in %.3f, shared %.3f, ratio %.3f (want 1 +- %.2f)%s"
			% [left, right, ratio, MATCH_TOL, "" if match_ok else "  FAIL"]
		)
	)
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
		img.save_png(out.path_join("light_model_%s.png" % method))
	for plane in planes:
		plane.queue_free()

	# (2) Cloud shadows on the terrain.
	var world := WorldData.new()
	add_child(world)
	var terrain := Terrain.new()
	add_child(terrain)
	if not world.load_dir(WorldData.default_dir()) or not terrain.setup(world):
		printerr("cloud shadow check: %s" % ", ".join(world.errors + terrain.errors))
		get_tree().quit(2)
		return
	var at := Vector3.ZERO
	var place := _arg(args, "--place", "")
	var doc: Variant = JSON.parse_string(world.read_text("pois.json"))
	if place != "" and doc is Dictionary:
		for p: Dictionary in doc.get("pois", []):
			if p.id == place:
				at = world.map_to_world(Vector3(float(p.x), float(p.y), float(p.z)))
	at.y = world.height_at(at.x, at.z)
	cam.global_transform = Transform3D(
		Basis.from_euler(Vector3(deg_to_rad(-55.0), 0.0, 0.0)), at + Vector3(0.0, 350.0, 250.0)
	)
	var clear := await _frame(vp)
	dome.cloud_cover = float(_arg(args, "--cover", "0.5"))
	lights.cloud_cover = 0.0  # keep the sun's energy: only the shadow differs
	dome.show_minute(int(noon) + 1)
	var cloudy := await _frame(vp)
	var share := _darker_share(clear, cloudy)
	var share_ok := share >= SHARE_MIN and share <= SHARE_MAX
	bad += int(not share_ok)
	print(
		(
			"terrain, cover %.2f: %.1f%% of pixels < %.2f x cloudless (want %.0f-%.0f%%)%s"
			% [
				dome.cloud_cover,
				share * 100.0,
				DARKER,
				SHARE_MIN * 100.0,
				SHARE_MAX * 100.0,
				"" if share_ok else "  FAIL"
			]
		)
	)
	if out != "":
		clear.save_png(out.path_join("terrain_clear_%s.png" % method))
		cloudy.save_png(out.path_join("terrain_cloudy_%s.png" % method))
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)


func _frame(vp: Viewport) -> Image:
	for f in SETTLE_FRAMES:
		await RenderingServer.frame_post_draw
	return vp.get_texture().get_image()


## Mean linear red-green-blue brightness over `rect`.
static func _mean(img: Image, rect: Rect2i) -> float:
	var sum := 0.0
	for y in range(rect.position.y, rect.end.y, 4):
		for x in range(rect.position.x, rect.end.x, 4):
			var c := img.get_pixel(x, y).srgb_to_linear()
			sum += (c.r + c.g + c.b) / 3.0
	return sum / float(ceili(rect.size.x / 4.0) * ceili(rect.size.y / 4.0))


## Share of pixels in the lower two thirds (ground) that are below DARKER
## times their cloudless value.
static func _darker_share(clear: Image, cloudy: Image) -> float:
	var n := 0
	var dark := 0
	for y in range(clear.get_height() / 3, clear.get_height(), 4):
		for x in range(0, clear.get_width(), 4):
			var a := clear.get_pixel(x, y).srgb_to_linear()
			var b := cloudy.get_pixel(x, y).srgb_to_linear()
			var la := a.r + a.g + a.b
			if la < 0.03:
				continue
			n += 1
			if b.r + b.g + b.b < DARKER * la:
				dark += 1
	return float(dark) / maxf(float(n), 1.0)


static func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
