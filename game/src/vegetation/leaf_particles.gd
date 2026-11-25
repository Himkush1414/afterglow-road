class_name LeafParticles
extends GPUParticles3D
## Leaf cards blown from crowns in strong wind (06 §A4, 08 §5.3). The
## emission points are crown points of the nearest leafy trees within
## radius_m of the camera (record position, crown_height x height x scale
## up), rebuilt on a worker once the camera moved reselect_m. Particles are
## emitted while the wind at the camera, raised to the mean crown height,
## is at least min_wind_ms; they start along the wind and sink slowly. All
## numbers come from the optional "leaf_particles" object of the "trees"
## tuning; without it the node stays off.

const CARD_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, shadows_disabled, specular_disabled;
uniform vec3 colour : source_color = vec3(0.36, 0.42, 0.18);

void fragment() {
	// A leaf outline: an ellipse pointed at both ends, a darker midrib.
	vec2 p = UV * 2.0 - 1.0;
	float w = (1.0 - p.y * p.y) * 0.55;
	if (abs(p.x) > w) {
		discard;
	}
	float rib = smoothstep(0.0, 0.08, abs(p.x));
	ALBEDO = colour * mix(0.7, 1.0, rib) * (COLOR.rgb * 0.4 + 0.6);
	BACKLIGHT = colour * 0.5;
}
"""

## Wind speed in m/s at an engine position; set by setup() from the wind.
var wind_of: Callable
## Crown points (engine positions) the emitter uses now.
var points := PackedVector3Array()

var _cfg := {}
var _wind: Wind
var _field: TreeField
var _world: WorldData
## Per tree type: crown height above the ground in metres at scale 1, or -1
## for a type without a crown.
var _crowns := PackedFloat32Array()
var _built_at := Vector3(INF, INF, INF)
var _crown_y := 0.0
var _task := -1
var _result: Variant = null
var _mutex := Mutex.new()


## False when the tuning has no leaf particles (the node stays off).
func setup(
	field: TreeField, world: WorldData, defs: Array, wind: Wind, cfg: Dictionary, mult: float
) -> bool:
	_wait()
	emitting = false
	_cfg = cfg
	_field = field
	_world = world
	points = PackedVector3Array()
	_built_at = Vector3(INF, INF, INF)
	if cfg.is_empty():
		return false
	_wind = wind
	if wind != null:
		wind_of = wind.speed_at
	_crowns.clear()
	for d: Dictionary in defs:
		var leafy := float(d.get("canopy_r_m", 0.0)) > 0.0
		_crowns.append(float(d.height_m) * float(cfg.crown_height) if leafy else -1.0)
	amount = maxi(1, roundi(float(cfg.amount) * mult))
	lifetime = float(cfg.lifetime_s)
	local_coords = false
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_POINTS
	pm.spread = 25.0
	pm.gravity = Vector3(0.0, -float(cfg.gravity_ms2), 0.0)
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.angular_velocity_min = -180.0
	pm.angular_velocity_max = 180.0
	pm.scale_min = 0.7
	pm.scale_max = 1.3
	process_material = pm
	var card := QuadMesh.new()
	card.size = Vector2.ONE * float(cfg.size_m)
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = CARD_SHADER
	mat.shader = shader
	var c: Array = cfg.colour
	mat.set_shader_parameter("colour", Color(float(c[0]), float(c[1]), float(c[2])))
	card.material = mat
	draw_pass_1 = card
	return true


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		update(cam.global_position)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_wait()


## Rebuilds the crown points when `eye` moved reselect_m, picks up a finished
## rebuild, and switches emission by the wind at the crowns.
func update(eye: Vector3) -> void:
	if _cfg.is_empty() or _world == null:
		return
	_collect()
	if _task < 0 and eye.distance_to(_built_at) >= float(_cfg.reselect_m):
		_built_at = eye
		_task = WorkerThreadPool.add_task(_build.bind(eye), false, "leaf points")
	var speed := 0.0
	if not points.is_empty() and wind_of.is_valid():
		speed = wind_of.call(Vector3(eye.x, _crown_y, eye.z))
	emitting = not points.is_empty() and speed >= float(_cfg.min_wind_ms)
	if emitting:
		var pm := process_material as ParticleProcessMaterial
		var w := Vector3(_wind.dir.x, 0.0, _wind.dir.y) if _wind != null else Vector3.RIGHT
		pm.direction = (w + Vector3(0.0, 0.2, 0.0)).normalized()
		pm.initial_velocity_min = speed * float(_cfg.drift) * 0.7
		pm.initial_velocity_max = speed * float(_cfg.drift) * 1.3


## Waits for a rebuild in flight and takes its points (for tests).
func wait_for_points() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_collect()


## The crown points of the leafy trees nearest `eye` within radius_m, at
## most points_max, nearest first (any thread: reads only).
func crown_points(eye: Vector3) -> PackedVector3Array:
	var m := _world.world_to_map(eye)
	var at := Vector2(m.x, m.z)
	var radius := float(_cfg.radius_m)
	var lo := WorldData.tree_chunk_of_map(m - Vector3(radius, 0.0, radius))
	var hi := WorldData.tree_chunk_of_map(m + Vector3(radius, 0.0, radius))
	var found := []
	for cz in range(maxi(lo.y, 0), hi.y + 1):
		for cx in range(maxi(lo.x, 0), hi.x + 1):
			var c := Vector2i(cx, cz)
			var raw := _field.chunk_records(c)
			for i in raw.size() / TreeField.RECORD_BYTES:
				var r := TreeField.decode(raw, c, i)
				var crown: float = _crowns[r.model] if r.model < _crowns.size() else -1.0
				var map: Vector2 = r.map
				var d2 := map.distance_squared_to(at)
				if crown < 0.0 or d2 > radius * radius:
					continue
				var pos := _world.map_to_world(Vector3(map.x, 0.0, map.y))
				pos.y = _world.height_at(pos.x, pos.z) + crown * float(r.scale)
				found.append([d2, pos])
	found.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out := PackedVector3Array()
	for f: Array in found.slice(0, int(_cfg.points_max)):
		out.append(f[1])
	return out


func _build(eye: Vector3) -> void:
	var pts := crown_points(eye)
	_mutex.lock()
	_result = pts
	_mutex.unlock()


func _collect() -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	var got: Variant = _result
	_result = null
	_mutex.unlock()
	if got == null:
		return
	points = got
	_apply_points()


func _apply_points() -> void:
	var pm := process_material as ParticleProcessMaterial
	if points.is_empty():
		pm.emission_point_count = 0
		return
	var img := Image.create(points.size(), 1, false, Image.FORMAT_RGBF)
	var box := AABB(points[0], Vector3.ZERO)
	var sum := 0.0
	for i in points.size():
		var p := points[i]
		img.set_pixel(i, 0, Color(p.x, p.y, p.z))
		box = box.expand(p)
		sum += p.y
	_crown_y = sum / points.size()
	pm.emission_point_texture = ImageTexture.create_from_image(img)
	pm.emission_point_count = points.size()
	# Leaves travel downwind for a lifetime and sink: grow the box to match.
	var reach := float(_cfg.lifetime_s) * 20.0
	visibility_aabb = box.grow(reach)


func _wait() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_mutex.lock()
	_result = null
	_mutex.unlock()
