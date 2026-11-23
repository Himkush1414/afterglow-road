extends Node
## Wind field CPU vs GPU (T-08-11): a 50 x 1 probe viewport runs the shader
## include's wind_speed_at for 50 points (one per pixel) and writes the speed
## as 16 bits (red high byte, green low byte, scaled to 2 x max_ms); each
## value is compared with Wind.speed_at for the same point and wind state.
## Several wind states are checked; each must differ by less than TOL.
## Needs a display:
##   tools/godot.sh res://scenes/debug/wind_check.tscn [--rendering-method mobile]
## Prints one line per state, then RESULT PASS or FAIL (exit 0 or 1).

const TOL := 0.05
const POINTS := 50
const SEED := 8111
## Wind states: [blows toward (deg), base m/s, gustiness, seconds advanced].
const STATES := [[30.0, 10.0, 0.5, 37.3], [200.0, 4.0, 0.8, 123.4], [295.0, 16.0, 0.3, 611.0]]
const PROBE := """
shader_type canvas_item;
#include "res://shaders/common/wind.gdshaderinc"
uniform vec3 points[50];
uniform float scale;

void fragment() {
	float s = clamp(wind_speed_at(points[int(FRAGCOORD.x)]) / scale, 0.0, 1.0);
	float q = floor(s * 65535.0 + 0.5);
	float hi = floor(q / 256.0);
	COLOR = vec4(hi / 255.0, (q - hi * 256.0) / 255.0, 0.0, 1.0);
}
"""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("wind check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var cfg := ContentDB.tuning("wind")
	var wind := Wind.new()  # kept out of the tree: no frame advance between draw and compare
	if not wind.configure(cfg):
		printerr("wind check: %s" % ", ".join(wind.errors))
		wind.free()
		get_tree().quit(2)
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var half := WorldData.REGION_M * WorldData.REGIONS_PER_SIDE * 0.5
	var pts := PackedVector3Array()
	for i in POINTS:
		pts.append(
			Vector3(
				rng.randf_range(-half, half),
				rng.randf_range(-50.0, 1600.0),
				rng.randf_range(-half, half)
			)
		)
	var scale := 2.0 * float(cfg.max_ms)
	var vp := SubViewport.new()
	vp.size = Vector2i(POINTS, 1)
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.size = Vector2(POINTS, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = PROBE
	mat.set_shader_parameter("points", pts)
	mat.set_shader_parameter("scale", scale)
	rect.material = mat
	vp.add_child(rect)
	add_child(vp)
	var bad := 0
	for st: Array in STATES:
		var toward := deg_to_rad(float(st[0]))
		wind.dir = Vector2(sin(toward), -cos(toward))
		wind.base = float(st[1])
		wind.gust = float(st[2])
		wind.scroll = Vector2.ZERO
		wind.advance(float(st[3]))
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		var worst := 0.0
		for i in POINTS:
			var c := img.get_pixel(i, 0)
			var gpu := (roundi(c.r * 255.0) * 256 + roundi(c.g * 255.0)) / 65535.0 * scale
			var cpu := wind.speed_at(pts[i])
			worst = maxf(worst, absf(gpu - cpu) / maxf(cpu, 1e-3))
		var ok := worst < TOL
		bad += int(not ok)
		print(
			(
				"toward %.0f° base %.1f gust %.2f after %.1f s: max diff %.3f%%%s"
				% [st[0], st[1], st[2], st[3], worst * 100.0, "" if ok else "  FAIL"]
			)
		)
	wind.free()
	var method := RenderingServer.get_current_rendering_method()
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)
