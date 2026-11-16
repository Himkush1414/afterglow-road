extends SceneTree
## Spike P1-01 (assumptions A-01, A-03): CDLOD selection in GDScript feeding
## one MultiMesh; height decoded from RG8 in the vertex shader. Reads local
## spike data (res://content/spike_data/) made by a local generator.
##   -- --time      headless: fly 30 s at 40 m/s, report selection cost
##   -- --shots     render fixed views and 24 views along the flight path,
##                  count clear-colour pixels under terrain (needs a display)
##   -- --r0 <m> --morph <ratio>   LOD settings (defaults: the corrected ones)

const ROOT_SIZE := 4096.0
const LEVELS := 7
const HALF := 4096.0
const MAX_INSTANCES := 512

var r0 := 160.0
var morph := 0.8
var ranges: PackedFloat32Array = []
var mins: Array[PackedInt32Array] = []
var maxs: Array[PackedInt32Array] = []
var mm := MultiMesh.new()
var buffer := PackedFloat32Array()
var count := 0
var cam := Camera3D.new()
var frustum: Array[Plane] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var ri := args.find("--r0")
	if ri >= 0:
		r0 = float(args[ri + 1])
	var mi := args.find("--morph")
	if mi >= 0:
		morph = float(args[mi + 1])
	_load_minmax("res://content/spike_data/minmax.bin")
	for l in LEVELS:
		ranges.append(r0 * pow(2.0, l))
	cam.far = 12000.0
	cam.near = 0.05
	cam.fov = 75.0
	root.add_child(cam)
	if "--time" in args:
		_time_selection()
		return
	_build_scene()
	await _shots()


func _load_minmax(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	for l in LEVELS:
		var k := int(4096 / (32 * pow(2, l)))
		var lo := PackedInt32Array()
		var hi := PackedInt32Array()
		lo.resize(k * k)
		hi.resize(k * k)
		for i in k * k:
			lo[i] = f.get_16()
			hi[i] = f.get_16()
		mins.append(lo)
		maxs.append(hi)


func _node_box(level: int, ix: int, iz: int) -> AABB:
	var size := 64.0 * pow(2.0, level)
	var k := int(4096 / (32 * pow(2, level)))
	var lo := mins[level][iz * k + ix] * 0.02 - 64.0
	var hi := maxs[level][iz * k + ix] * 0.02 - 64.0
	return AABB(
		Vector3(ix * size - HALF, lo, iz * size - HALF), Vector3(size, hi - lo + 0.01, size)
	)


func _in_frustum(box: AABB) -> bool:
	for p in frustum:
		var v := Vector3(
			box.position.x + (box.size.x if p.normal.x < 0.0 else 0.0),
			box.position.y + (box.size.y if p.normal.y < 0.0 else 0.0),
			box.position.z + (box.size.z if p.normal.z < 0.0 else 0.0)
		)
		if p.distance_to(v) > 0.0:
			return false
	return true


static func _nearest_dist(box: AABB, eye: Vector3) -> float:
	var q := eye.clamp(box.position, box.end)
	return q.distance_to(eye)


## CDLOD selection (05 §5): returns the number of instances written.
func select() -> int:
	frustum = cam.get_frustum()
	count = 0
	var eye := cam.global_position
	for iz in 2:
		for ix in 2:
			_visit(LEVELS - 1, ix, iz, eye)
	mm.visible_instance_count = count
	if count > 0:
		mm.buffer = buffer
	return count


func _visit(level: int, ix: int, iz: int, eye: Vector3) -> void:
	# Strugar's CDLOD: a node that reaches into the next finer range is split;
	# children that do not reach into it are drawn by this node, at this
	# node's level, as quadrants.
	var box := _node_box(level, ix, iz)
	if not _in_frustum(box):
		return
	if level == 0 or _nearest_dist(box, eye) > ranges[level - 1]:
		_emit(box, level, 32.0)
		return
	for dz in 2:
		for dx in 2:
			var cx := ix * 2 + dx
			var cz := iz * 2 + dz
			var child := _node_box(level - 1, cx, cz)
			if _nearest_dist(child, eye) > ranges[level - 1]:
				if _in_frustum(child):
					_emit(child, level, 16.0)
			else:
				_visit(level - 1, cx, cz, eye)


func _emit(box: AABB, level: int, cells: float) -> void:
	if count >= MAX_INSTANCES:
		return
	var o := count * 16
	# Identity transform rows, then custom data (corner x, corner z, size, level code).
	for i in 12:
		buffer[o + i] = 1.0 if i == 0 or i == 5 or i == 10 else 0.0
	buffer[o + 12] = box.position.x
	buffer[o + 13] = box.position.z
	buffer[o + 14] = box.size.x
	buffer[o + 15] = float(level) + (0.5 if cells < 32.0 else 0.0)
	count += 1


func _setup_multimesh() -> void:
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _patch_mesh()
	mm.instance_count = MAX_INSTANCES
	buffer.resize(MAX_INSTANCES * 16)


func _patch_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in 33:
		for x in 33:
			st.add_vertex(Vector3(x / 32.0, 0.0, z / 32.0))
	for z in 32:
		for x in 32:
			var a := z * 33 + x
			st.add_index(a)
			st.add_index(a + 1)
			st.add_index(a + 33)
			st.add_index(a + 1)
			st.add_index(a + 34)
			st.add_index(a + 33)
	var m := st.commit()
	# Keep the whole patch inside any frustum test the engine does on its own.
	m.custom_aabb = AABB(Vector3(-HALF, -100, -HALF), Vector3(2 * HALF, 1500, 2 * HALF))
	return m


func _fly_pose(t: float) -> Transform3D:
	# A 20 km loop over forest, hills and the mountain at 40 m/s, 60 m above
	# the highest ground under the camera (from the level-1 min/max boxes).
	var angle := t * 40.0 / 3200.0
	var p := Vector3(cos(angle) * 3200.0, 0.0, sin(angle) * 3200.0)
	p.y = _ground_max(p) + 60.0
	var fwd := Vector3(-sin(angle), -0.15, cos(angle)).normalized()
	return Transform3D(Basis.looking_at(fwd, Vector3.UP), p)


func _ground_max(p: Vector3) -> float:
	var k := 4096 / 64
	var ix := clampi(int((p.x + HALF) / 128.0), 0, k - 1)
	var iz := clampi(int((p.z + HALF) / 128.0), 0, k - 1)
	return maxs[1][iz * k + ix] * 0.02 - 64.0


func _time_selection() -> void:
	_setup_multimesh()
	var dt := 1.0 / 60.0
	var total := 0.0
	var worst := 0.0
	var calls := 0
	var max_count := 0
	var last_pos := Vector3(INF, 0, 0)
	var frames := 30 * 60
	for f in frames:
		cam.transform = _fly_pose(f * dt)
		if cam.position.distance_to(last_pos) <= 4.0:
			continue
		last_pos = cam.position
		var t0 := Time.get_ticks_usec()
		var n := select()
		var us := float(Time.get_ticks_usec() - t0)
		total += us
		worst = maxf(worst, us)
		calls += 1
		max_count = maxi(max_count, n)
	var per_frame := total / frames / 1000.0
	var summary := (
		"selection: %d calls in %d frames; mean %.3f ms per call, worst %.3f ms"
		% [calls, frames, total / calls / 1000.0, worst / 1000.0]
	)
	print("%s; per frame %.3f ms; max instances %d" % [summary, per_frame, max_count])
	print("RESULT %s" % ("PASS" if per_frame <= 1.0 and max_count <= 400 else "FAIL"))
	quit(0 if per_frame <= 1.0 and max_count <= 400 else 1)


func _build_scene() -> void:
	_setup_multimesh()
	var img := Image.load_from_file("res://content/spike_data/height_rgb.png")
	img.convert(Image.FORMAT_RG8)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/spikes/terrain/terrain_spike.gdshader")
	mat.set_shader_parameter("height_tex", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("morph_start", morph)
	mat.set_shader_parameter("r0", r0)
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = mat
	root.add_child(inst)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, -60, 0)
	root.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(1, 0, 1)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.5, 0.55, 0.6)
	root.add_child(env)


func _shots() -> void:
	var dir := OS.get_environment("SPIKE_OUT")
	var views := {
		"house": [Vector3(1400 - HALF, 75, 6900 - HALF), Vector3(7000 - HALF, 900, 900 - HALF)],
		"hills": [Vector3(4300 - HALF, 600, 3400 - HALF), Vector3(6000 - HALF, 400, 2000 - HALF)],
		"summit": [Vector3(6760 - HALF, 930, 1200 - HALF), Vector3(1400 - HALF, 60, 6900 - HALF)],
	}
	for name: String in views:
		var v: Array = views[name]
		cam.look_at_from_position(v[0], v[1])
		var n := select()
		for i in 4:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		# A crack is a clear-colour pixel below terrain in the same column.
		var holes := 0
		var h := img.get_height()
		var w := img.get_width()
		for x in w:
			var ground := false
			for y in h:
				var c := img.get_pixel(x, y)
				var is_sky := c.r > 0.95 and c.g < 0.05 and c.b > 0.95
				if not is_sky:
					ground = true
				elif ground:
					holes += 1
		var magenta := holes
		if dir != "":
			var method := RenderingServer.get_current_rendering_method()
			img.save_png(dir.path_join("terrain_%s_%s.png" % [name, method]))
		print("%s: %d instances, clear-colour pixels under terrain: %d" % [name, n, magenta])
	var total := 0
	var worst_n := 0
	for i in 24:
		cam.transform = _fly_pose(i * 21.0)
		var n := select()
		worst_n = maxi(worst_n, n)
		for f in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var fimg := root.get_texture().get_image()
		var h_count := _holes(fimg)
		total += h_count
		if h_count > 0:
			print("  frame %d at %s: %d" % [i, cam.position.round(), h_count])
			var out_dir := OS.get_environment("SPIKE_OUT")
			if out_dir != "":
				fimg.save_png(out_dir.path_join("flight_%02d.png" % i))
	print(
		(
			"flight: 24 frames, %d clear-colour pixels under terrain, at most %d instances"
			% [total, worst_n]
		)
	)
	quit()


func _holes(img: Image) -> int:
	var holes := 0
	for x in img.get_width():
		var ground := false
		for y in img.get_height():
			var c := img.get_pixel(x, y)
			if not (c.r > 0.95 and c.g < 0.05 and c.b > 0.95):
				ground = true
			elif ground:
				holes += 1
	return holes
