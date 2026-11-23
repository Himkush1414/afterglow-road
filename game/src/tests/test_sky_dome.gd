extends TestCase
## SkyDome: sky setup, one parameter update per game minute with prev/next
## pairs (T-08-4, first half), star fade and turn, the shader's uniforms.

const CLOCK := {
	"gmin_real_s": 1.0,
	"start_gmin": 0,
	"latitude_deg": 40.0,
	"sun_declination_deg": 10.0,
	"solar_noon_h": 12.0,
	"night_below_deg": -10.0,
	"golden_from_deg": 0.0,
	"day_from_deg": 6.0,
	"moon_cycle_days": 4,
	"moon_phase_at_start": 0.0,
	"moon_declination_deg": -10.0,
}
const SKY := {
	"ramp":
	[
		{
			"elev_deg": -10,
			"zenith": "#000000",
			"horizon": "#202020",
			"sun_colour": "#FF8000",
			"sun_energy": 0,
			"ambient_energy": 0.2
		},
		{
			"elev_deg": 40,
			"zenith": "#0000FF",
			"horizon": "#FFFFFF",
			"sun_colour": "#FFFFFF",
			"sun_energy": 3.0,
			"ambient_energy": 1.0
		},
	],
	"moon_colour": "#8080FF",
	"moon_energy_base": 0.02,
	"moon_energy_illum": 0.2,
	"moon_cloud_dim": 0.5,
	"sun_shadow_above_deg": -2,
	"overcast_sun_dim": 0.75,
	"overcast_colour": "#808080",
}

var _clock: GameClock
var _lights: SkyLights
var _dome: SkyDome


func before_each() -> void:
	_clock = GameClock.new()
	_clock.configure(CLOCK)
	_lights = SkyLights.new()
	_lights.setup(_clock, SKY)
	_dome = SkyDome.new()
	check(_dome.setup(_clock, _lights, 128), "setup: %s" % [_dome.errors])


func after_each() -> void:
	_dome.free()
	_lights.free()
	_clock.free()


func test_setup_builds_an_incremental_sky() -> void:
	check_eq(_dome.environment.background_mode, Environment.BG_SKY)
	check_eq(_dome.environment.ambient_light_source, Environment.AMBIENT_SOURCE_SKY)
	check_eq(_dome.sky.process_mode, Sky.PROCESS_MODE_INCREMENTAL)
	check_eq(_dome.sky.radiance_size, Sky.RADIANCE_SIZE_128)
	var other := SkyDome.new()
	check(other.setup(_clock, _lights, 64), "64 is supported")
	check_eq(other.sky.radiance_size, Sky.RADIANCE_SIZE_64)
	check(not other.setup(_clock, _lights, 100), "100 is refused")
	other.free()


func test_shader_declares_every_pair() -> void:
	var names: Array[String] = []
	for u: Dictionary in _dome.material.shader.get_shader_uniform_list():
		names.append(u.name)
	for key in SkyDome.KEYS:
		check("prev_" + key in names and "next_" + key in names, "pair %s" % key)
	for key: String in ["blend_t0", "blend_s", "time_rollover_s", "pole"]:
		check(key in names, key)


func test_one_update_per_game_minute() -> void:
	# T-08-4, first half: 30 real seconds of 60 Hz frames at one game minute
	# per real second change the parameters once per game minute.
	_clock.set_now(600.0)
	var changes := 0
	var last: Variant = null
	for f in 30 * 60:
		_clock.advance(1.0 / 60.0)
		_dome._process(1.0 / 60.0)
		var z: Variant = _dome.material.get_shader_parameter("next_sun_dir")
		if z != last:
			changes += 1
			last = z
	check_eq(_dome.updates, 30, "updates")
	check_near(float(changes), 30.0, 1.0, "next_sun_dir changes")


func test_prev_is_the_last_next() -> void:
	_dome.show_minute(600)
	var first: Vector3 = _dome.material.get_shader_parameter("next_sun_dir")
	check_eq(_dome.material.get_shader_parameter("prev_sun_dir"), first, "first show: no blend")
	_dome.show_minute(601)
	check_eq(_dome.material.get_shader_parameter("prev_sun_dir"), first, "blends from the last")
	var t0 := float(_dome.material.get_shader_parameter("blend_t0"))
	check_near(t0, ShaderClock.now(), 0.5, "blend starts now on the shaders' clock")
	check_near(float(_dome.material.get_shader_parameter("blend_s")), 1.0, 1e-9, "one minute")
	_clock.time_scale = 60.0
	_dome.show_minute(602)
	check_near(float(_dome.material.get_shader_parameter("blend_s")), 1.0 / 60.0, 1e-9, "faster")


func test_stars_fade_with_the_sun_and_clouds() -> void:
	check_near(float(_dome.values_at(0.0).stars), 1.0, 1e-9, "midnight")
	check_near(float(_dome.values_at(720.0).stars), 0.0, 1e-9, "noon")
	_dome.cloud_cover = 0.75
	check_near(float(_dome.values_at(0.0).stars), 0.25, 1e-9, "overcast")


func test_stars_turn_with_the_sun() -> void:
	var pole := SkyDome.pole(float(CLOCK.latitude_deg))
	check(pole.is_equal_approx(Vector3(0, sin(deg_to_rad(40.0)), -cos(deg_to_rad(40.0)))), "pole")
	for h: float in [8.0, 12.0, 17.0]:
		var a: Vector3 = _dome.values_at(h * 60.0).sun_dir
		var b: Vector3 = _dome.values_at((h + 1.0) * 60.0).sun_dir
		var turn := SkyDome.star_angle((h + 1.0) * 60.0) - SkyDome.star_angle(h * 60.0)
		check(a.rotated(pole, turn).is_equal_approx(b), "the sky turns with the sun at %s h" % h)


func test_shader_clock_reads_the_wall_clock_plus_its_offset() -> void:
	var rollover := ShaderClock.rollover_s()
	check_eq(
		rollover, float(ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs"))
	)
	var want := fposmod(Time.get_ticks_usec() / 1e6 + ShaderClock.offset_s, rollover)
	check_near(ShaderClock.now(), want, 0.05, "now")
	check(ShaderClock.now() >= 0.0 and ShaderClock.now() < rollover, "wrapped")


func test_cloud_drift_stays_continuous_when_the_wind_changes() -> void:
	_dome.wind = Vector2(2.0, 0.0)
	_dome._advance_drift(10.0)
	check(_dome.drift_at(13.0).is_equal_approx(Vector2(6.0, 0.0)), "3 s at 2 m/s")
	_dome.wind = Vector2(0.0, 1.0)
	_dome._advance_drift(13.0)
	check(_dome.drift_at(13.0).is_equal_approx(Vector2(6.0, 0.0)), "no jump at the change")
	check(_dome.drift_at(15.0).is_equal_approx(Vector2(6.0, 2.0)), "then the new wind")
	var rollover := ShaderClock.rollover_s()
	_dome._advance_drift(rollover - 1.0)
	var before := _dome.drift_at(rollover - 1.0)
	check(_dome.drift_at(1.0).is_equal_approx(before + Vector2(0.0, 2.0)), "across the rollover")


func test_cloud_noise_and_cover() -> void:
	for tex: NoiseTexture2D in [_dome.cumulus_texture, _dome.cirrus_texture]:
		check(tex.seamless and tex.width == 512 and tex.height == 512, "512² seamless noise")
	check(_dome.material.get_shader_parameter("cumulus_tex") == _dome.cumulus_texture, "bound")
	_dome.cloud_cover = 0.6
	_dome.cloud_darkness = 0.3
	var v := _dome.values_at(720.0)
	check_eq([v.cloud_cover, v.cloud_darkness], [0.6, 0.3], "weather inputs reach the shader")


func _glow_dome() -> SkyDome:
	var sky: Dictionary = SKY.duplicate(true)
	sky.glow = {
		"target_poi": "t",
		"centre_colour": "#00FF00",
		"edge_colour": "#FF0000",
		"width_deg": 10,
		"scroll_rad_s": [0.001, 0.002],
		"intensity": 0.1,
		"target_end_gain": 2.0,
		"full_below_deg": -10,
		"cloud_dim": 0.5,
		"azimuth_min_deg": 20,
		"azimuth_max_deg": 70,
		"ended_gain": 1.5
	}
	_lights.setup(_clock, sky)
	var dome := SkyDome.new()
	check(dome.setup(_clock, _lights, 128), "setup: %s" % [dome.errors])
	return dome


func test_glow_strength_by_sun_clouds_and_story() -> void:
	check_eq(_dome.glow_strength(-20.0), 0.0, "no glow configured")
	var dome := _glow_dome()
	check_eq(dome.glow_strength(5.0), 0.0, "sun up")
	check_near(dome.glow_strength(-5.0), 0.5, 1e-9, "half way down")
	check_near(dome.glow_strength(-30.0), 1.0, 1e-9, "full")
	dome.cloud_cover = 1.0
	check_near(dome.glow_strength(-30.0), 0.5, 1e-9, "dimmed by overcast")
	dome.cloud_cover = 0.0
	dome.story_ended = true
	check_near(dome.glow_strength(-30.0), 1.5, 1e-9, "brighter after the end")
	var sigma := float(dome.material.get_shader_parameter("glow_sigma"))
	check_near(sigma * 2.3548, deg_to_rad(10.0), 1e-6, "width is the full width at half maximum")
	dome.free()


func test_glow_azimuth_follows_the_target_within_its_range() -> void:
	var dome := _glow_dome()
	check_near(dome.glow_azimuth_deg(Vector3.ZERO), 45.0, 1e-9, "no target: middle")
	dome.has_glow_target = true
	dome.glow_target = Vector3(100.0, 50.0, -100.0)  # north-east
	check_near(dome.glow_azimuth_deg(Vector3.ZERO), 45.0, 1e-6, "north-east")
	dome.glow_target = Vector3(100.0, 0.0, -10.0)  # nearly east
	check_near(dome.glow_azimuth_deg(Vector3.ZERO), 70.0, 1e-6, "clamped high")
	dome.glow_target = Vector3(-100.0, 0.0, -100.0)  # north-west
	check_near(dome.glow_azimuth_deg(Vector3.ZERO), 20.0, 1e-6, "clamped low")
	dome.glow_target = Vector3(100.0, 50.0, -100.0)
	dome.follow_glow(Vector3.ZERO)
	check_near(float(dome.material.get_shader_parameter("glow_azimuth")), PI / 4.0, 1e-6, "set")
	dome.follow_glow(Vector3(0.1, 0.0, 0.0))
	check_near(
		float(dome.material.get_shader_parameter("glow_azimuth")),
		PI / 4.0,
		1e-6,
		"small moves wait"
	)
	check_eq(dome.material.get_shader_parameter("glow_end_elev"), 0.0, "reaches the horizon")
	dome.story_ended = true
	dome.follow_glow(Vector3.ZERO)
	var end := float(dome.material.get_shader_parameter("glow_end_elev"))
	check_near(end, atan2(50.0, Vector2(100.0, 100.0).length()), 1e-6, "ends at the target")
	dome.free()


func test_environment_settings_and_ambient() -> void:
	var env_cfg := {
		"exposure": 1.2,
		"tonemap_white": 5.0,
		"glow_intensity": 0.3,
		"glow_threshold": 1.1,
		"ambient_floor_colour": "#FFFFFF",
		"ambient_floor_energy": 0.1,
		"fog_k": 3.0,
		"sky_fog_clear_m": 12000,
		"sky_fog_full_m": 150,
		"mist_from_h": 5,
		"mist_to_h": 8,
		"mist_fade_h": 0.5,
		"mist_top_y": 130,
		"mist_mult": 6
	}
	var dome := SkyDome.new()
	check(dome.setup(_clock, _lights, 128, env_cfg), "setup: %s" % [dome.errors])
	var env := dome.environment
	check_eq(env.tonemap_mode, Environment.TONE_MAPPER_AGX)
	check_near(env.tonemap_exposure, 1.2, 1e-6, "exposure")
	check_near(env.tonemap_white, 5.0, 1e-6, "white")
	check(env.glow_enabled, "glow on")
	check_near(env.glow_intensity, 0.3, 1e-6, "glow intensity")
	check_near(env.glow_hdr_threshold, 1.1, 1e-6, "glow threshold")
	var floor_v: Vector3 = dome.material.get_shader_parameter("ambient_floor")
	check(floor_v.is_equal_approx(Vector3(0.1, 0.1, 0.1)), "ambient floor in linear light")
	dome.show_minute(720)
	var r := _lights.ramp.at(_clock.sun_elevation_deg(12.0))
	check_near(
		env.ambient_light_energy, float(r.ambient_energy), 1e-6, "ambient energy from the ramp"
	)
	var bad: Dictionary = env_cfg.duplicate()
	bad.ambient_floor_colour = "x"
	check(not dome.setup(_clock, _lights, 128, bad), "bad colour refused")
	dome.free()


func test_fog_mapping_helpers() -> void:
	check_near(SkyDome.fog_density(1200.0, 3.0), 0.0025, 1e-12, "k over visibility")
	check_eq(SkyDome.fog_density(0.0, 3.0), 0.0, "no visibility, no fog")
	check_near(SkyDome.sky_affect(12000.0, 12000.0, 150.0), 0.0, 1e-9, "clear sky untouched")
	check_near(SkyDome.sky_affect(150.0, 12000.0, 150.0), 1.0, 1e-9, "thick fog covers it")
	check_near(SkyDome.sky_affect(50.0, 12000.0, 150.0), 1.0, 1e-9, "and nearer")
	var mid := SkyDome.sky_affect(1341.6, 12000.0, 150.0)  # geometric middle
	check_near(mid, 0.25, 1e-3, "half way in log distance, squared")
	check_eq(SkyDome.mist_factor(4.0, 5.0, 8.0, 0.5), 0.0, "before")
	check_near(SkyDome.mist_factor(4.75, 5.0, 8.0, 0.5), 0.5, 1e-9, "fading in")
	check_eq(SkyDome.mist_factor(6.0, 5.0, 8.0, 0.5), 1.0, "inside")
	check_near(SkyDome.mist_factor(8.25, 5.0, 8.0, 0.5), 0.5, 1e-9, "fading out")
	check_eq(SkyDome.mist_factor(9.0, 5.0, 8.0, 0.5), 0.0, "after")


func test_fog_reaches_the_environment() -> void:
	var env_cfg := {
		"exposure": 1.0,
		"tonemap_white": 6.0,
		"glow_intensity": 0.4,
		"glow_threshold": 1.0,
		"ambient_floor_colour": "#000000",
		"ambient_floor_energy": 0.0,
		"fog_k": 3.0,
		"sky_fog_clear_m": 12000,
		"sky_fog_full_m": 150,
		"mist_from_h": 5,
		"mist_to_h": 8,
		"mist_fade_h": 0.5,
		"mist_top_y": 130,
		"mist_mult": 6
	}
	var dome := SkyDome.new()
	check(dome.setup(_clock, _lights, 128, env_cfg), "setup: %s" % [dome.errors])
	var env := dome.environment
	dome.show_minute(720)
	check(not env.fog_enabled, "no visibility set: no fog")
	dome.visibility_m = 1500.0
	dome.show_minute(721)
	check(env.fog_enabled and env.fog_mode == Environment.FOG_MODE_EXPONENTIAL, "exponential fog")
	check_near(env.fog_density, 0.002, 1e-9, "density")
	check_eq(env.fog_light_color, dome.values_at(721.0).horizon, "fog takes the horizon colour")
	check_eq(env.fog_height_density, 0.0, "no mist at noon")
	dome.show_minute(6 * 60)
	check_near(env.fog_height_density, 0.012, 1e-9, "dawn mist: six times the density")
	check_near(env.fog_height, 130.0, 1e-9, "below its top")
	dome.mist_allowed = false
	dome.show_minute(6 * 60 + 1)
	check_eq(env.fog_height_density, 0.0, "no mist outside clear weather")
	check(not env.volumetric_fog_enabled, "volumetric off by default")
	dome.volumetric = true
	dome.show_minute(6 * 60 + 2)
	check(env.volumetric_fog_enabled and is_equal_approx(env.volumetric_fog_density, 0.002), "on")
	dome.free()


func test_a_world_without_places_has_no_glow_target() -> void:
	var dome := _glow_dome()
	var world := WorldData.new()
	check(world.load_dir(ContentDB.SAMPLE_ROOT + "/world"), "sample world: %s" % [world.errors])
	check(not world.has_layer("pois.json"), "the sample world lists no places")
	dome.has_glow_target = true
	dome.find_glow_target(world)
	check(not dome.has_glow_target, "no target")
	check_eq(world.errors, PackedStringArray(), "nothing read")
	world.free()
	dome.free()
