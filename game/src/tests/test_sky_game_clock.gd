extends TestCase
## GameClock: the T-08-2 rule with test tuning values (not the game's),
## scale, pause, hour and phase signals, sun and moon positions (T-08-1 and
## T-08-3 in the general form; T-08-3 also on the loaded content), save data.

const CFG := {
	"gmin_real_s": 1.5,
	"start_gmin": 100,
	"latitude_deg": 40.0,
	"sun_declination_deg": 10.0,
	"solar_noon_h": 12.0,
	"night_below_deg": -10.0,
	"golden_from_deg": 0.0,
	"day_from_deg": 6.0,
	"moon_cycle_days": 6,
	"moon_phase_at_start": 0.25,
	"moon_declination_deg": -10.0,
}

var _c: GameClock
var _hours: Array[int] = []
var _phases: Array[int] = []


func before_each() -> void:
	_c = GameClock.new()
	_c.configure(CFG)
	_hours.clear()
	_phases.clear()
	_c.hour_changed.connect(func(h: int) -> void: _hours.append(h))
	_c.phase_changed.connect(func(p: int) -> void: _phases.append(p))


func after_each() -> void:
	_c.free()


func test_a_game_day_takes_its_real_seconds_at_scale_one() -> void:
	# T-08-2 in the general form: 1,440 game minutes in 1,440 × gmin_real_s
	# real seconds ± 1 s, advanced in 60 Hz frames.
	var real := 1440.0 * float(CFG.gmin_real_s)
	var frames := int(real * 60.0)
	for f in frames:
		_c.advance(1.0 / 60.0)
	check_near(_c.now_gmin * float(CFG.gmin_real_s), real, 1.0, "real seconds for one day")
	check_eq(_c.day(), 2)


func test_scale_and_pause() -> void:
	_c.time_scale = 60.0
	_c.advance(3.0)
	check_near(_c.now_gmin, 120.0, 1e-9, "60x")
	_c.paused = true
	_c.advance(100.0)
	check_near(_c.now_gmin, 120.0, 1e-9, "paused")
	_c.paused = false
	_c.time_scale = -5.0
	check_eq(_c.time_scale, 0.0, "negative scale clamps to 0")
	_c.advance(10.0)
	check_near(_c.now_gmin, 120.0, 1e-9, "scale 0")


func test_one_day_announces_every_hour_and_phase_in_order() -> void:
	check_eq(_c.phase, GameClock.Phase.NIGHT, "midnight is night")
	_c.time_scale = 60.0
	_c.advance(1440.0 * float(CFG.gmin_real_s) / 60.0)
	var expected_hours: Array[int] = []
	for h in range(1, 24):
		expected_hours.append(h)
	expected_hours.append(0)
	check_eq(_hours, expected_hours)
	var order: Array[int] = [
		GameClock.Phase.DAWN,
		GameClock.Phase.GOLDEN,
		GameClock.Phase.DAY,
		GameClock.Phase.GOLDEN,
		GameClock.Phase.DUSK,
		GameClock.Phase.NIGHT,
	]
	check_eq(_phases, order, "phase order")


func test_sun_elevation_follows_the_formula() -> void:
	var lat: float = CFG.latitude_deg
	var dec: float = CFG.sun_declination_deg
	var noon: float = CFG.solar_noon_h
	check_near(_c.sun_elevation_deg(noon), 90.0 - lat + dec, 1e-6, "noon")
	# Sunrise: cos H = −tan φ · tan δ.
	var h0 := rad_to_deg(acos(-tan(deg_to_rad(lat)) * tan(deg_to_rad(dec)))) / 15.0
	check_near(_c.sun_elevation_deg(noon - h0), 0.0, 1e-6, "sunrise")
	check_near(_c.sun_elevation_deg(noon + h0), 0.0, 1e-6, "sunset")
	check_eq(_c.phase_at(noon - h0 - 0.01), GameClock.Phase.DAWN)
	check_eq(_c.phase_at(noon + h0 + 0.01), GameClock.Phase.DUSK)
	check_eq(_c.phase_at(noon - h0 + 0.01), GameClock.Phase.GOLDEN)


func test_sun_azimuth() -> void:
	var lat := deg_to_rad(float(CFG.latitude_deg))
	var dec := deg_to_rad(float(CFG.sun_declination_deg))
	var noon: float = CFG.solar_noon_h
	check_near(_c.sun_azimuth_deg(noon), 180.0, 1e-6, "south at noon")
	var h0 := rad_to_deg(acos(-tan(lat) * tan(dec))) / 15.0
	# At rise and set: cos A = sin δ / cos φ.
	var rise_az := rad_to_deg(acos(sin(dec) / cos(lat)))
	check_near(_c.sun_azimuth_deg(noon - h0), rise_az, 1e-6, "rises north of east")
	check_near(_c.sun_azimuth_deg(noon + h0), 360.0 - rise_az, 1e-6, "sets north of west")
	check_near(_c.sun_azimuth_deg(noon + 12.0), 0.0, 1e-6, "north at midnight")
	check(_c.sun_azimuth_deg(noon - 3.0) < 180.0, "east of south in the morning")


func test_moon_phase_cycle_and_light() -> void:
	var cycle := float(CFG.moon_cycle_days) * GameClock.GMIN_PER_DAY
	check_near(_c.moon_phase(0.0), float(CFG.moon_phase_at_start), 1e-12, "start phase")
	for g: float in [0.0, 333.3, 4000.0, 12345.6]:
		check_near(_c.moon_phase(g + cycle), _c.moon_phase(g), 1e-9, "repeats after a cycle")
		check_near(_c.moon_phase(g + 3.0 * cycle), _c.moon_phase(g), 1e-9, "and after three")
	check_near(_c.moon_phase(cycle * 0.25), 0.5, 1e-12, "full a quarter cycle later")
	check_near(GameClock.moon_illumination(0.0), 0.0, 1e-12, "new")
	check_near(GameClock.moon_illumination(0.5), 1.0, 1e-12, "full")
	check_near(GameClock.moon_illumination(0.25), 0.5, 1e-12, "half")
	var midnight := float(CFG.solar_noon_h) + 12.0
	var top := 90.0 - float(CFG.latitude_deg) + float(CFG.moon_declination_deg)
	check_near(_c.moon_azimuth_deg(midnight, 0.5), 180.0, 1e-6, "full moon south at midnight")
	check_near(_c.moon_elevation_deg(midnight, 0.5), top, 1e-6, "and at its highest")


## Clock hours (16 to 23) where the full moon (phase held at 0.5) rises,
## and where the sun sets, found by bisection on the elevation.
func _full_moon_rise_and_sunset(c: GameClock) -> Vector2:
	var moon := func(t: float) -> float: return c.moon_elevation_deg(t, 0.5)
	var sun := func(t: float) -> float: return -c.sun_elevation_deg(t)
	return Vector2(_rising_root(moon, 12.0, 24.0), _rising_root(sun, 12.0, 24.0))


func _rising_root(f: Callable, a: float, b: float) -> float:
	if float(f.call(a)) >= 0.0 or float(f.call(b)) < 0.0:
		return NAN
	for i in 60:
		var m := (a + b) * 0.5
		if float(f.call(m)) < 0.0:
			a = m
		else:
			b = m
	return (a + b) * 0.5


func test_full_moon_rises_at_sunset() -> void:
	# T-08-3 in the general form: with the moon's declination opposite the
	# sun's, the full moon crosses 0° within 20 game minutes of sunset.
	var r := _full_moon_rise_and_sunset(_c)
	check(absf(r.x - r.y) * 60.0 <= 20.0, "rise %.3f h, sunset %.3f h" % [r.x, r.y])


func test_full_moon_rises_at_sunset_on_the_content() -> void:
	var cfg := ContentDB.tuning("clock")
	if not check(not cfg.is_empty(), "content has a clock group"):
		return
	var c := GameClock.new()
	c.configure(cfg)
	var r := _full_moon_rise_and_sunset(c)
	check(absf(r.x - r.y) * 60.0 <= 20.0, "rise %.3f h, sunset %.3f h" % [r.x, r.y])
	var cycle := float(cfg.moon_cycle_days) * GameClock.GMIN_PER_DAY
	check_near(c.moon_phase(777.0 + cycle), c.moon_phase(777.0), 1e-9, "repeats after a cycle")
	c.free()


func test_jumps_announce_once() -> void:
	_c.new_game()
	check_near(_c.now_gmin, float(CFG.start_gmin), 1e-9, "new game time")
	check_eq(_hours, [1] as Array[int])
	_hours.clear()
	_c.set_now(2 * 1440.0 + 13 * 60.0 + 5.0)
	check_eq(_hours, [13] as Array[int], "one hour signal for a jump")
	check_eq(_phases, [GameClock.Phase.DAY] as Array[int], "one phase signal for a jump")
	check_eq([_c.day(), _c.hour, _c.minute()], [3, 13, 5])


func test_save_data_round_trip_and_bad_values() -> void:
	_c.set_now(5000.25)
	var data := _c.save_data()
	var other := GameClock.new()
	other.configure(CFG)
	check(other.load_data(data), "loads")
	check_eq(other.now_gmin, 5000.25)
	check(not other.load_data({}), "missing value refused")
	check(not other.load_data({"now_gmin": -1.0}), "negative refused")
	check(not other.load_data({"now_gmin": "x"}), "wrong type refused")
	check_eq(other.now_gmin, 5000.25, "unchanged after refusals")
	other.free()


func test_an_unconfigured_clock_stays_stopped() -> void:
	var bare := GameClock.new()
	bare.advance(10.0)
	check_eq(bare.now_gmin, 0.0)
	bare.free()
