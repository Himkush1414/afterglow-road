extends TestCase
## GameClock: the T-08-2 rule with test tuning values (not the game's),
## scale, pause, hour and phase signals, sun elevation, save data.

const CFG := {
	"gmin_real_s": 1.5,
	"start_gmin": 100,
	"latitude_deg": 40.0,
	"sun_declination_deg": 10.0,
	"solar_noon_h": 12.0,
	"night_below_deg": -10.0,
	"golden_from_deg": 0.0,
	"day_from_deg": 6.0,
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
