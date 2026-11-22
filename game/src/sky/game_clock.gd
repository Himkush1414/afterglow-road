class_name GameClock
extends Node
## Owns game time (03 §8): `now_gmin` = game minutes since day 1, 00:00.
## Real time advances it by `time_scale` / `gmin_real_s` game minutes per
## second unless `paused`. The day phase follows the sun's elevation.
## All numbers come from the "clock" tuning group (checked by ContentDB
## against schema.json) through `configure`.

signal phase_changed(phase: Phase)
signal hour_changed(hour: int)

enum Phase { NIGHT, DAWN, GOLDEN, DAY, DUSK }

const GMIN_PER_DAY := 1440.0
## Members only this class writes (checked by test_core_state_owners).
const STATE: Array[StringName] = [&"now_gmin", &"phase", &"hour"]

var now_gmin := 0.0
var time_scale := 1.0:
	set(value):
		time_scale = maxf(value, 0.0)
var paused := false
var phase := Phase.NIGHT
var hour := 0
var _cfg := {}


func _process(delta: float) -> void:
	advance(delta)


## Takes the "clock" tuning group, as ContentDB has checked it.
func configure(cfg: Dictionary) -> void:
	_cfg = cfg
	_sync()


func is_configured() -> bool:
	return not _cfg.is_empty()


## Starts a new game's clock.
func new_game() -> void:
	set_now(float(_cfg.start_gmin))


## Jumps to `gmin`; hour and phase signals fire once if they change.
func set_now(gmin: float) -> void:
	now_gmin = maxf(gmin, 0.0)
	_sync()


## Advances by `real_seconds`. Hours and phases crossed on the way are
## announced in order, at game-minute resolution.
func advance(real_seconds: float) -> void:
	if paused or not is_configured() or real_seconds <= 0.0:
		return
	var remaining := real_seconds * time_scale / float(_cfg.gmin_real_s)
	while remaining > 0.0:
		var step := minf(remaining, 1.0)
		now_gmin += step
		remaining -= step
		_sync()


## Day number, starting at 1.
func day() -> int:
	return int(now_gmin / GMIN_PER_DAY) + 1


## Clock time of the current day in hours, 0 to 24.
func clock_hours() -> float:
	return fmod(now_gmin, GMIN_PER_DAY) / 60.0


func minute() -> int:
	return int(fmod(now_gmin, 60.0))


## Sun elevation in degrees at clock time `hours` (08 §1.2).
func sun_elevation_deg(hours: float) -> float:
	return _elevation(_sun_hour_angle(hours), float(_cfg.sun_declination_deg))


## Sun azimuth in degrees from north, clockwise, at clock time `hours`.
func sun_azimuth_deg(hours: float) -> float:
	return _azimuth(_sun_hour_angle(hours), float(_cfg.sun_declination_deg))


## Moon phase at `gmin` game minutes: 0 new, 0.5 full, repeating every
## moon_cycle_days game days.
func moon_phase(gmin: float) -> float:
	var days := gmin / GMIN_PER_DAY
	return fposmod(float(_cfg.moon_phase_at_start) + days / float(_cfg.moon_cycle_days), 1.0)


## Moon elevation in degrees at clock time `hours` and phase `p`.
func moon_elevation_deg(hours: float, p: float) -> float:
	return _elevation(_sun_hour_angle(hours) - 360.0 * p, float(_cfg.moon_declination_deg))


## Moon azimuth in degrees from north, clockwise.
func moon_azimuth_deg(hours: float, p: float) -> float:
	return _azimuth(_sun_hour_angle(hours) - 360.0 * p, float(_cfg.moon_declination_deg))


## Lit fraction of the moon's disc at phase `p`.
static func moon_illumination(p: float) -> float:
	return 0.5 * (1.0 - cos(TAU * p))


func _sun_hour_angle(hours: float) -> float:
	return 15.0 * (hours - float(_cfg.solar_noon_h))


func _elevation(hour_angle_deg: float, dec_deg: float) -> float:
	var lat := deg_to_rad(float(_cfg.latitude_deg))
	var dec := deg_to_rad(dec_deg)
	var h := deg_to_rad(hour_angle_deg)
	return rad_to_deg(asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(h)))


func _azimuth(hour_angle_deg: float, dec_deg: float) -> float:
	var lat := deg_to_rad(float(_cfg.latitude_deg))
	var dec := deg_to_rad(dec_deg)
	var h := deg_to_rad(hour_angle_deg)
	var a := rad_to_deg(atan2(sin(h), cos(h) * sin(lat) - tan(dec) * cos(lat)))
	return fposmod(180.0 + a, 360.0)


## Day phase at clock time `hours`.
func phase_at(hours: float) -> Phase:
	var e := sun_elevation_deg(hours)
	if e < float(_cfg.night_below_deg):
		return Phase.NIGHT
	if e < float(_cfg.golden_from_deg):
		return Phase.DAWN if hours < float(_cfg.solar_noon_h) else Phase.DUSK
	if e < float(_cfg.day_from_deg):
		return Phase.GOLDEN
	return Phase.DAY


func save_data() -> Dictionary:
	return {"now_gmin": now_gmin}


## Restores from `save_data()`; false when the value is missing or invalid.
func load_data(data: Dictionary) -> bool:
	var value: Variant = data.get("now_gmin")
	if not (value is float or value is int) or float(value) < 0.0:
		Log.error("clock", "invalid clock.now_gmin in save")
		return false
	set_now(float(value))
	return true


func _sync() -> void:
	var h := int(clock_hours())
	if h != hour:
		hour = h
		hour_changed.emit(h)
	var p := phase_at(clock_hours())
	if p != phase:
		phase = p
		phase_changed.emit(p)
