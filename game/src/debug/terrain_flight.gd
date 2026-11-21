class_name TerrainFlight
extends RefCounted
## The scripted terrain flight of T-05-3 and T-05-7: a closed loop around
## the map centre, 20 km long on a full map (smaller maps get the largest
## loop that fits), flown at 40 m/s, 60 m above the highest ground near the
## camera, looking ahead and slightly down.

const LENGTH_M := 20000.0
const SPEED_MPS := 40.0
const CLEARANCE_M := 60.0
## Fraction of the map size the loop radius may reach.
const MAX_RADIUS := 0.4
## Ground is probed this far around the camera.
const PROBE_M := 64.0

var radius := 0.0
var duration_s := 0.0
var _world: WorldData


func _init(world: WorldData) -> void:
	_world = world
	radius = minf(LENGTH_M / TAU, MAX_RADIUS * world.size_m)
	duration_s = TAU * radius / SPEED_MPS


## Camera transform (engine coordinates) `t` seconds into the flight.
func pose(t: float) -> Transform3D:
	var angle := t * SPEED_MPS / radius
	var centre := _world.map_to_world(Vector3(_world.size_m, 0.0, _world.size_m) * 0.5)
	var p := centre + Vector3(cos(angle), 0.0, sin(angle)) * radius
	var ground := -INF
	for dz: float in [-PROBE_M, 0.0, PROBE_M]:
		for dx: float in [-PROBE_M, 0.0, PROBE_M]:
			ground = maxf(ground, _world.height_at(p.x + dx, p.z + dz))
	p.y = ground + CLEARANCE_M
	var forward := Vector3(-sin(angle), -0.15, cos(angle)).normalized()
	return Transform3D(Basis.looking_at(forward, Vector3.UP), p)
