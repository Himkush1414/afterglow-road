class_name MantleProbe
extends RefCounted
## Whether a body can mantle onto the obstacle in front of it (10 §4.1,
## §4.2): a face within reach, a walkable top between the mantle heights
## above the feet, free space of mantle_depth_m × mantle_room_m above the
## top edge (body-wide), a landing where the capsule fits standing or
## crouched, and a clear path up and over (Q-121).

## The face ray runs this far under the lowest mantle height, metres.
const FACE_BELOW_M := 0.05
## The top ray starts this far inside the face and above the highest top.
const TOP_INSET_M := 0.05
const TOP_ABOVE_M := 0.05
## Clearance kept above surfaces by the space and path tests, metres.
const CLEAR_M := 0.02
## The landing axis lies this much further in than one radius from the edge.
const LAND_INSET_M := 0.05


## {"rise": top above the feet, "raised": the feet over the start at top
## height, "landing": the feet on the top, "crouch": true when only a
## crouched capsule fits there}, or empty when the mantle is not possible.
## `cfg`: the movement tuning group; `forward`: the facing direction.
static func find(
	body: PhysicsBody3D, cfg: Dictionary, radius: float, forward: Vector3
) -> Dictionary:
	var space := body.get_world_3d().direct_space_state
	var feet := body.global_position
	var f := Vector3(forward.x, 0.0, forward.z).normalized()
	var lo := float(cfg.mantle_min_m)
	var hi := float(cfg.mantle_max_m)
	var walk := deg_to_rad(float(cfg.walk_slope_deg))
	var from := feet + Vector3.UP * (lo - FACE_BELOW_M)
	var face := _ray(space, body, from, from + f * (radius + float(cfg.mantle_reach_m)))
	if face.is_empty() or (face.normal as Vector3).angle_to(Vector3.UP) <= walk:
		return {}
	var n: Vector3 = face.normal
	var into := -Vector3(n.x, 0.0, n.z).normalized()
	var edge: Vector3 = face.position
	var probe := edge + into * TOP_INSET_M
	var top_from := Vector3(probe.x, feet.y + hi + TOP_ABOVE_M, probe.z)
	var top := _ray(space, body, top_from, Vector3(probe.x, feet.y + lo - TOP_ABOVE_M, probe.z))
	if top.is_empty() or (top.normal as Vector3).angle_to(Vector3.UP) > walk:
		return {}
	var top_y: float = (top.position as Vector3).y
	var rise := top_y - feet.y
	if rise < lo or rise > hi:
		return {}
	if not _space_free(space, body, cfg, radius, Vector3(edge.x, top_y, edge.z), into):
		return {}
	var landing := Vector3(edge.x, top_y + CLEAR_M, edge.z) + into * (radius + LAND_INSET_M)
	var raised := Vector3(feet.x, landing.y, feet.z)
	for h: float in [float(cfg.stand_height_m), float(cfg.crouch_height_m)]:
		var capsule := CapsuleShape3D.new()
		capsule.radius = radius
		capsule.height = h
		if (
			_fits(space, body, capsule, landing)
			and _path_clear(space, body, capsule, feet, raised, landing)
		):
			return {
				"rise": rise,
				"raised": raised,
				"landing": landing,
				"crouch": h < float(cfg.stand_height_m)
			}
	return {}


static func _ray(
	space: PhysicsDirectSpaceState3D, body: PhysicsBody3D, a: Vector3, b: Vector3
) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(a, b)
	query.exclude = [body.get_rid()]
	return space.intersect_ray(query)


## The mantle_depth_m × mantle_room_m box, body-wide, just above the top edge.
static func _space_free(
	space: PhysicsDirectSpaceState3D,
	body: PhysicsBody3D,
	cfg: Dictionary,
	radius: float,
	edge: Vector3,
	into: Vector3
) -> bool:
	var depth := float(cfg.mantle_depth_m)
	var room := float(cfg.mantle_room_m)
	var box := BoxShape3D.new()
	box.size = Vector3(2.0 * radius, room, depth)
	var centre := edge + into * (depth * 0.5) + Vector3.UP * (room * 0.5 + CLEAR_M)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.transform = Transform3D(Basis.looking_at(into), centre)
	query.exclude = [body.get_rid()]
	return space.intersect_shape(query, 1).is_empty()


static func _capsule_query(
	body: PhysicsBody3D, capsule: CapsuleShape3D, feet: Vector3
) -> PhysicsShapeQueryParameters3D:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.transform = Transform3D(Basis.IDENTITY, feet + Vector3.UP * (capsule.height * 0.5))
	query.exclude = [body.get_rid()]
	return query


static func _fits(
	space: PhysicsDirectSpaceState3D, body: PhysicsBody3D, capsule: CapsuleShape3D, feet: Vector3
) -> bool:
	return space.intersect_shape(_capsule_query(body, capsule, feet), 1).is_empty()


## Straight up from the start to top height, then across to the landing.
static func _path_clear(
	space: PhysicsDirectSpaceState3D,
	body: PhysicsBody3D,
	capsule: CapsuleShape3D,
	feet: Vector3,
	raised: Vector3,
	landing: Vector3
) -> bool:
	var start := feet + Vector3.UP * CLEAR_M
	var legs: Array[Array] = [[start, raised], [raised, landing]]
	for leg: Array in legs:
		var query := _capsule_query(body, capsule, leg[0])
		query.motion = (leg[1] as Vector3) - (leg[0] as Vector3)
		var hit := space.cast_motion(query)
		if hit.is_empty() or hit[0] < 1.0:
			return false
	return true
