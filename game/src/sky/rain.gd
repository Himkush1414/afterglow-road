class_name Rain
extends Node3D
## Rain (08 §4.4): rain exposure of a point is 1 when a ray straight up,
## tilted toward upwind by the local wind speed, hits nothing on the
## blocking layers (buildings, player pieces, tents), else 0; under dense
## forest canopy it is scaled down. All numbers come from the "rain" tuning.

var errors: PackedStringArray = []
## Rain intensity 0..1 from the weather.
var intensity := 0.0
## Tilts the up ray; null or unconfigured means no tilt.
var wind: Wind
var world: WorldData
## Tree cover 0..1 at an engine position; defaults to the world's mask.
var canopy_of: Callable

var _cfg := {}
var _mask := 0


## Takes the "rain" tuning group. False and `errors` when a blocking layer
## is outside 1..32.
func configure(cfg: Dictionary) -> bool:
	errors.clear()
	_cfg = cfg
	_mask = 0
	for layer: Variant in cfg.block_layers:
		if int(layer) < 1 or int(layer) > 32:
			errors.append("rain: block layer %s outside 1..32" % layer)
		else:
			_mask |= 1 << (int(layer) - 1)
	return errors.is_empty()


func is_configured() -> bool:
	return not _cfg.is_empty()


## Takes the weather's blended parameters (rain intensity).
func set_from_weather(p: Dictionary) -> void:
	intensity = float(p.rain)


## Rain exposure 0..1 at an engine position.
func exposure_at(pos: Vector3) -> float:
	if _roofed(pos):
		return 0.0
	var cover := 0.0
	if canopy_of.is_valid():
		cover = float(canopy_of.call(pos))
	elif world != null and world.is_loaded():
		cover = world.tree_cover_at(pos.x, pos.z)
	return float(_cfg.canopy_factor) if cover > float(_cfg.canopy_cover) else 1.0


## Unit vector of the up ray at `pos`: tilted toward upwind by
## tilt_deg_per_ms per m/s of the local wind.
func ray_direction(pos: Vector3) -> Vector3:
	if wind == null or not wind.is_configured():
		return Vector3.UP
	var tilt := deg_to_rad(float(_cfg.tilt_deg_per_ms) * wind.speed_at(pos))
	var upwind := -Vector3(wind.dir.x, 0.0, wind.dir.y)
	return Vector3.UP * cos(tilt) + upwind * sin(tilt)


func _roofed(pos: Vector3) -> bool:
	if not is_inside_tree():
		return false
	var from := pos + Vector3(0.0, float(_cfg.ray_start_m), 0.0)
	var to := from + ray_direction(pos) * float(_cfg.ray_length_m)
	var q := PhysicsRayQueryParameters3D.create(from, to, _mask)
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()
