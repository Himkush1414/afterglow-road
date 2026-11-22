extends TestCase
## Wind: the gust field formula, altitude, scrolling downwind, the noise
## sampler, weather input, and exposure behind walls (T-08-12).

const CFG := {
	"tile_m": 180,
	"noise_side": 64,
	"noise_seed": 3,
	"noise_frequency": 0.05,
	"altitude_scale_m": 1000,
	"max_ms": 24,
	"shelter_by_biome": [1.2, 1.1, 0.5, 0.9, 0.8, 1.2, 1.0, 1.3, 0.35, 0.7],
	"ray_height_m": 1.0,
	"ray_lengths_m": [3, 8, 20],
	"ray_weights": [0.45, 0.30, 0.15],
	"min_exposure": 0.1,
	"blocker_layer": 9,
}
const ROCKY_HILLS := 6
const MOOR := 5

var _wind: Wind
var _bodies: Array[Node] = []


func before_each() -> void:
	_wind = Wind.new()
	check(_wind.configure(CFG), "configure: %s" % [_wind.errors])
	_wind.dir = Vector2(1.0, 0.0)
	_wind.base = 5.0
	_wind.gust = 0.4


func after_each() -> void:
	for b in _bodies:
		b.queue_free()
	_bodies.clear()
	if _wind.is_inside_tree():
		_wind.queue_free()
	else:
		_wind.free()


func test_speed_follows_the_formula() -> void:
	for p: Vector3 in [Vector3(10, 0, 20), Vector3(-333, 120, 4000), Vector3(7.5, 900, -12)]:
		var n := _wind.noise_at((Vector2(p.x, p.z) - _wind.scroll) / 180.0)
		var want := _wind.base_at(p.y) * (1.0 + 0.4 * (2.0 * n - 1.0))
		check_near(_wind.speed_at(p), want, 1e-9, "speed at %s" % p)
	check(_wind.vector_at(Vector3.ZERO).normalized().is_equal_approx(Vector3(1, 0, 0)), "downwind")


func test_altitude_raises_the_base_up_to_the_cap() -> void:
	_wind.base = 10.0
	check_near(_wind.base_at(-50.0), 10.0, 1e-9, "below sea level: base")
	check_near(_wind.base_at(500.0), 15.0, 1e-9, "500 m: x1.5")
	_wind.base = 20.0
	check_near(_wind.base_at(1000.0), 24.0, 1e-9, "capped")


func test_the_gust_field_moves_downwind() -> void:
	var p := Vector3(10.0, 0.0, 20.0)
	var before := _wind.speed_at(p)
	_wind.advance(2.0)
	check(_wind.scroll.is_equal_approx(Vector2(10.0, 0.0)), "scrolled base x dt")
	check_near(_wind.speed_at(p + Vector3(10.0, 0.0, 0.0)), before, 1e-6, "pattern moved 10 m")
	_wind.advance(36.0)  # 190 m: wraps at the 180 m tile
	check(_wind.scroll.is_equal_approx(Vector2(10.0, 0.0)), "wrapped at the tile")


func test_noise_sampler_matches_texels_and_tiles() -> void:
	var side := _wind.noise.get_width()
	for ij: Vector2i in [Vector2i(0, 0), Vector2i(5, 9), Vector2i(63, 63)]:
		var uv := (Vector2(ij) + Vector2(0.5, 0.5)) / side
		check_near(_wind.noise_at(uv), _wind.noise.get_pixel(ij.x, ij.y).r, 1e-6, "texel %s" % ij)
	var at := Vector2(0.123, 0.789)
	check_near(_wind.noise_at(at), _wind.noise_at(at + Vector2(1.0, -2.0)), 1e-6, "tiles")


func test_weather_input() -> void:
	_wind.set_from_weather({"wind_from_deg": 225.0, "wind_speed": 7.0, "gustiness": 0.3})
	check(_wind.dir.is_equal_approx(Vector2(sqrt(0.5), -sqrt(0.5))), "from SW toward NE")
	check_eq([_wind.base, _wind.gust], [7.0, 0.3])


func _wall(x: float) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1 << 8
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 3.0, 6.0)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(x, 1.0, 0.0)
	(Engine.get_main_loop() as SceneTree).root.add_child(body)
	_bodies.append(body)


func _exposure_with(walls: Array, biome: int) -> float:
	for b in _bodies:
		b.free()
	_bodies.clear()
	for x: float in walls:
		_wall(x)
	_wind.biome_of = func(_p: Vector3) -> int: return biome
	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	await tree.physics_frame
	return _wind.exposure_at(Vector3.ZERO)


func test_exposure_behind_walls() -> void:
	# T-08-12. The wind blows toward +x, so upwind walls stand at -x. Wall
	# cases use a shelter factor of 1.0 (rocky hills); open moor is 1.2.
	(Engine.get_main_loop() as SceneTree).root.add_child(_wind)
	var near := await _exposure_with([-2.0], ROCKY_HILLS)
	check(near <= 0.55, "wall 2 m upwind: %.3f" % near)
	var mid := await _exposure_with([-5.0], ROCKY_HILLS)
	check(mid <= 0.55 + 1e-9, "wall 5 m upwind: %.3f" % mid)
	var two := await _exposure_with([-3.0, -8.0], ROCKY_HILLS)
	check(two <= 0.25, "walls at 3 m and 8 m: %.3f" % two)
	var open := await _exposure_with([], MOOR)
	check_near(open, 1.2, 1e-9, "open moor")
	var downwind := await _exposure_with([4.0], ROCKY_HILLS)
	check_near(downwind, 1.0, 1e-9, "a wall downwind does not shelter")
	_wind.dir = Vector2(-1.0, 0.0)
	var turned := _wind.exposure_at(Vector3.ZERO)
	check(turned < 1.0, "the same wall shelters when the wind turns: %.3f" % turned)
	_wind.dir = Vector2(1.0, 0.0)
	var deep := await _exposure_with([-2.0], 8)
	check_near(deep, 0.1, 1e-9, "never below the minimum")
