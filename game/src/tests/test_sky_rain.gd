extends TestCase
## Rain exposure (T-08-10): 0 under a roof, 1 in the open, the canopy
## factor under dense canopy; the up ray tilts toward upwind with the wind;
## only the blocking layers count; tree cover from the world's mask.

const CFG := {
	"ray_start_m": 0.1,
	"ray_length_m": 40.0,
	"tilt_deg_per_ms": 0.3,
	"block_layers": [2, 3],
	"canopy_cover": 0.6,
	"canopy_factor": 0.6,
}
const WIND := {
	"tile_m": 180,
	"noise_side": 16,
	"noise_seed": 1,
	"noise_frequency": 0.05,
	"altitude_scale_m": 1000,
	"max_ms": 40,
	"shelter_by_biome": [1.0],
	"ray_height_m": 1.0,
	"ray_lengths_m": [3],
	"ray_weights": [0.5],
	"min_exposure": 0.1,
	"blocker_layer": 9,
}

var _rain: Rain
var _cover := 0.0
var _bodies: Array[Node] = []


func before_each() -> void:
	_rain = Rain.new()
	check(_rain.configure(CFG), "configure: %s" % [_rain.errors])
	_cover = 0.0
	_rain.canopy_of = func(_p: Vector3) -> float: return _cover
	(Engine.get_main_loop() as SceneTree).root.add_child(_rain)


func after_each() -> void:
	for b in _bodies:
		b.queue_free()
	_bodies.clear()
	if _rain.wind != null:
		_rain.wind.free()
	_rain.queue_free()


# gdlint:ignore = function-name
func test_T_08_10_roof_open_and_canopy() -> void:
	check_near(await _exposure_at(Vector3.ZERO), 1.0, 1e-9, "open")
	_roof(Vector3(0.0, 3.0, 0.0), 2)
	check_near(await _exposure_at(Vector3.ZERO), 0.0, 1e-9, "under a roof")
	check_near(await _exposure_at(Vector3(10.0, 0.0, 0.0)), 1.0, 1e-9, "beside the roof")
	_cover = 0.8
	check_near(await _exposure_at(Vector3(10.0, 0.0, 0.0)), 0.6, 1e-9, "dense canopy")
	check_near(await _exposure_at(Vector3.ZERO), 0.0, 1e-9, "roof under canopy")
	_cover = 0.6
	check_near(await _exposure_at(Vector3(10.0, 0.0, 0.0)), 1.0, 1e-9, "canopy at the limit")


func test_only_blocking_layers_shelter() -> void:
	_roof(Vector3(0.0, 2.5, 0.0), 3)
	check_near(await _exposure_at(Vector3.ZERO), 0.0, 1e-9, "player piece")
	_roof(Vector3(20.0, 2.5, 0.0), 9)
	check_near(await _exposure_at(Vector3(20.0, 0.0, 0.0)), 1.0, 1e-9, "wind blocker only")
	_roof(Vector3(40.0, 41.0, 0.0), 2)
	check_near(await _exposure_at(Vector3(40.0, 0.0, 0.0)), 1.0, 1e-9, "above the ray")
	_roof(Vector3(60.0, -0.05, 0.0), 2)
	check_near(await _exposure_at(Vector3(60.0, 0.0, 0.0)), 1.0, 1e-9, "the floor it stands on")


func test_the_ray_tilts_toward_upwind() -> void:
	var wind := Wind.new()
	check(wind.configure(WIND), "wind: %s" % [wind.errors])
	wind.dir = Vector2(1.0, 0.0)  # blows toward +x; upwind is -x
	wind.base = 20.0
	wind.gust = 0.0
	_rain.wind = wind
	var d := _rain.ray_direction(Vector3.ZERO)
	check_near(d.length(), 1.0, 1e-9, "unit")
	check_near(rad_to_deg(Vector3.UP.angle_to(d)), 6.0, 1e-6, "0.3° per m/s at 20 m/s")
	check(d.x < 0.0 and is_zero_approx(d.z), "toward upwind")
	# A roof 30 m up and 3 m upwind: missed straight up, hit by the tilted ray.
	_roof(Vector3(-3.15, 30.0, 0.0), 2, Vector3(1.0, 0.2, 4.0))
	check_near(await _exposure_at(Vector3.ZERO), 0.0, 1e-9, "driven rain finds the roof")
	wind.base = 0.0
	check_near(await _exposure_at(Vector3.ZERO), 1.0, 1e-9, "calm: straight up misses it")


func test_tree_cover_from_the_world_mask() -> void:
	var world := WorldData.new()
	check(world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), "sample world: %s" % [world.errors])
	check(world.mask().is_empty(), "the sample world has no mask")
	check_eq(world.tree_cover_at(0.0, 0.0), 0.0, "no mask: no cover")
	_rain.canopy_of = Callable()
	_rain.world = world
	check_near(await _exposure_at(Vector3.ZERO), 1.0, 1e-9, "open without a mask")
	# A mask with dense cover in the cell holding engine (0, 0).
	var side := world.mask_side()
	var bytes := PackedByteArray()
	bytes.resize(side * side * 4)
	var i := floori(world.origin_offset_m / WorldData.MASK_CELL_M)
	bytes[(i * side + i) * 4 + 3] = 204
	world._mask = bytes
	check_near(world.tree_cover_at(1.0, 1.0), 0.8, 1e-9, "A / 255 of the cell")
	check_eq(world.tree_cover_at(-1.0, 1.0), 0.0, "the next cell")
	check_near(await _exposure_at(Vector3(1.0, 0.0, 1.0)), 0.6, 1e-9, "dense canopy from the mask")
	world.free()
	var bad := Rain.new()
	check(not bad.configure({"block_layers": [0, 33]}), "layers outside 1..32 refused")
	check_eq(bad.errors.size(), 2)
	bad.free()


func test_weather_input() -> void:
	_rain.set_from_weather({"rain": 0.6})
	check_near(_rain.intensity, 0.6, 1e-9)
	var g: Variant = RenderingServer.global_shader_parameter_get("rain_intensity")
	if g != null:  # the headless renderer may not keep globals
		check_near(float(g), 0.6, 1e-6, "water shaders get the intensity")
	_rain.set_from_weather({"rain": 0.0})


func _roof(pos: Vector3, layer: int, size := Vector3(6.0, 0.2, 6.0)) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1 << (layer - 1)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = pos
	(Engine.get_main_loop() as SceneTree).root.add_child(body)
	_bodies.append(body)


func _exposure_at(pos: Vector3) -> float:
	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	await tree.physics_frame
	return _rain.exposure_at(pos)


func test_the_volume_follows_the_eye_slanted_by_the_wind() -> void:
	var cfg := CFG.duplicate()
	(
		cfg
		. merge(
			{
				"fall_ms": 9.0,
				"volume_m": [20, 12, 20],
				"streak_width_m": 0.015,
				"streak_length_m": 0.45,
				"streak_alpha": 0.3,
				"collision_size_m": 0.02,
				"height_field_m": 32,
				"height_field_res": 512,
				"splash_share": 0.25,
				"splash_s": 0.3,
				"splash_size_m": 0.04,
				"splash_speed_ms": 1.8,
				"splash_radius_m": 8.0,
				"shelter_check_s": 0.25,
			}
		)
	)
	check(_rain.configure(cfg), "configure: %s" % [_rain.errors])
	_rain.set_process(false)
	_rain.build_volume(800)
	var p := _rain.particles
	check_eq(p.amount, 800, "preset streaks")
	check_near(_rain.lifetime(), 12.0 / 9.0, 1e-9, "falls through 12 m at 9 m/s")
	check_eq(
		_rain.height_field.resolution, GPUParticlesCollisionHeightField3D.RESOLUTION_512, "512 px"
	)
	check(_rain.height_field.follow_camera_enabled, "height field follows the camera")
	check(not p.emitting, "dry: not emitting")
	check(not _rain.splashes.emitting, "dry: no splashes")
	check_eq(_rain.splashes.amount, 200, "splashes: a quarter of the streaks")
	var spm := _rain.splashes.process_material as ParticleProcessMaterial
	check_eq(spm.emission_shape, ParticleProcessMaterial.EMISSION_SHAPE_RING, "a disc")
	check_eq(spm.emission_ring_radius, 8.0, "of the splash radius")
	check_eq(spm.emission_ring_inner_radius, 0.0, "filled")
	check(_rain.splashes.sub_emitter.is_empty(), "splashes emit on their own")
	var mat := (_rain.splashes.draw_pass_1 as QuadMesh).material as ShaderMaterial
	check_eq(mat.get_shader_parameter("radius_m"), 8.0, "drawn within 8 m")
	var wind := Wind.new()
	check(wind.configure(WIND), "wind: %s" % [wind.errors])
	wind.dir = Vector2(0.0, 1.0)  # blows toward +z
	wind.base = 9.0
	wind.gust = 0.0
	_rain.wind = wind
	_rain.intensity = 0.6
	_rain.ground_of = func(_p: Vector3) -> float: return 48.5
	var eye := Vector3(100.0, 50.0, -30.0)
	_rain.follow(eye)
	var pm := p.process_material as ParticleProcessMaterial
	var w := wind.speed_at(eye)
	check_near(w, 9.45, 1e-9, "9 m/s raised 5% at 50 m")
	var slant := rad_to_deg(atan(w / 9.0))
	check_near(rad_to_deg(Vector3.DOWN.angle_to(pm.direction)), slant, 1e-4, "slant atan(w / 9)")
	check(pm.direction.z > 0.0 and is_zero_approx(pm.direction.x), "slanted downwind")
	check_near(pm.initial_velocity_min, sqrt(w * w + 81.0), 1e-4, "speed")
	check_near(p.amount_ratio, 0.6, 1e-6, "amount follows the intensity")
	check(p.emitting, "raining")
	check(_rain.splashes.emitting, "raining: splashes")
	var drift := w * _rain.lifetime() * 0.5
	check(
		p.position.is_equal_approx(eye + Vector3(0.0, 6.0, -drift)),
		"top above, upwind: %s" % p.position
	)
	check(
		_rain.splashes.position.is_equal_approx(Vector3(100.0, 48.5, -30.0)),
		"splashes on the ground under the eye"
	)
	check_near(_rain.height_field.position.y, 50.0, 1e-9, "height field at the eye's height")
	_rain.build_volume(400)
	check_eq(String(_rain.splashes.name), "Splashes", "rebuilt with the same names")
	var bad := cfg.duplicate()
	bad.volume_m = [20, 12]
	check(not _rain.configure(bad), "volume needs 3 sizes")


func test_the_fallback_hides_under_a_roof_and_splashes_on_the_ground() -> void:
	var cfg := CFG.duplicate()
	(
		cfg
		. merge(
			{
				"fall_ms": 9.0,
				"volume_m": [20, 12, 20],
				"streak_width_m": 0.015,
				"streak_length_m": 0.45,
				"streak_alpha": 0.3,
				"collision_size_m": 0.02,
				"height_field_m": 32,
				"height_field_res": 512,
				"splash_share": 0.25,
				"splash_s": 0.3,
				"splash_size_m": 0.04,
				"splash_speed_ms": 1.8,
				"splash_radius_m": 8.0,
				"shelter_check_s": 0.25,
			}
		)
	)
	check(_rain.configure(cfg), "configure: %s" % [_rain.errors])
	_rain.set_process(false)
	_rain.build_volume(800, false)
	check(not _rain.collides, "fallback")
	check(_rain.height_field == null, "no height field")
	var pm := _rain.particles.process_material as ParticleProcessMaterial
	check_eq(pm.collision_mode, ParticleProcessMaterial.COLLISION_DISABLED, "drops do not collide")
	var spm := _rain.splashes.process_material as ParticleProcessMaterial
	check_eq(spm.emission_shape, ParticleProcessMaterial.EMISSION_SHAPE_RING, "splash disc")
	check_eq(spm.emission_ring_radius, 8.0, "of the splash radius")
	check(_rain.splashes.sub_emitter.is_empty(), "splashes emit on their own")
	_rain.ground_of = func(_p: Vector3) -> float: return 2.5
	_rain.intensity = 1.0
	_rain.follow(Vector3(10.0, 4.1, -3.0))
	check(
		_rain.splashes.position.is_equal_approx(Vector3(10.0, 2.5, -3.0)),
		"on the ground under the eye"
	)
	check(_rain.splashes.emitting, "splashing while it rains")
	_roof(Vector3(0.0, 3.0, 0.0), 2)
	var tree := Engine.get_main_loop() as SceneTree
	await tree.physics_frame
	await tree.physics_frame
	_rain.shelter(Vector3(0.0, 1.6, 0.0))
	check(not _rain.particles.visible and not _rain.splashes.visible, "hidden under the roof")
	_rain.shelter(Vector3(10.0, 1.6, 0.0))
	check(_rain.particles.visible and _rain.splashes.visible, "shown in the open")
	_rain.build_volume(800, true)
	_rain.shelter(Vector3(0.0, 1.6, 0.0))
	check(_rain.particles.visible, "with collisions the roof stops the drops instead")
	check(not _rain.splashes.visible, "no splashes seen from under a roof")
	check(_rain.height_field != null, "rebuilt with collisions")
