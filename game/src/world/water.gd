class_name Water
extends Node3D
## Water bodies of the world (05 §7) from water.json: the sea (surface at sea
## level wherever the ground is below it), lakes (polygon and level) and
## rivers and streams (centre line with a level and width per point).
## Queries take engine coordinates; the file uses map coordinates.

const SEA := &"sea"
const LAKE := &"lake"
## Size of the lookup cells for river segments, metres.
const CELL_M := 64.0
const SHADER := "res://shaders/water.gdshader"
const SHADER_DESKTOP := "res://shaders/water_desktop.gdshader"
## Sea near grid (05 §7): QUADS x QUADS over GRID_M, snapped to the camera,
## and a ring around it out to FAR_M.
const SEA_GRID_M := 512.0
const SEA_GRID_QUADS := 64
const SEA_FAR_M := 60000.0
## River ribbons are cut into one mesh per region of REGION_M.
const REGION_M := 512.0
## Points either side used to smooth a river's grade for its flow speed.
const GRADE_SMOOTH := 2

var errors: PackedStringArray = []
var sea_level := 0.0

## Built surfaces: the sea node (moves with the camera), lake and river meshes.
var sea: Node3D
var lake_meshes: Array[MeshInstance3D] = []
var river_meshes: Array[MeshInstance3D] = []

var _world: WorldData
var _lakes: Array[Dictionary] = []
var _rivers: Array[Dictionary] = []
## Vector2i cell -> Array of [river index, segment index]
var _cells := {}


## Reads water.json of the loaded `world`. Returns false and fills `errors`
## when it is missing, changed or malformed.
func setup(world: WorldData) -> bool:
	errors.clear()
	_world = world
	_lakes.clear()
	_rivers.clear()
	_cells.clear()
	var text := world.read_text("water.json")
	if text == "":
		errors.append_array(world.errors)
		return false
	var doc: Variant = JSON.parse_string(text)
	if not doc is Dictionary:
		errors.append("water.json: not a JSON object")
		return false
	sea_level = float(doc.get("sea_level_y", 0.0))
	for lake: Dictionary in doc.get("lakes", []):
		var poly := PackedVector2Array()
		for p: Array in lake.polygon:
			poly.append(Vector2(p[0], p[1]))
		_lakes.append({"id": StringName(lake.id), "level": float(lake.level), "polygon": poly})
	for river: Dictionary in doc.get("rivers", []):
		var centre := PackedVector2Array()
		for p: Array in river.centre:
			centre.append(Vector2(p[0], p[1]))
		var level := PackedFloat32Array(river.level)
		var width := PackedFloat32Array(river.width)
		if level.size() != centre.size() or width.size() != centre.size() or centre.size() < 2:
			errors.append(
				"water.json: river %s needs matching point, level and width lists" % river.id
			)
			return false
		_rivers.append(
			{
				"id": StringName(river.id),
				"kind": StringName(river.kind),
				"centre": centre,
				"level": level,
				"width": width
			}
		)
		_index_river(_rivers.size() - 1)
	return true


## Builds the sea, lake and river surfaces. `ground` is the terrain height
## texture (RG8 codes), used by the shader for the water depth.
func build(ground: Texture2D) -> void:
	for n in get_children():
		n.free()
	lake_meshes.clear()
	river_meshes.clear()
	var cfg := ContentDB.tuning("water")
	var still := _material(ground, cfg, false)
	var flowing := _material(ground, cfg, true)
	sea = Node3D.new()
	sea.name = "Sea"
	add_child(sea)
	var grid := PlaneMesh.new()
	grid.size = Vector2(SEA_GRID_M, SEA_GRID_M)
	grid.subdivide_width = SEA_GRID_QUADS - 1
	grid.subdivide_depth = SEA_GRID_QUADS - 1
	sea.add_child(_mesh_node(grid, still))
	sea.add_child(_mesh_node(_ring_mesh(SEA_GRID_M * 0.5, SEA_FAR_M), still))
	sea.position.y = sea_level
	for lake in _lakes:
		var node := _mesh_node(_lake_mesh(lake), still)
		add_child(node)
		lake_meshes.append(node)
	var speeds := _flow_speeds(
		float(cfg.get("flow_min_mps", 0.0)), float(cfg.get("flow_max_mps", 0.0))
	)
	for i in _rivers.size():
		for piece in _river_pieces(i, speeds[i]):
			var node := _mesh_node(piece, flowing)
			add_child(node)
			river_meshes.append(node)


## Keeps the sea grid under the camera, snapped to its quads.
func follow(cam_pos: Vector3) -> void:
	if sea == null:
		return
	var step := SEA_GRID_M / SEA_GRID_QUADS
	sea.position = Vector3(snappedf(cam_pos.x, step), sea_level, snappedf(cam_pos.z, step))


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		follow(cam.global_position)


func lakes() -> Array[Dictionary]:
	return _lakes


func rivers() -> Array[Dictionary]:
	return _rivers


## Water surface height at engine `pos`, or -INF when there is no water above
## the ground there.
func surface_y(pos: Vector3) -> float:
	return _query(pos)[0]


## Water depth above the ground at `pos` (0 when dry).
func depth_at(pos: Vector3) -> float:
	var q := _query(pos)
	return q[0] - _world.height_at(pos.x, pos.z) if q[0] > -INF else 0.0


## Kind of water at `pos`: &"sea", &"lake", a river's kind (&"river",
## &"stream"), or &"" when dry.
func kind_at(pos: Vector3) -> StringName:
	return _query(pos)[1]


## [surface, kind]: rivers first (their ribbon), then lakes, then the sea.
func _query(pos: Vector3) -> Array:
	var m3 := _world.world_to_map(pos)
	var m := Vector2(m3.x, m3.z)
	var bed := _world.height_at(pos.x, pos.z)
	var surface := -INF
	var kind := &""
	var river := _river_at(m)
	if not river.is_empty():
		surface = river[0]
		kind = river[1]
	else:
		for lake in _lakes:
			if Geometry2D.is_point_in_polygon(m, lake.polygon):
				surface = lake.level
				kind = LAKE
				break
		if kind == &"" and bed < sea_level:
			surface = sea_level
			kind = SEA
	if surface <= bed:
		return [-INF, &""]
	return [surface, kind]


## [level, kind] of the nearest river segment whose ribbon holds map point
## `m`, or [].
func _river_at(m: Vector2) -> Array:
	var key := Vector2i(floori(m.x / CELL_M), floori(m.y / CELL_M))
	var best := INF
	var out := []
	for hit: Array in _cells.get(key, []):
		var r: Dictionary = _rivers[hit[0]]
		var i: int = hit[1]
		var a: Vector2 = r.centre[i]
		var b: Vector2 = r.centre[i + 1]
		var ab := b - a
		var t := clampf((m - a).dot(ab) / maxf(ab.length_squared(), 1e-9), 0.0, 1.0)
		var d := m.distance_to(a + ab * t)
		var half := lerpf(r.width[i], r.width[i + 1], t) * 0.5
		if d <= half and d < best:
			best = d
			out = [lerpf(r.level[i], r.level[i + 1], t), r.kind]
	return out


func _index_river(index: int) -> void:
	var r: Dictionary = _rivers[index]
	var centre: PackedVector2Array = r.centre
	for i in centre.size() - 1:
		var half := maxf(r.width[i], r.width[i + 1]) * 0.5
		var lo := Vector2(minf(centre[i].x, centre[i + 1].x), minf(centre[i].y, centre[i + 1].y))
		var hi := Vector2(maxf(centre[i].x, centre[i + 1].x), maxf(centre[i].y, centre[i + 1].y))
		lo -= Vector2(half, half)
		hi += Vector2(half, half)
		for cz in range(floori(lo.y / CELL_M), floori(hi.y / CELL_M) + 1):
			for cx in range(floori(lo.x / CELL_M), floori(hi.x / CELL_M) + 1):
				var key := Vector2i(cx, cz)
				if not _cells.has(key):
					_cells[key] = []
				_cells[key].append([index, i])


## Desktop path (refraction, waves): not on the Mobile renderer, and only
## when the applied quality preset allows refraction.
static func uses_desktop_path() -> bool:
	if RenderingServer.get_current_rendering_method() == "mobile":
		return false
	var refraction: Variant = Quality.value("water_refraction")
	return refraction == null or bool(refraction)


func _material(ground: Texture2D, cfg: Dictionary, flowing: bool) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = load(SHADER_DESKTOP if uses_desktop_path() else SHADER)
	m.set_shader_parameter("ground_tex", ground)
	m.set_shader_parameter("origin_offset", _world.origin_offset_m)
	m.set_shader_parameter("sample_m", _world.sample_m)
	m.set_shader_parameter("height_scale", _world.height_of_code(1) - _world.height_of_code(0))
	m.set_shader_parameter("height_offset", -_world.height_of_code(0))
	for key: String in ["shallow_color", "deep_color", "foam_color"]:
		var c: Array = cfg.get(key, [0.5, 0.5, 0.5])
		m.set_shader_parameter(key, Color(c[0], c[1], c[2]))
	for key: String in ["deep_m", "foam_m", "normal_tile_m"]:
		m.set_shader_parameter(key, float(cfg.get(key, 1.0)))
	m.set_shader_parameter("roughness_value", float(cfg.get("roughness", 0.1)))
	m.set_shader_parameter("flowing", flowing)
	m.set_shader_parameter("wave_amplitude_m", float(cfg.get("wave_amplitude_m", 0.0)))
	m.set_shader_parameter("wave_range_m", float(cfg.get("wave_range_m", 0.0)))
	m.set_shader_parameter("normal_a", _normal_texture(1))
	m.set_shader_parameter("normal_b", _normal_texture(2))
	return m


static func _normal_texture(seed_value: int) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 0.02
	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.seamless = true
	tex.as_normal_map = true
	tex.generate_mipmaps = true
	tex.width = 256
	tex.height = 256
	return tex


static func _mesh_node(mesh: Mesh, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## A flat square ring between half-sizes `inner` and `outer`.
static func _ring_mesh(inner: float, outer: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for k in 4:
		var a: Vector2 = corners[k]
		var b: Vector2 = corners[(k + 1) % 4]
		var ai := Vector3(a.x * inner, 0.0, a.y * inner)
		var bi := Vector3(b.x * inner, 0.0, b.y * inner)
		var ao := Vector3(a.x * outer, 0.0, a.y * outer)
		var bo := Vector3(b.x * outer, 0.0, b.y * outer)
		for v: Vector3 in [ai, ao, bo, ai, bo, bi]:
			st.add_vertex(v)
	return st.commit()


func _lake_mesh(lake: Dictionary) -> ArrayMesh:
	var poly: PackedVector2Array = lake.polygon
	var tris := Geometry2D.triangulate_polygon(poly)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	for i in tris:
		var p := _world.map_to_world(Vector3(poly[i].x, 0.0, poly[i].y))
		st.add_vertex(Vector3(p.x, lake.level, p.z))
	return st.commit()


## Flow speed per river point: the smoothed level drop per metre, mapped
## linearly from the gentlest to the steepest grade of all rivers onto
## [lo, hi] m/s.
func _flow_speeds(lo: float, hi: float) -> Array[PackedFloat32Array]:
	var grades: Array[PackedFloat32Array] = []
	var g_lo := INF
	var g_hi := -INF
	for r in _rivers:
		var c: PackedVector2Array = r.centre
		var level: PackedFloat32Array = r.level
		var g := PackedFloat32Array()
		g.resize(c.size())
		for i in c.size():
			var a := maxi(i - GRADE_SMOOTH, 0)
			var b := mini(i + GRADE_SMOOTH, c.size() - 1)
			var run := 0.0
			for k in range(a, b):
				run += c[k].distance_to(c[k + 1])
			g[i] = maxf(level[a] - level[b], 0.0) / maxf(run, 1e-6)
			g_lo = minf(g_lo, g[i])
			g_hi = maxf(g_hi, g[i])
		grades.append(g)
	var out: Array[PackedFloat32Array] = []
	for g in grades:
		var s := PackedFloat32Array()
		for v in g:
			s.append(lerpf(lo, hi, (v - g_lo) / (g_hi - g_lo) if g_hi > g_lo else 0.0))
		out.append(s)
	return out


## Ribbon meshes of river `index`, one per run of points in the same region
## (each run repeats the next region's first point so the pieces meet).
## UV = (metres across, metres along), UV2.x = flow speed.
func _river_pieces(index: int, speed: PackedFloat32Array) -> Array[ArrayMesh]:
	var r: Dictionary = _rivers[index]
	var c: PackedVector2Array = r.centre
	var level: PackedFloat32Array = r.level
	var width: PackedFloat32Array = r.width
	var along := PackedFloat32Array([0.0])
	for i in range(1, c.size()):
		along.append(along[i - 1] + c[i - 1].distance_to(c[i]))
	var out: Array[ArrayMesh] = []
	var start := 0
	while start < c.size() - 1:
		var region := _region(c[start])
		var end := start + 1
		while end < c.size() - 1 and _region(c[end]) == region:
			end += 1
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var verts: Array[Vector3] = []
		var uvs: Array[Vector2] = []
		for i in range(start, end + 1):
			var t := (c[mini(i + 1, c.size() - 1)] - c[maxi(i - 1, 0)]).normalized()
			var n := Vector2(-t.y, t.x) * width[i] * 0.5
			for side: float in [-1.0, 1.0]:
				var m := c[i] + n * side
				var p := _world.map_to_world(Vector3(m.x, 0.0, m.y))
				verts.append(Vector3(p.x, level[i], p.z))
				uvs.append(Vector2(side * width[i] * 0.5, along[i]))
		for q in end - start:
			for k: int in [0, 2, 1, 1, 2, 3]:
				var v := q * 2 + k
				st.set_normal(Vector3.UP)
				st.set_uv(uvs[v])
				st.set_uv2(Vector2(speed[start + q + (k >> 1)], 0.0))
				st.add_vertex(verts[v])
		out.append(st.commit())
		start = end
	return out


static func _region(m: Vector2) -> Vector2i:
	return Vector2i(floori(m.x / REGION_M), floori(m.y / REGION_M))
