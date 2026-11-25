extends Node
## Grass wind (06 §B4, T-06-11): a row of test blades 2 m apart across a
## 200 m strip along the wind, drawn with grass.gdshader and seen straight
## from above with an orthographic camera. An upright blade is edge-on and
## covers nothing; a leaning blade covers its width times its lean, so each
## blade's covered pixels give its lean. The check
## - compares every blade's lean with the lean the gust field gives at its
##   root (the shader's formula on the CPU);
## - finds how far the lean profile moved after `DT` seconds of wind (best
##   match of the two profiles) and checks that the gust front crossed the
##   strip at the wind speed +- 15%;
## - checks (control) that blades without wind or base lean cover nothing;
## - fade: with every fade key at 0.5, only the blades nearer than
##   radius x (1 - 0.5 x fade band) are drawn;
## - benders: a bender between two blades pushes both away from it by
##   (1 - r / radius) x push x height and no other blade.
## Needs a display:
##   tools/godot.sh [--rendering-method mobile] res://scenes/debug/grass_check.tscn
## Prints one line per case, then RESULT PASS or FAIL (exit 0 or 1).

const WIDTH := 2048
const HEIGHT := 64
const M_PER_PX := 0.1
const BLADES := 100
const SPACING_M := 2.0
const BLADE_H := 3.0
const BLADE_W := 0.5
## Test values, not tuning: lean = (LEAN_BASE + LEAN_PER_MS x w) x height.
const LEAN_BASE := 0.10
const LEAN_PER_MS := 0.025
const WIND_MS := 10.0
const GUST := 0.6
const DT := 4.0
const SPEED_TOL := 0.15
const LEAN_TOL_M := 0.15
const BACKGROUND := Color(1.0, 0.0, 1.0)

var _vp: SubViewport
var _cam: Camera3D
var _wind: Wind
var _mat: ShaderMaterial
var _mm: MultiMesh
var _start := Vector3(-100.0, 0.0, 37.0)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("grass check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var cfg := ContentDB.tuning("wind")
	_wind = Wind.new()
	_wind.set_process(false)
	add_child(_wind)
	if cfg.is_empty() or not _wind.configure(cfg):
		printerr("grass check: no wind tuning")
		get_tree().quit(2)
		return
	_setup()
	var bad := 0
	_wind.dir = Vector2(1.0, 0.0)
	_wind.gust = GUST
	# Control: no wind and no base lean leave the blades edge-on (nothing seen).
	_wind.base = 0.0
	_wind.advance(0.0)
	_mat.set_shader_parameter("lean_base", 0.0)
	var calm := await _profile()
	_mat.set_shader_parameter("lean_base", LEAN_BASE)
	var calm_max := 0.0
	for v in calm:
		calm_max = maxf(calm_max, v)
	var upright := calm_max <= LEAN_TOL_M
	print("calm: largest lean %.2f m%s" % [calm_max, _flag(upright)])
	bad += int(not upright)
	_wind.base = WIND_MS
	_wind.advance(0.0)
	var a := await _profile()
	var worst := 0.0
	for i in BLADES:
		worst = maxf(worst, absf(a[i] - _expected(i)))
	var spread := _spread(a)
	var follows := worst <= LEAN_TOL_M and spread > 0.1
	print(
		(
			"lean: worst blade %.2f m from the gust field, profile spread %.2f m%s"
			% [worst, spread, _flag(follows)]
		)
	)
	bad += int(not follows)
	_wind.advance(DT)
	var b := await _profile()
	var shift := _best_shift(a, b, int(WIND_MS * DT * 2.0 / SPACING_M))
	var speed := shift * SPACING_M / DT
	var ok := absf(speed - WIND_MS) <= SPEED_TOL * WIND_MS
	print(
		(
			"gust front: moved %.1f m in %.1f s = %.2f m/s at %.1f m/s%s"
			% [shift * SPACING_M, DT, speed, WIND_MS, _flag(ok)]
		)
	)
	bad += int(not ok)
	bad += await _fade_case()
	bad += await _bender_case()
	print("RESULT %s" % ("PASS" if bad == 0 else "FAIL"))
	get_tree().quit(0 if bad == 0 else 1)


## Fade keys 0.5, radius 60 m, band 0.3: drawn where (60 - d) / 18 > 0.5.
func _fade_case() -> int:
	_wind.base = 0.0
	_wind.advance(0.0)
	for i in BLADES:
		_mm.set_instance_custom_data(i, Color(0.5, 0.0, 0.0, 0.0))
	_mat.set_shader_parameter("radius_m", 60.0)
	_mat.set_shader_parameter("fade_band", 0.3)
	var p := await _profile()
	var wrong := 0
	var drawn := 0
	for i in BLADES:
		var d := absf(_root(i).x - _cam.position.x)
		var want := (60.0 - d) / 18.0 > 0.5
		var seen := p[i] > LEAN_BASE * BLADE_H * 0.5
		wrong += int(want != seen and absf(d - 51.0) > 0.5)
		drawn += int(seen)
	for i in BLADES:
		_mm.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
	_mat.set_shader_parameter("radius_m", 100000.0)
	var ok := wrong == 0 and drawn > 0 and drawn < BLADES
	print("fade: %d of %d blades drawn, %d on the wrong side%s" % [drawn, BLADES, wrong, _flag(ok)])
	return int(not ok)


## No wind, no base lean; a 3 m bender 1 m left of blade 50's root.
func _bender_case() -> int:
	_wind.base = 0.0
	_wind.advance(0.0)
	_mat.set_shader_parameter("lean_base", 0.0)
	_mat.set_shader_parameter("bend_push", 0.2)
	var at := _root(50) - Vector3(1.0, 0.0, 0.0)
	var benders: Array[Vector4] = [Vector4(at.x, at.y, at.z, 3.0), Vector4(), Vector4(), Vector4()]
	_mat.set_shader_parameter("benders", benders)
	var p := await _profile()
	var push := (1.0 - 1.0 / 3.0) * 0.2 * BLADE_H
	var worst := 0.0
	for i in BLADES:
		var want := push if i == 49 or i == 50 else 0.0
		worst = maxf(worst, absf(p[i] - want))
	_mat.set_shader_parameter("lean_base", LEAN_BASE)
	_mat.set_shader_parameter("bend_push", 0.0)
	var ok := worst <= LEAN_TOL_M * 0.5
	print(
		(
			"benders: blades 49 and 50 pushed %.2f / %.2f m (want %.2f), worst blade off by %.2f m%s"
			% [p[49], p[50], push, worst, _flag(ok)]
		)
	)
	return int(not ok)


func _setup() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(WIDTH, HEIGHT)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.own_world_3d = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BACKGROUND
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 1.0, 1.0)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.keep_aspect = Camera3D.KEEP_WIDTH
	_cam.size = WIDTH * M_PER_PX
	_cam.near = 0.1
	_cam.far = 100.0
	# Straight down, image x along world x; the strip starts at the left edge.
	_cam.position = _start + Vector3(WIDTH * M_PER_PX * 0.5, 20.0, 0.0)
	_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_vp.add_child(_cam)
	var node := MultiMeshInstance3D.new()
	_mm = _blades()
	node.multimesh = _mm
	_mat = _material()
	node.material_override = _mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_vp.add_child(node)
	add_child(_vp)


func _blades() -> MultiMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [
		Vector3(0.0, 0.0, -BLADE_W * 0.5),
		Vector3(0.0, 0.0, BLADE_W * 0.5),
		Vector3(0.0, BLADE_H, BLADE_W * 0.5),
		Vector3(0.0, BLADE_H, -BLADE_W * 0.5),
	]
	for k: int in [0, 1, 2, 0, 2, 3]:
		var v: Vector3 = corners[k]
		st.set_color(Color(v.y / BLADE_H, 0.0, 0.0))
		st.set_normal(Vector3.RIGHT)
		st.add_vertex(v)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = st.commit()
	mm.instance_count = BLADES
	for i in BLADES:
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, _root(i)))
		mm.set_instance_custom_data(i, Color(0.0, 0.0, 0.0, 0.0))
	return mm


func _material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/grass.gdshader")
	mat.set_shader_parameter("colour", Color(1.0, 1.0, 1.0))
	mat.set_shader_parameter("blade_height_m", BLADE_H)
	mat.set_shader_parameter("lean_base", LEAN_BASE)
	mat.set_shader_parameter("lean_per_ms", LEAN_PER_MS)
	mat.set_shader_parameter("flutter_m", 0.0)
	mat.set_shader_parameter("radius_m", 100000.0)
	return mat


func _root(i: int) -> Vector3:
	return _start + Vector3(SPACING_M * (i + 0.25), 0.0, 0.0)


## The lean the shader gives blade i (metres along the wind).
func _expected(i: int) -> float:
	var w := _wind.speed_at(_root(i))
	return minf((LEAN_BASE + LEAN_PER_MS * w) * BLADE_H, BLADE_H * 0.95)


## Each blade's lean in metres: covered pixels in its 2 m slot, over its
## width in pixels, in metres.
func _profile() -> PackedFloat32Array:
	for i in 3:
		await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var out := PackedFloat32Array()
	out.resize(BLADES)
	var slot := roundi(SPACING_M / M_PER_PX)
	for i in BLADES:
		var count := 0
		for x in range(i * slot, (i + 1) * slot):
			for y in HEIGHT:
				var c := img.get_pixel(x, y)
				if absf(c.r - 1.0) + c.g + absf(c.b - 1.0) > 0.05:
					count += 1
		out[i] = count / (BLADE_W / M_PER_PX) * M_PER_PX
	return out


static func _spread(v: PackedFloat32Array) -> float:
	var lo := INF
	var hi := -INF
	for x in v:
		lo = minf(lo, x)
		hi = maxf(hi, x)
	return hi - lo


## The shift s (in blades, refined between neighbours) at which b[i] best
## matches a[i - s]: the largest correlation of the overlapping parts.
static func _best_shift(a: PackedFloat32Array, b: PackedFloat32Array, most: int) -> float:
	var scores := PackedFloat32Array()
	for s in most + 1:
		scores.append(_correlation(a, b, s))
	var best := 0
	for s in scores.size():
		if scores[s] > scores[best]:
			best = s
	if best == 0 or best == most:
		return best
	var l := scores[best - 1]
	var c := scores[best]
	var r := scores[best + 1]
	var den := l - 2.0 * c + r
	return best + (0.5 * (l - r) / den if absf(den) > 1e-9 else 0.0)


static func _correlation(a: PackedFloat32Array, b: PackedFloat32Array, s: int) -> float:
	var n := a.size() - s
	var ma := 0.0
	var mb := 0.0
	for i in n:
		ma += a[i]
		mb += b[i + s]
	ma /= n
	mb /= n
	var num := 0.0
	var da := 0.0
	var db := 0.0
	for i in n:
		num += (a[i] - ma) * (b[i + s] - mb)
		da += (a[i] - ma) * (a[i] - ma)
		db += (b[i + s] - mb) * (b[i + s] - mb)
	return num / sqrt(maxf(da * db, 1e-12))


static func _flag(ok: bool) -> String:
	return "" if ok else "  <-- FAIL"
