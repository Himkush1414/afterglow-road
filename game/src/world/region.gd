class_name Region
extends Node3D
## One 512 m region of the world (03 §10): holds the region's objects while
## it is loaded. Loading happens in steps the Streamer spreads over frames;
## on load the region applies its saved change set ("delta"), and delta()
## returns what must be saved. Regions have no content yet (later steps
## add buildings, props, nodes and items as load steps and delta entries).

enum State { UNLOADED, LOADING, ACTIVE, UNLOADING }

## Cliff faces are drawn in cells of this size (map metres).
const CELL_M := 64.0
## Physics layers (05 §6): 2 static world, 9 wind blockers.
const CLIFF_LAYERS := (1 << 1) | (1 << 8)

var coord := Vector2i.ZERO
var state := State.UNLOADED
## The region file's objects: {kind: {type id: [[sid, x, y, z, yaw, ...], ...]}}
var objects := {}
var _delta := {}
var _steps: Array[Callable] = []
var _world: WorldData
var _kit: RockKit


func _init(region: Vector2i = Vector2i.ZERO) -> void:
	coord = region
	name = "Region_%d_%d" % [region.x, region.y]


## Starts loading with the saved `delta`; the work is done by load_step().
## Without a world (tests) the region has no file content.
func begin_load(delta: Dictionary, world: WorldData = null, kit: RockKit = null) -> void:
	state = State.LOADING
	_delta = delta.duplicate(true)
	_world = world
	_kit = kit
	_steps = [_read_file, _apply_delta, _build_cliffs]


## Runs the next load step. Returns true when the region is fully loaded.
func load_step() -> bool:
	if not _steps.is_empty():
		var step: Callable = _steps.pop_front()
		step.call()
	if _steps.is_empty():
		state = State.ACTIVE
	return state == State.ACTIVE


## The change set to save for this region (empty while nothing changed).
func delta() -> Dictionary:
	return _delta.duplicate(true)


func _apply_delta() -> void:
	pass


func _read_file() -> void:
	objects = {}
	if _world == null:
		return
	var text := _world.read_indexed("regions", "%d_%d.json" % [coord.x, coord.y])
	if text == "":
		if not _world.errors.is_empty():
			Log.error("region", "; ".join(_world.errors))
			_world.errors.clear()
		return
	var doc: Variant = JSON.parse_string(text)
	if doc is Dictionary:
		objects = (doc as Dictionary).get("objects", {})


## Cliff faces: one MultiMesh per type and CELL_M cell (so the engine can
## cull cells and pick mesh LODs per cell), and one static body holding a
## collision shape per face.
func _build_cliffs() -> void:
	var cliffs: Dictionary = objects.get("cliff", {})
	if cliffs.is_empty() or _kit == null:
		return
	var body := StaticBody3D.new()
	body.name = "Cliffs"
	body.collision_layer = CLIFF_LAYERS
	body.collision_mask = 0
	add_child(body)
	for type_id: String in cliffs:
		var shape := _kit.shape(type_id)
		var cells := {}
		for row: Array in cliffs[type_id]:
			var xf := cliff_transform(_world, row)
			var col := CollisionShape3D.new()
			col.shape = shape
			col.transform = xf
			body.add_child(col)
			var key := Vector2i(floori(float(row[1]) / CELL_M), floori(float(row[3]) / CELL_M))
			if not cells.has(key):
				cells[key] = []
			cells[key].append(xf)
		for key: Vector2i in cells:
			var xfs: Array = cells[key]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = _kit.mesh(type_id)
			mm.instance_count = xfs.size()
			for i in xfs.size():
				mm.set_instance_transform(i, xfs[i])
			var draw := MultiMeshInstance3D.new()
			draw.name = "Cliff_%s_%d_%d" % [type_id, key.x, key.y]
			draw.multimesh = mm
			draw.material_override = _kit.material()
			add_child(draw)


## The nodes drawing this region's cliff faces (one per type and cell).
func cliff_draws() -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for n in get_children():
		if n is MultiMeshInstance3D:
			out.append(n)
	return out


## Engine transform of a cliff row [sid, x, y, z, yaw°, pitch°] (map
## coordinates): the face's +Z is the slope's normal, its +Y runs up the
## slope, and the face's centre sits on the row's point, lifted off the
## slope by RockKit.FACE_LIFT_M.
static func cliff_transform(world: WorldData, row: Array) -> Transform3D:
	var yaw := deg_to_rad(float(row[4]))
	var slope := deg_to_rad(float(row[5]))
	var down := Vector3(sin(yaw), 0.0, -cos(yaw))
	var normal := Vector3(down.x * sin(slope), cos(slope), down.z * sin(slope))
	var up := Vector3(-down.x * cos(slope), sin(slope), -down.z * cos(slope))
	var basis := Basis(up.cross(normal), up, normal)
	var centre := world.map_to_world(Vector3(float(row[1]), float(row[2]), float(row[3])))
	return Transform3D(
		basis, centre - up * (RockKit.STAND_IN_M.y * 0.5) + normal * RockKit.FACE_LIFT_M
	)
