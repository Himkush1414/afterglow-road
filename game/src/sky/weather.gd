class_name Weather
extends Node
## The weather state machine (08 §4): one state for the whole map, rolled
## every roll_every_gmin game minutes from a per-save stream, with the fog
## window, the grace period and the no-rain start; parameters blend over
## blend_gmin after a change; each change picks a new wind; ground wetness
## grows with rain and dries in sun or shade. All numbers come from the
## "weather" tuning group. `update` applies every change that fell due, in
## order, so sleeping through weather works.

var errors: PackedStringArray = []
## What the weather drives, once per game minute (each may be null).
var sky_dome: SkyDome
var sky_lights: SkyLights
var terrain: Terrain
var wind: Wind
var state := ""
var next_change_gmin := 0.0
## Direction the wind blows from (compass degrees) and its base speed (m/s).
var wind_dir_deg := 0.0
var wind_speed := 0.0
var ground_wetness := 0.0

var _cfg := {}
var _clock: GameClock
var _states := {}
var _order: Array[String] = []
var _rows := {}
var _prev_state := ""
var _prev_wind_dir := 0.0
var _prev_wind_speed := 0.0
var _blend_from := -INF
var _last_gmin := -1.0
var _pushed_gmin := -1


## Takes the "weather" tuning group and the clock (sun height for drying).
## False and `errors` when the table does not hold together.
func configure(cfg: Dictionary, clock: GameClock) -> bool:
	errors.clear()
	_cfg = cfg
	_clock = clock
	_states.clear()
	_order.clear()
	_rows.clear()
	for s: Dictionary in cfg.get("states", []):
		if _states.has(s.id):
			errors.append("weather: state %s twice" % s.id)
		_states[s.id] = s
		_order.append(s.id)
	for row: Dictionary in cfg.get("transitions", []):
		var p: Array = row.p
		if not _states.has(row.from):
			errors.append("weather: transitions from unknown state %s" % row.from)
		elif p.size() != _order.size():
			errors.append(
				"weather: row %s has %d values for %d states" % [row.from, p.size(), _order.size()]
			)
		elif absf(p.reduce(func(a: float, b: float) -> float: return a + b, 0.0) - 1.0) > 1e-6:
			errors.append("weather: row %s does not sum to 1" % row.from)
		_rows[row.from] = p
	for id: String in _order:
		if not _rows.has(id):
			errors.append("weather: no transitions from %s" % id)
	var named: Array = [
		cfg.get("fog_state"),
		cfg.get("fallback_state"),
		cfg.get("grace_state"),
		cfg.get("grace_then_state"),
		cfg.get("no_rain_state"),
		cfg.get("mist_state")
	]
	named.append_array(cfg.get("rain_states", []))
	for id: Variant in named:
		if not _states.has(id):
			errors.append("weather: unknown state %s" % [id])
	return errors.is_empty()


func is_configured() -> bool:
	return not _cfg.is_empty() and errors.is_empty()


## Starts a new game's weather at `gmin`: the grace state, dry ground.
func new_game(gmin: float) -> void:
	state = _cfg.grace_state
	_prev_state = state
	_blend_from = -INF
	var roll := float(_cfg.roll_every_gmin)
	next_change_gmin = (floorf(gmin / roll) + 1.0) * roll
	var rng := _stream(floorf(gmin / roll) * roll)
	_pick_wind(rng)
	_prev_wind_dir = wind_dir_deg
	_prev_wind_speed = wind_speed
	ground_wetness = 0.0
	_last_gmin = gmin


## Applies every change due up to `gmin` in order and integrates the
## ground wetness.
func update(gmin: float) -> void:
	if not is_configured():
		return
	if _last_gmin < 0.0:
		_last_gmin = gmin
	while next_change_gmin <= gmin:
		_wet(_last_gmin, next_change_gmin)
		_last_gmin = next_change_gmin
		_change_at(next_change_gmin)
		next_change_gmin += float(_cfg.roll_every_gmin)
	if gmin > _last_gmin:
		_wet(_last_gmin, gmin)
		_last_gmin = gmin


func _process(_delta: float) -> void:
	if _clock == null or not is_configured() or not _clock.is_configured() or state == "":
		return
	update(_clock.now_gmin)
	var g := int(_clock.now_gmin)
	if g != _pushed_gmin:
		push(float(g))


## Hands the blended parameters at `gmin` to the sky, the lights, the wind
## and the terrain: cloud cover and darkness, visibility, dawn mist allowed
## in the mist state, wind direction, speed and gustiness, ground wetness.
func push(gmin: float) -> void:
	_pushed_gmin = int(gmin)
	var p := params(gmin)
	if sky_dome != null:
		sky_dome.cloud_cover = float(p.cloud_cover)
		sky_dome.cloud_darkness = float(p.cloud_darkness)
		sky_dome.visibility_m = float(p.visibility_m)
		sky_dome.mist_allowed = state == _cfg.mist_state
		sky_dome.wind = wind_vector(p)
	if sky_lights != null:
		sky_lights.cloud_cover = float(p.cloud_cover)
	if wind != null:
		wind.set_from_weather(p)
	if terrain != null and terrain.is_ready():
		terrain.set_wetness(ground_wetness)


## Switches to state `id` at `gmin` now (debug console), blending as for a
## rolled change; the next roll stays where it was. False for an unknown id.
func force(id: String, gmin: float) -> bool:
	if not _states.has(id):
		return false
	update(gmin)
	_prev_state = state
	_prev_wind_dir = wind_dir_deg
	_prev_wind_speed = wind_speed
	_blend_from = gmin
	state = id
	_pick_wind(_stream(gmin))
	_pushed_gmin = -1
	return true


func state_ids() -> Array[String]:
	return _order.duplicate()


## The state rolled at change time `t` coming from state `from`, with the
## fog window, the no-rain start and the grace period applied.
func roll_target(t: float, from: String) -> String:
	var rng := _stream(t)
	return _target(t, from, rng.randf())


## Blended parameters at `gmin`: every number of the state table plus the
## wind, the current state id and whether lightning is on.
func params(gmin: float) -> Dictionary:
	var blend := float(_cfg.blend_gmin)
	var w := 1.0 if blend <= 0.0 else clampf((gmin - _blend_from) / blend, 0.0, 1.0)
	var a: Dictionary = _states[_prev_state]
	var b: Dictionary = _states[state]
	var out := {"state": state, "lightning": bool(b.lightning)}
	for key: String in [
		"cloud_cover",
		"cloud_darkness",
		"rain",
		"gustiness",
		"temp_day_c",
		"temp_night_c",
		"visibility_m"
	]:
		out[key] = lerpf(float(a[key]), float(b[key]), w)
	out.wind_speed = lerpf(_prev_wind_speed, wind_speed, w)
	out.wind_from_deg = fposmod(
		rad_to_deg(lerp_angle(deg_to_rad(_prev_wind_dir), deg_to_rad(wind_dir_deg), w)), 360.0
	)
	return out


## Wind on the map plane in m/s (x east, y south) from blended parameters.
static func wind_vector(p: Dictionary) -> Vector2:
	var toward := deg_to_rad(float(p.wind_from_deg) + 180.0)
	return Vector2(sin(toward), -cos(toward)) * float(p.wind_speed)


func save_data() -> Dictionary:
	return {
		"state": state,
		"next_change_gmin": next_change_gmin,
		"wind_dir_deg": wind_dir_deg,
		"wind_speed": wind_speed,
		"ground_wetness": ground_wetness,
	}


## Restores from `save_data()`; false when a value is missing or invalid.
func load_data(data: Dictionary) -> bool:
	var s: Variant = data.get("state")
	var keys: Array[String] = ["next_change_gmin", "wind_dir_deg", "wind_speed", "ground_wetness"]
	for key in keys:
		var v: Variant = data.get(key)
		if not (v is float or v is int):
			Log.error("weather", "invalid weather.%s in save" % key)
			return false
	if not s is String or not _states.has(s):
		Log.error("weather", "invalid weather.state in save")
		return false
	state = s
	_prev_state = state
	_blend_from = -INF
	next_change_gmin = float(data.next_change_gmin)
	wind_dir_deg = float(data.wind_dir_deg)
	wind_speed = float(data.wind_speed)
	_prev_wind_dir = wind_dir_deg
	_prev_wind_speed = wind_speed
	ground_wetness = clampf(float(data.ground_wetness), 0.0, 1.0)
	_last_gmin = -1.0
	return true


func _change_at(t: float) -> void:
	var rng := _stream(t)
	var to := _target(t, state, rng.randf())
	_prev_state = state
	_prev_wind_dir = wind_dir_deg
	_prev_wind_speed = wind_speed
	_blend_from = t
	state = to
	_pick_wind(rng)


func _target(t: float, from: String, roll: float) -> String:
	var row: Array = _rows[from]
	var to: String = _order[-1]
	var acc := 0.0
	for i in _order.size():
		acc += float(row[i])
		if roll < acc:
			to = _order[i]
			break
	var hours := fmod(t, GameClock.GMIN_PER_DAY) / 60.0
	var fog: String = _cfg.fog_state
	var starts := hours >= float(_cfg.fog_start_from_h) and hours < float(_cfg.fog_start_to_h)
	if to == fog and ((from != fog and not starts) or hours >= float(_cfg.fog_end_h)):
		to = _cfg.fallback_state
	if t < float(_cfg.no_rain_before_gmin) and to in _cfg.rain_states:
		to = _cfg.no_rain_state
	if to != from and _p(from, to) == 0.0 and _p(from, from) > 0.0:
		to = from
	var grace := float(_cfg.grace_until_gmin)
	if t < grace:
		to = _cfg.grace_state
	elif t < grace + float(_cfg.roll_every_gmin):
		to = _cfg.grace_then_state
	return to


func _p(from: String, to: String) -> float:
	return float(_rows[from][_order.find(to)])


## The stream of the change at `t`: key = day × changes per day + slot.
func _stream(t: float) -> RandomNumberGenerator:
	var per_day := int(GameClock.GMIN_PER_DAY / float(_cfg.roll_every_gmin))
	var day := int(t / GameClock.GMIN_PER_DAY) + 1
	var slot := int(fmod(t, GameClock.GMIN_PER_DAY) / float(_cfg.roll_every_gmin))
	return Rng.for_save_key(day * per_day + slot)


func _pick_wind(rng: RandomNumberGenerator) -> void:
	var s: Dictionary = _states[state]
	wind_speed = lerpf(float(s.wind_min_ms), float(s.wind_max_ms), rng.randf())
	var turn := float(_cfg.turn_deg) * (rng.randf() * 2.0 - 1.0)
	wind_dir_deg = fposmod(float(_cfg.prevailing_from_deg) + turn, 360.0)


## Ground wetness from `a` to `b` game minutes in one-minute steps: rain
## wets it (full after wet_full_gmin at rain 1); without rain it dries in
## dry_sun_gmin with the sun up under light cloud, else in dry_shade_gmin.
func _wet(a: float, b: float) -> void:
	var no_rain := float(_states[state].rain) <= 0.0 and float(_states[_prev_state].rain) <= 0.0
	if no_rain and ground_wetness <= 0.0:
		return  # dry ground stays dry
	var t := a
	while t < b:
		var step := minf(1.0, b - t)
		var p := params(t + step * 0.5)
		var rain := float(p.rain)
		if rain > 0.0:
			ground_wetness += step * rain / float(_cfg.wet_full_gmin)
		else:
			var hours := fmod(t, GameClock.GMIN_PER_DAY) / 60.0
			var sun := _clock != null and _clock.sun_elevation_deg(hours) > 0.0
			sun = sun and float(p.cloud_cover) <= float(_cfg.sun_max_cover)
			ground_wetness -= step / float(_cfg.dry_sun_gmin if sun else _cfg.dry_shade_gmin)
		ground_wetness = clampf(ground_wetness, 0.0, 1.0)
		t += step
