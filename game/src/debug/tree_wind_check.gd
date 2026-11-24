extends Node
## Tree wind (T-06-5): a probe viewport runs the shader include's
## tree_wind_offset for vertices of one tree model at many times and reads
## back the offset along the wind (row 0) and its length (row 1), 16 bits each.
## - Wind 0: every sampled trunk vertex (bark, branch phase 0) and a trunk
##   line from the base to the top stay still at all times.
## - Wind at the reference speed: the mean offset of the model's highest
##   vertex over the sampled times is the species' flex ± TOL, and so is the
##   top of the trunk line.
## Needs a display and local tree models:
##   tools/godot.sh [--rendering-method mobile] res://scenes/debug/tree_wind_check.tscn -- <tree id>
## Prints one line per case, then RESULT PASS or FAIL (exit 0 or 1).

const TOL := 0.10
const TIMES := 64
const STEP_S := 0.4
const POINTS := 12
const SCALE_M := 4.0
const MODEL_DIR := "assets/models/trees"
const PROBE := """
shader_type canvas_item;
#include "res://shaders/common/tree_wind.gdshaderinc"
uniform vec3 pts[12];
uniform vec3 nrm[12];
uniform vec4 col[12];
uniform float height_m;
uniform float flex;
uniform float step_s;
uniform float scale;

vec2 enc(float s) {
	float q = floor(clamp(s, 0.0, 1.0) * 65535.0 + 0.5);
	float hi = floor(q / 256.0);
	return vec2(hi / 255.0, (q - hi * 256.0) / 255.0);
}

void fragment() {
	int x = int(FRAGCOORD.x);
	int i = x / 64;
	float t = float(x % 64) * step_s;
	vec3 o = tree_wind_offset(pts[i], nrm[i], col[i], 0.0, vec3(0.0), height_m, flex, t);
	float along = dot(o, vec3(wind_dir.x, 0.0, wind_dir.y));
	float v = FRAGCOORD.y < 1.0 ? (along / scale) * 0.5 + 0.5 : length(o) / scale;
	COLOR = vec4(enc(v), 0.0, 1.0);
}
"""

var _vp: SubViewport
var _mat: ShaderMaterial


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("tree wind check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var args := OS.get_cmdline_user_args()
	var tree_def: Dictionary = ContentDB.entry("trees", args[0]) if args.size() == 1 else {}
	var cfg := ContentDB.tuning("trees")
	var path := (ContentDB.root as String).path_join(MODEL_DIR).path_join("tree_%s_1.glb" % args[0])
	if tree_def.is_empty() or cfg.is_empty() or not ResourceLoader.exists(path):
		printerr("tree wind check: needs -- <tree id>, the trees tuning group and %s" % path)
		get_tree().quit(2)
		return
	var wind := Wind.new()  # kept out of the tree: no frame advance between draw and read
	if not wind.configure(ContentDB.tuning("wind")):
		printerr("tree wind check: %s" % ", ".join(wind.errors))
		get_tree().quit(2)
		return
	TreeShading.push(cfg, [])
	var height := float(tree_def.height_m)
	var flex := TreeShading.flex(cfg, String(tree_def.species))
	var model := _model_vertices(path)
	_setup(height, flex)
	var bad := 0
	# Wind 0: trunk vertices of the model plus a trunk line, at every time.
	var still: Array = model.trunk.slice(0, POINTS - 3)
	for k in 3:
		still.append([Vector3(0.0, height * k / 2.0, 0.0), Vector3.UP, Color(0, 0, 0, 1)])
	wind.base = 0.0
	wind.gust = 0.0
	var rows := await _probe(wind, still)
	var moved := 0.0
	for i in still.size():
		for s: float in rows[i][1]:
			moved = maxf(moved, s)
	bad += int(moved > 0.0)
	print(
		(
			"wind 0: %d trunk points, largest offset %.4f m%s"
			% [still.size(), moved, _flag(moved == 0.0)]
		)
	)
	# Reference wind: mean along-wind offset of the highest vertex and the trunk top.
	wind.base = float(cfg.wind_ref_ms)
	var tops: Array = [model.top, [Vector3(0.0, height, 0.0), Vector3.UP, Color(0, 0, 0, 1)]]
	rows = await _probe(wind, tops)
	for i in 2:
		var mean := 0.0
		for s: float in rows[i][0]:
			mean += s / TIMES
		var ok := absf(mean - flex) <= TOL * flex
		bad += int(not ok)
		var what := "highest model vertex" if i == 0 else "trunk line top"
		print(
			(
				"wind %.1f m/s: %s at %.2f m moves %.3f m on average (expected %.2f ± %d%%)%s"
				% [wind.base, what, tops[i][0].y, mean, flex, int(TOL * 100), _flag(ok)]
			)
		)
	wind.free()
	var method := RenderingServer.get_current_rendering_method()
	print("RESULT %s (%s)" % ["PASS" if bad == 0 else "FAIL", method])
	get_tree().quit(0 if bad == 0 else 1)


## {"trunk": [[pos, normal, colour], ...] (bark vertices with branch phase 0,
## spread over the height), "top": [pos, normal, colour] (highest vertex)} of
## the model's T0 mesh.
func _model_vertices(path: String) -> Dictionary:
	var node := (load(path) as PackedScene).instantiate()
	var mesh: Mesh
	for child in node.find_children("*_t0", "MeshInstance3D", true, false):
		mesh = (child as MeshInstance3D).mesh
	var trunk: Array = []
	var top: Array = []
	for s in mesh.get_surface_count():
		var a := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
		var c: PackedColorArray = a[Mesh.ARRAY_COLOR]
		for i in v.size():
			if top.is_empty() or v[i].y > top[0].y:
				top = [v[i], n[i], c[i]]
			if s == 0 and c[i].r == 0.0:
				trunk.append([v[i], n[i], c[i]])
	node.free()
	trunk.sort_custom(func(x: Array, y: Array) -> bool: return x[0].y < y[0].y)
	var spread: Array = []
	var want := POINTS - 3
	for k in want:
		spread.append(trunk[int(float(k) / maxf(want - 1, 1) * (trunk.size() - 1))])
	return {"trunk": spread, "top": top}


func _setup(height: float, flex: float) -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(POINTS * TIMES, 2)
	_vp.disable_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.size = Vector2(POINTS * TIMES, 2.0)
	_mat = ShaderMaterial.new()
	_mat.shader = Shader.new()
	_mat.shader.code = PROBE
	_mat.set_shader_parameter("height_m", height)
	_mat.set_shader_parameter("flex", flex)
	_mat.set_shader_parameter("step_s", STEP_S)
	_mat.set_shader_parameter("scale", SCALE_M)
	rect.material = _mat
	_vp.add_child(rect)
	add_child(_vp)


## Per point: [along-wind offsets, offset lengths] over the sampled times.
func _probe(wind: Wind, points: Array) -> Array:
	var pts := PackedVector3Array()
	var nrm := PackedVector3Array()
	var col := PackedColorArray()
	for i in POINTS:
		var p: Array = points[mini(i, points.size() - 1)]
		pts.append(p[0])
		nrm.append(p[1])
		col.append(p[2])
	_mat.set_shader_parameter("pts", pts)
	_mat.set_shader_parameter("nrm", nrm)
	_mat.set_shader_parameter("col", col)
	wind.dir = Vector2(1.0, 0.0)
	wind.scroll = Vector2.ZERO
	wind.advance(0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var out: Array = []
	for i in points.size():
		var along: Array = []
		var size: Array = []
		for t in TIMES:
			along.append((_dec(img.get_pixel(i * TIMES + t, 0)) - 0.5) * 2.0 * SCALE_M)
			size.append(_dec(img.get_pixel(i * TIMES + t, 1)) * SCALE_M)
		out.append([along, size])
	return out


func _dec(c: Color) -> float:
	return (roundi(c.r * 255.0) * 256 + roundi(c.g * 255.0)) / 65535.0


func _flag(ok: bool) -> String:
	return "" if ok else "  FAIL"
