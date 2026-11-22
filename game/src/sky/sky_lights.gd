class_name SkyLights
extends Node3D
## The sun and the moon as two directional lights (08 §2.2, §2.3). Their
## directions follow the clock; colour and energy come from the sky ramp
## and the moon's phase. Only one casts shadows: the sun while its
## elevation is above sun_shadow_above_deg, else the moon. Updated once per
## game minute from the clock given to `setup`.

var errors: PackedStringArray = []
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var ramp := SkyRamp.new()
## Cloud cover 0..1, set by the weather.
var cloud_cover := 0.0:
	set(value):
		cloud_cover = clampf(value, 0.0, 1.0)
		_applied_gmin = -1

var _clock: GameClock
var _cfg := {}
var _moon_colour := Color.WHITE
var _applied_gmin := -1


func _init() -> void:
	sun = _light("Sun")
	moon = _light("Moon")


## Takes the clock to follow and the "sky" tuning group. False and `errors`
## when the group is missing or its ramp is invalid.
func setup(clock: GameClock, cfg: Dictionary) -> bool:
	_clock = clock
	_cfg = cfg
	errors.clear()
	if cfg.is_empty():
		errors.append("no sky tuning group")
		return false
	if not ramp.setup(cfg.ramp):
		errors.append_array(ramp.errors)
	var c: Variant = cfg.moon_colour
	if c is String and Color.html_is_valid(c):
		_moon_colour = Color.html(c)
	else:
		errors.append("moon_colour: '%s' is not a #RRGGBB colour" % [c])
	_applied_gmin = -1
	return errors.is_empty()


func _process(_delta: float) -> void:
	if _clock == null or not _clock.is_configured() or not errors.is_empty() or _cfg.is_empty():
		return
	var g := int(_clock.now_gmin)
	if g != _applied_gmin:
		apply(float(g))


## Sets both lights for `gmin` game minutes since day 1, 00:00.
func apply(gmin: float) -> void:
	_applied_gmin = int(gmin)
	var hours := fmod(gmin, GameClock.GMIN_PER_DAY) / 60.0
	var sun_e := _clock.sun_elevation_deg(hours)
	var r := ramp.at(sun_e)
	_aim(sun, sun_e, _clock.sun_azimuth_deg(hours))
	sun.light_color = r.sun_colour
	sun.light_energy = float(r.sun_energy) * (1.0 - float(_cfg.overcast_sun_dim) * cloud_cover)
	var p := _clock.moon_phase(gmin)
	var moon_e := _clock.moon_elevation_deg(hours, p)
	_aim(moon, moon_e, _clock.moon_azimuth_deg(hours, p))
	moon.light_color = _moon_colour
	var lit := (
		float(_cfg.moon_energy_base)
		+ float(_cfg.moon_energy_illum) * GameClock.moon_illumination(p)
	)
	moon.light_energy = (
		lit * (1.0 - float(_cfg.moon_cloud_dim) * cloud_cover) if moon_e > 0.0 else 0.0
	)
	var sun_shadows := sun_e > float(_cfg.sun_shadow_above_deg)
	sun.shadow_enabled = sun_shadows
	moon.shadow_enabled = not sun_shadows


## The "sky" tuning group given to `setup`.
func sky_config() -> Dictionary:
	return _cfg


## Unit vector toward a body at `elev_deg` above the horizon and `az_deg`
## from north, clockwise; north is −Z and east is +X.
static func direction(elev_deg: float, az_deg: float) -> Vector3:
	var e := deg_to_rad(elev_deg)
	var a := deg_to_rad(az_deg)
	return Vector3(sin(a) * cos(e), sin(e), -cos(a) * cos(e))


func _aim(light: DirectionalLight3D, elev_deg: float, az_deg: float) -> void:
	var toward := direction(elev_deg, az_deg)
	var up := Vector3.UP if absf(toward.y) < 0.999 else Vector3.FORWARD
	# A directional light shines along its −Z axis, away from the body.
	light.basis = Basis.looking_at(-toward, up)


func _light(light_name: String) -> DirectionalLight3D:
	var light := DirectionalLight3D.new()
	light.name = light_name
	light.shadow_enabled = false
	add_child(light)
	return light
