extends TestCase
## SkyRamp interpolation and filling, SkyLights directions, energies and
## the one-shadow rule (T-08-6) with test values and on the loaded content.

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
			"sun_energy": 0,
			"ambient_energy": 0.2
		},
		{
			"elev_deg": 0,
			"zenith": "#404040",
			"horizon": "#FF0000",
			"horizon_sun": "#00FF00",
			"sun_colour": "#FF8000",
			"sun_energy": 1.0,
			"ambient_energy": 0.6
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


func _rig(clock_cfg: Dictionary, sky_cfg: Dictionary) -> SkyLights:
	var clock := GameClock.new()
	clock.configure(clock_cfg)
	var lights := SkyLights.new()
	lights.add_child(clock)
	check(lights.setup(clock, sky_cfg), "setup: %s" % [lights.errors])
	return lights


func test_ramp_interpolates_and_holds_at_the_ends() -> void:
	var r := SkyRamp.new()
	check(r.setup(SKY.ramp), "valid ramp: %s" % [r.errors])
	check_near(float(r.at(20.0).sun_energy), 2.0, 1e-9, "halfway energy")
	check_near(float(r.at(-5.0).ambient_energy), 0.4, 1e-9, "halfway ambient")
	check(
		(r.at(20.0).zenith as Color).is_equal_approx(Color.html("#404040").lerp(Color.BLUE, 0.5)),
		"halfway zenith"
	)
	check_eq(r.at(-60.0).zenith, Color.html("#000000"), "held below the first row")
	check_near(float(r.at(80.0).sun_energy), 3.0, 1e-9, "held above the last row")


func test_ramp_fills_missing_colours() -> void:
	var r := SkyRamp.new()
	r.setup(SKY.ramp)
	check_eq(r.rows[0].sun_colour, Color.html("#FF8000"), "sun colour from the row above")
	check_eq(r.rows[0].horizon_sun, Color.html("#202020"), "no own sun colour: plain horizon")
	check_eq(r.rows[2].horizon_sun, Color.html("#FFFFFF"), "toward-sun horizon = own sun colour")
	check_eq(r.rows[1].horizon_sun, Color.html("#00FF00"), "given toward-sun horizon kept")
	var top := SkyRamp.new()
	var rows: Array = SKY.ramp.duplicate(true)
	rows[2].erase("sun_colour")
	top.setup(rows)
	check_eq(top.rows[2].sun_colour, Color.html("#FF8000"), "top row takes the one below")


func test_ramp_errors() -> void:
	var r := SkyRamp.new()
	var rows: Array = SKY.ramp.duplicate(true)
	rows[1].zenith = "blue"
	check(not r.setup(rows), "bad colour refused")
	rows = SKY.ramp.duplicate(true)
	rows[2].elev_deg = -20
	check(not r.setup(rows), "falling elevations refused")
	rows = SKY.ramp.duplicate(true)
	rows[1].erase("sun_colour")
	rows[2].erase("sun_colour")
	check(not r.setup(rows), "no sun colour refused")
	var lights := SkyLights.new()
	var bad: Dictionary = SKY.duplicate(true)
	bad.moon_colour = "x"
	check(not lights.setup(null, bad), "bad moon colour refused")
	check(not lights.setup(null, {}), "missing group refused")
	lights.free()


func test_directions() -> void:
	check(SkyLights.direction(0.0, 0.0).is_equal_approx(Vector3(0, 0, -1)), "north")
	check(SkyLights.direction(0.0, 90.0).is_equal_approx(Vector3(1, 0, 0)), "east")
	check(SkyLights.direction(90.0, 123.0).is_equal_approx(Vector3.UP), "zenith")
	var lights := _rig(CLOCK, SKY)
	lights.apply(9.0 * 60.0)
	var clock: GameClock = lights.get_child(2)
	var toward := SkyLights.direction(clock.sun_elevation_deg(9.0), clock.sun_azimuth_deg(9.0))
	check(lights.sun.basis.z.is_equal_approx(toward), "sun light shines away from the sun")
	check(toward.x > 0.0 and toward.y > 0.0, "morning sun is east and up")
	lights.free()


func test_energies_and_colours() -> void:
	var lights := _rig(CLOCK, SKY)
	var clock: GameClock = lights.get_child(2)
	lights.apply(12.0 * 60.0)
	var r := lights.ramp.at(clock.sun_elevation_deg(12.0))
	check_near(lights.sun.light_energy, float(r.sun_energy), 1e-6, "noon sun energy from the ramp")
	check_eq(lights.sun.light_color, r.sun_colour)
	lights.cloud_cover = 1.0
	lights.apply(12.0 * 60.0)
	check_near(lights.sun.light_energy, float(r.sun_energy) * 0.25, 1e-6, "overcast dims the sun")
	# A 4-day cycle from phase 0: full on day 3 at 00:00, high in the south.
	lights.cloud_cover = 0.0
	var full := 2.0 * GameClock.GMIN_PER_DAY
	lights.apply(full)
	check_near(clock.moon_phase(full), 0.5, 1e-9, "full moon on day 3, 00:00")
	check(clock.moon_elevation_deg(0.0, 0.5) > 0.0, "and it is up")
	check_near(lights.moon.light_energy, 0.22, 1e-6, "full moon energy = base + illum")
	check_eq(lights.moon.light_color, Color.html("#8080FF"))
	lights.cloud_cover = 1.0
	lights.apply(full)
	check_near(lights.moon.light_energy, 0.11, 1e-6, "clouds dim the moon")
	lights.apply(full + 12.0 * 60.0)
	check_eq(lights.moon.light_energy, 0.0, "no moonlight while it is down")
	lights.free()


func _one_shadow_over_a_day(lights: SkyLights, label: String) -> void:
	var bad := 0
	for m in int(GameClock.GMIN_PER_DAY):
		lights.apply(float(m))
		if int(lights.sun.shadow_enabled) + int(lights.moon.shadow_enabled) != 1:
			bad += 1
	check_eq(bad, 0, "%s: minutes without exactly one shadow light" % label)


func test_one_shadow_light_at_any_time() -> void:
	# T-08-6: sweep 24 h at one-minute steps.
	var lights := _rig(CLOCK, SKY)
	_one_shadow_over_a_day(lights, "test values")
	lights.apply(12.0 * 60.0)
	check(lights.sun.shadow_enabled and not lights.moon.shadow_enabled, "sun casts by day")
	lights.apply(0.0)
	check(lights.moon.shadow_enabled and not lights.sun.shadow_enabled, "moon casts by night")
	lights.free()


func test_one_shadow_light_on_the_content() -> void:
	var sky := ContentDB.tuning("sky")
	if not check(not sky.is_empty(), "content has a sky group"):
		return
	var lights := _rig(ContentDB.tuning("clock"), sky)
	_one_shadow_over_a_day(lights, "content")
	lights.free()
