extends TestCase
## Weather: table checks, T-08-8 (10,000 changes, no forbidden pair, grace
## period, fog window) with test values and on the loaded content, T-08-9
## (wetting and drying), blending, wind, save data.

const CLOCK := {
	"gmin_real_s": 1.0,
	"start_gmin": 0,
	"latitude_deg": 45.0,
	"sun_declination_deg": 0.0,
	"solar_noon_h": 12.0,
	"night_below_deg": -10.0,
	"golden_from_deg": 0.0,
	"day_from_deg": 6.0,
	"moon_cycle_days": 8,
	"moon_phase_at_start": 0.0,
	"moon_declination_deg": 0.0,
}

var _clock: GameClock
var _w: Weather


func _state(id: String, cover: float, rain: float, vis: float) -> Dictionary:
	return {
		"id": id,
		"cloud_cover": cover,
		"cloud_darkness": cover * 0.5,
		"rain": rain,
		"wind_min_ms": 2.0,
		"wind_max_ms": 6.0,
		"gustiness": 0.2,
		"temp_day_c": 0.0,
		"temp_night_c": 0.0,
		"visibility_m": vis,
		"lightning": rain >= 1.0
	}


func _table() -> Dictionary:
	return {
		"states":
		[
			_state("sun", 0.1, 0.0, 10000.0),
			_state("grey", 0.6, 0.0, 6000.0),
			_state("wet", 0.9, 1.0, 1000.0),
			_state("mist", 0.4, 0.0, 200.0),
		],
		"transitions":
		[
			{"from": "sun", "p": [0.6, 0.3, 0.0, 0.1]},
			{"from": "grey", "p": [0.3, 0.3, 0.3, 0.1]},
			{"from": "wet", "p": [0.0, 0.5, 0.5, 0.0]},
			{"from": "mist", "p": [0.5, 0.4, 0.0, 0.1]},
		],
		"roll_every_gmin": 120,
		"blend_gmin": 10,
		"fog_state": "mist",
		"fog_start_from_h": 3,
		"fog_start_to_h": 8,
		"fog_end_h": 10,
		"fallback_state": "sun",
		"grace_state": "sun",
		"grace_until_gmin": 1080,
		"grace_then_state": "grey",
		"rain_states": ["wet"],
		"no_rain_before_gmin": 2160,
		"no_rain_state": "grey",
		"prevailing_from_deg": 225,
		"turn_deg": 40,
		"wet_full_gmin": 20,
		"dry_sun_gmin": 120,
		"dry_shade_gmin": 240,
		"sun_max_cover": 0.5,
		"mist_state": "sun"
	}


func before_each() -> void:
	_clock = GameClock.new()
	_clock.configure(CLOCK)
	_w = Weather.new()
	check(_w.configure(_table(), _clock), "configure: %s" % [_w.errors])


func after_each() -> void:
	_w.free()
	_clock.free()


func test_table_errors() -> void:
	var t := _table()
	t.transitions[0].p = [0.5, 0.3, 0.0, 0.1]
	check(not _w.configure(t, _clock), "row not summing to 1")
	t = _table()
	t.transitions.pop_back()
	check(not _w.configure(t, _clock), "state without a row")
	t = _table()
	t.fog_state = "snow"
	check(not _w.configure(t, _clock), "unknown named state")


## T-08-8 on `cfg`: 10,000 changes from a new game, for three save seeds.
func _simulate(cfg: Dictionary, label: String) -> void:
	var w := Weather.new()
	if not check(w.configure(cfg, _clock), "%s: %s" % [label, w.errors]):
		w.free()
		return
	var rows := {}
	var order: Array = cfg.states.map(func(s: Dictionary) -> String: return s.id)
	for row: Dictionary in cfg.transitions:
		rows[row.from] = row.p
	var grace := float(cfg.grace_until_gmin)
	var roll := float(cfg.roll_every_gmin)
	var saved_seed := Rng.save_seed
	for seed: int in [1, 77, 123456]:
		Rng.save_seed = seed
		w.new_game(float(cfg.grace_until_gmin) * 0.3)
		var forbidden := 0
		var grace_bad := 0
		var fog_bad := 0
		var rain_bad := 0
		var seen := {}
		for i in 10000:
			var t := w.next_change_gmin
			var from := w.state
			w.update(t)
			var to := w.state
			seen[to] = true
			var hours := fmod(t, GameClock.GMIN_PER_DAY) / 60.0
			if t < grace:
				grace_bad += int(to != cfg.grace_state)
			elif t < grace + roll:
				grace_bad += int(to != cfg.grace_then_state)
			elif float(rows[from][order.find(to)]) == 0.0:
				forbidden += 1
			if to == cfg.fog_state:
				var starts := (
					hours >= float(cfg.fog_start_from_h) and hours < float(cfg.fog_start_to_h)
				)
				fog_bad += int((from != to and not starts) or hours >= float(cfg.fog_end_h))
			rain_bad += int(t < float(cfg.no_rain_before_gmin) and to in cfg.rain_states)
		check_eq(
			[forbidden, grace_bad, fog_bad, rain_bad],
			[0, 0, 0, 0],
			"%s seed %d: forbidden, grace, fog, early rain" % [label, seed]
		)
		check(
			seen.size() == order.size(), "%s seed %d: every state occurs %s" % [label, seed, seen]
		)
	Rng.save_seed = saved_seed
	w.free()


func test_ten_thousand_changes_with_test_values() -> void:
	_simulate(_table(), "test values")


func test_ten_thousand_changes_on_the_content() -> void:
	var cfg := ContentDB.tuning("weather")
	if check(not cfg.is_empty(), "content has a weather group"):
		_simulate(cfg, "content")


func test_wetting_and_drying() -> void:
	# T-08-9: 20 game minutes of full rain make the ground wet; 120 game
	# minutes of sun with light cloud dry it.
	var start := 2.0 * GameClock.GMIN_PER_DAY + 12.0 * 60.0
	var base := {"next_change_gmin": start + 10000.0, "wind_dir_deg": 225.0, "wind_speed": 3.0}
	var wet: Dictionary = base.merged({"state": "wet", "ground_wetness": 0.0})
	check(_w.load_data(wet), "storm loaded")
	_w.update(start)
	_w.update(start + 20.0)
	check_near(_w.ground_wetness, 1.0, 1e-9, "wet after 20 game minutes")
	var sunny: Dictionary = base.merged({"state": "sun", "ground_wetness": 1.0})
	check(_w.load_data(sunny), "clear loaded")
	_w.update(start - 60.0)  # 11:00, the sun is up until long after 13:00
	_w.update(start + 59.0)
	check(_w.ground_wetness > 0.0, "not dry after 119 minutes")
	_w.update(start + 60.0)
	check_near(_w.ground_wetness, 0.0, 1e-9, "dry after 120 game minutes of sun")
	var night: Dictionary = base.merged({"state": "sun", "ground_wetness": 1.0})
	_w.load_data(night)
	_w.update(2.0 * GameClock.GMIN_PER_DAY)  # midnight
	_w.update(2.0 * GameClock.GMIN_PER_DAY + 120.0)
	check_near(_w.ground_wetness, 0.5, 1e-9, "half dry after 120 minutes at night")


func test_parameters_blend_after_a_change() -> void:
	_w.new_game(0.0)
	check_eq(_w.state, "sun", "grace state")
	_w.update(1080.0)
	check_eq(_w.state, "grey", "cloudy after the grace period")
	var half := _w.params(1085.0)
	check_near(float(half.cloud_cover), 0.35, 1e-9, "half way after 5 of 10 minutes")
	check_near(float(_w.params(1095.0).visibility_m), 6000.0, 1e-9, "fully blended")
	check_eq(half.state, "grey")


func test_wind_from_the_prevailing_side() -> void:
	_w.new_game(0.0)
	check(_w.wind_speed >= 2.0 and _w.wind_speed <= 6.0, "speed in the state's range")
	check(
		absf(angle_difference(deg_to_rad(_w.wind_dir_deg), deg_to_rad(225.0))) <= deg_to_rad(40.0),
		"within 40° of 225°"
	)
	var v := Weather.wind_vector({"wind_from_deg": 225.0, "wind_speed": 2.0})
	check(v.is_equal_approx(Vector2(sqrt(2.0), -sqrt(2.0))), "from the south-west blows north-east")


func test_save_round_trip() -> void:
	_w.new_game(500.0)
	_w.update(4000.0)
	var data := _w.save_data()
	var other := Weather.new()
	other.configure(_table(), _clock)
	check(other.load_data(data), "loads")
	check_eq(other.save_data(), data, "same values")
	check(not other.load_data({}), "missing values refused")
	var bad := data.duplicate()
	bad.state = "snow"
	check(not other.load_data(bad), "unknown state refused")
	other.free()


func test_push_drives_the_sky_and_force_switches() -> void:
	var dome := SkyDome.new()
	var lights := SkyLights.new()
	var wind := Wind.new()
	_w.sky_dome = dome
	_w.sky_lights = lights
	_w.wind = wind
	_w.new_game(0.0)
	_w.push(10.0)
	var p := _w.params(10.0)
	check_near(wind.base, float(p.wind_speed), 1e-9, "wind base speed")
	check_near(wind.gust, float(p.gustiness), 1e-9, "wind gustiness")
	check(wind.dir.is_normalized(), "wind direction is a unit vector")
	check(wind.dir.dot(dome.wind.normalized()) > 0.9999, "wind and sky blow the same way")
	check_near(dome.cloud_cover, 0.1, 1e-9, "cover")
	check_near(dome.visibility_m, 10000.0, 1e-9, "visibility")
	check(dome.mist_allowed, "mist allowed in the mist state")
	check(dome.wind.length() > 0.0 and dome.wind.x > 0.0, "wind toward the north-east side")
	check_near(lights.cloud_cover, 0.1, 1e-9, "lights cover")
	check(_w.force("wet", 20.0), "forced")
	check(not _w.force("snow", 20.0), "unknown refused")
	_w.push(40.0)
	check_eq(_w.state, "wet")
	check_near(dome.cloud_cover, 0.9, 1e-9, "blended in after 20 minutes")
	check(not dome.mist_allowed, "no mist outside the mist state")
	check_near(wind.base, float(_w.params(40.0).wind_speed), 1e-9, "wind follows the new state")
	check_eq(_w.state_ids(), ["sun", "grey", "wet", "mist"] as Array[String])
	wind.free()
	lights.free()
	dome.free()
