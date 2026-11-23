extends TestCase
## Lightning: strikes only while active, at intervals and distances inside
## their ranges; the flash in pulses; thunder after distance / sound speed;
## the flash light and the bolt point at the strike's azimuth.

const CFG := {
	"seed_key": 1,
	"interval_min_s": 20.0,
	"interval_max_s": 60.0,
	"flash_energy": 6.0,
	"flash_s": 0.15,
	"pulses": 2,
	"distance_min_m": 500.0,
	"distance_max_m": 4000.0,
	"sound_ms": 340.0,
	"flash_elevation_deg": 20.0,
	"bolt_draw_m": 1000.0,
	"bolt_top_deg": 20.0,
	"bolt_width_deg": 4.0,
}
const DT := 1.0 / 60.0

var _l: Lightning
var _strikes: Array[Vector3] = []  # time, azimuth, distance
var _thunders: Array[Vector2] = []  # time, distance


func before_each() -> void:
	_l = Lightning.new()
	check(_l.configure(CFG), "configure: %s" % [_l.errors])
	_l.rng.seed = 99
	_strikes.clear()
	_thunders.clear()
	_l.flashed.connect(
		func(az: float, d: float) -> void: _strikes.append(Vector3(_l.time_s, az, d))
	)
	_l.thunder.connect(func(d: float) -> void: _thunders.append(Vector2(_l.time_s, d)))


func after_each() -> void:
	_l.free()


func test_the_flash_has_two_pulses() -> void:
	var want := [[0.0, 6.0], [0.04, 6.0], [0.06, 0.0], [0.09, 0.0], [0.11, 6.0], [0.149, 6.0]]
	for row: Array in want:
		check_eq(_l.flash_energy(row[0]), row[1], "at %.3f s" % row[0])
	check_eq(_l.flash_energy(0.15), 0.0, "over after flash_s")
	check_eq(_l.flash_energy(-0.01), 0.0, "not before")


func test_no_strikes_while_inactive() -> void:
	_run(600.0)
	check_eq(_strikes.size(), 0, "calm")
	_l.set_from_weather({"lightning": true})
	check(_l.active, "on with the storm")
	check(_l.next_strike_s >= _l.time_s + 20.0 - 1e-9, "first strike after the minimum interval")
	_l.set_from_weather({"lightning": false})
	_run(600.0)
	check_eq(_strikes.size(), 0, "off again")


func test_intervals_distances_and_thunder_timing() -> void:
	_l.set_active(true)
	_run(6000.0)
	check(_strikes.size() >= 100 and _strikes.size() <= 300, "strikes: %d" % _strikes.size())
	var prev := 0.0
	for s in _strikes:
		var gap := s.x - prev
		if prev > 0.0:
			check(gap >= 20.0 - DT and gap <= 60.0 + DT, "gap %.2f s" % gap)
		prev = s.x
		check(s.y >= 0.0 and s.y < 360.0, "azimuth %.1f" % s.y)
		check(s.z >= 500.0 and s.z <= 4000.0, "distance %.0f" % s.z)
	check(_thunders.size() >= _strikes.size() - 1, "thunder follows each strike")
	for i in _thunders.size():
		var delay := _thunders[i].x - _strikes[i].x
		check_near(delay, _strikes[i].z / 340.0, DT * 1.01, "thunder delay %d" % i)
		check_eq(_thunders[i].y, _strikes[i].z)


func test_light_and_bolt_follow_the_strike() -> void:
	_l.strike(90.0, 1700.0)  # from the east
	check(_l.light.visible and _l.bolt.visible, "shown during the flash")
	check_near(_l.light.light_energy, 6.0, 1e-9, "energy")
	var to := _l.toward_flash()
	check(to.x > 0.9 and absf(to.z) < 1e-6, "toward the east: %s" % to)
	check_near(rad_to_deg(asin(to.y)), 20.0, 1e-4, "elevation")
	var shines := -_l.light.global_transform.basis.z if _l.is_inside_tree() else -_l.light.basis.z
	check(shines.dot(-to) > 0.9999, "light travels from the flash")
	var b := _l.bolt.transform
	check_near(b.origin.x, 1000.0, 1e-3, "bolt drawn 1,000 m toward the azimuth")
	check_near(b.origin.y, 1000.0 * tan(deg_to_rad(20.0)) * 0.5, 1e-3, "base on the horizon")
	_l.advance(0.2)
	check(not _l.light.visible and not _l.bolt.visible, "hidden after the flash")
	check_eq(_l.pending_thunder(), 1, "thunder on its way")
	_l.advance(5.0)
	check_eq(_thunders.size(), 1, "thunder after 5 s")


func test_bad_ranges_refused() -> void:
	var cfg := CFG.duplicate()
	cfg.interval_min_s = 70.0
	cfg.distance_min_m = 5000.0
	var bad := Lightning.new()
	check(not bad.configure(cfg), "refused")
	check_eq(bad.errors.size(), 2)
	bad.free()


func _run(seconds: float) -> void:
	for i in int(seconds / DT):
		_l.advance(DT)
