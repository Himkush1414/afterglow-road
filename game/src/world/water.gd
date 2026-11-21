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

var errors: PackedStringArray = []
var sea_level := 0.0

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
