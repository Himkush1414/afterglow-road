class_name SkyDome
extends WorldEnvironment
## The sky background (08 §2.2): sky.gdshader on a Sky with incremental
## radiance. Once per game minute it computes the sky values for that minute
## and hands the shader the last two sets (prev_/next_) and the moment of the
## change on the shaders' clock (ShaderClock), so the shader blends them
## over the minute's real length without any per-frame parameter change.

const SHADER := "res://shaders/sky.gdshader"
## Supported radiance sizes, in Sky.RadianceSize order.
const RADIANCE_SIZES: Array[int] = [32, 64, 128, 256, 512, 1024, 2048]
## Sun elevations (degrees) where the stars start and finish fading in.
const STARS_FROM_DEG := -6.0
const STARS_FULL_DEG := -12.0
## The shaders' clock is measured again this often (game minutes).
const MEASURE_EVERY_GMIN := 60
## Values blended by the shader, without their prev_/next_ prefix.
const KEYS: Array[String] = [
	"zenith",
	"horizon",
	"horizon_sun",
	"sun_colour",
	"sun_dir",
	"moon_dir",
	"stars",
	"star_angle",
	"cloud_cover",
	"cloud_darkness",
]
## Cloud noise textures: side in pixels and FastNoiseLite settings
## (frequency per pixel, octaves, seed).
const NOISE_SIDE := 512
const CUMULUS_NOISE := [0.008, 5, 11]
const CIRRUS_NOISE := [0.006, 4, 23]

var errors: PackedStringArray = []
var material: ShaderMaterial
var sky: Sky
## Set by the weather: cloud cover 0..1 (also dims the stars), darkness of
## the cloud undersides 0..1, and the wind in m/s on the map plane (x east,
## y south) that the clouds drift with.
var cloud_cover := 0.0
var cloud_darkness := 0.0
var wind := Vector2.ZERO
## Tiling noise of the two cloud layers.
var cumulus_texture: NoiseTexture2D
var cirrus_texture: NoiseTexture2D
## Parameter updates so far (one per game minute shown).
var updates := 0

var _clock: GameClock
var _ramp: SkyRamp
var _next := {}
var _shown_gmin := -1
## Cloud drift (metres) at the shaders' time _drift_t0, continued since
## with _drift_wind.
var _drift := Vector2.ZERO
var _drift_t0 := -1.0
var _drift_wind := Vector2.ZERO


## Builds the sky for `clock`, coloured by the ramp of `lights`, with a
## radiance map of `radiance_size` pixels. False and `errors` when the size
## is not supported or the ramp is empty.
func setup(clock: GameClock, lights: SkyLights, radiance_size: int) -> bool:
	errors.clear()
	_clock = clock
	_ramp = lights.ramp
	if _ramp.rows.is_empty():
		errors.append("sky ramp is empty")
	var size_index := RADIANCE_SIZES.find(radiance_size)
	if size_index < 0:
		errors.append("radiance size %d is not one of %s" % [radiance_size, RADIANCE_SIZES])
		size_index = RADIANCE_SIZES.find(128)
	material = ShaderMaterial.new()
	material.shader = load(SHADER)
	sky = Sky.new()
	sky.sky_material = material
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = size_index as Sky.RadianceSize
	if environment == null:
		environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	var rollover: float = ProjectSettings.get_setting(
		"rendering/limits/time/time_rollover_secs", 3600.0
	)
	material.set_shader_parameter("time_rollover_s", rollover)
	cumulus_texture = noise_texture(CUMULUS_NOISE)
	cirrus_texture = noise_texture(CIRRUS_NOISE)
	material.set_shader_parameter("cumulus_tex", cumulus_texture)
	material.set_shader_parameter("cirrus_tex", cirrus_texture)
	_drift = Vector2.ZERO
	_drift_t0 = -1.0
	_next.clear()
	_shown_gmin = -1
	_measure_time.call_deferred()
	return errors.is_empty()


func _process(_delta: float) -> void:
	if _clock == null or not _clock.is_configured() or material == null:
		return
	var g := int(_clock.now_gmin)
	if g != _shown_gmin:
		show_minute(g)


## Hands the shader the values of game minute `gmin`, blending from the
## values shown before.
func show_minute(gmin: int) -> void:
	_shown_gmin = gmin
	var now := values_at(float(gmin))
	material.set_shader_parameter("pole", pole(_clock.latitude_deg()))
	for key in KEYS:
		material.set_shader_parameter("prev_" + key, _next.get(key, now[key]))
		material.set_shader_parameter("next_" + key, now[key])
	_next = now
	var scale := maxf(_clock.time_scale, 1e-3)
	var t0 := ShaderClock.now()
	_advance_drift(t0)
	material.set_shader_parameter("cloud_offset", _drift)
	material.set_shader_parameter("cloud_wind", wind)
	material.set_shader_parameter("blend_s", _clock.gmin_real_s() / scale)
	material.set_shader_parameter("blend_t0", t0)
	updates += 1
	if gmin % MEASURE_EVERY_GMIN == 0:
		_measure_time.call_deferred()


## Sky values at `gmin` game minutes since day 1, 00:00.
func values_at(gmin: float) -> Dictionary:
	var hours := fmod(gmin, GameClock.GMIN_PER_DAY) / 60.0
	var e := _clock.sun_elevation_deg(hours)
	var r := _ramp.at(e)
	var p := _clock.moon_phase(gmin)
	var fade := clampf((STARS_FROM_DEG - e) / (STARS_FROM_DEG - STARS_FULL_DEG), 0.0, 1.0)
	return {
		"zenith": r.zenith,
		"horizon": r.horizon,
		"horizon_sun": r.horizon_sun,
		"sun_colour": r.sun_colour,
		"sun_dir": SkyLights.direction(e, _clock.sun_azimuth_deg(hours)),
		"moon_dir":
		SkyLights.direction(_clock.moon_elevation_deg(hours, p), _clock.moon_azimuth_deg(hours, p)),
		"stars": fade * (1.0 - cloud_cover),
		"star_angle": star_angle(gmin),
		"cloud_cover": cloud_cover,
		"cloud_darkness": cloud_darkness,
	}


## Cloud drift in metres at the shaders' time `t`: the drift handed to the
## shader last, moved on by the wind it was handed with.
func drift_at(t: float) -> Vector2:
	if _drift_t0 < 0.0:
		return _drift
	var rollover := ShaderClock.rollover_s()
	var dt := fposmod(t - _drift_t0, rollover)
	if dt > rollover * 0.5:
		dt = 0.0
	return _drift + _drift_wind * dt


func _advance_drift(t: float) -> void:
	_drift = drift_at(t)
	_drift_t0 = t
	_drift_wind = wind


## A seamless 512² noise texture from [frequency, octaves, seed].
static func noise_texture(spec: Array) -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = float(spec[0])
	noise.fractal_octaves = int(spec[1])
	noise.seed = int(spec[2])
	var tex := NoiseTexture2D.new()
	tex.width = NOISE_SIDE
	tex.height = NOISE_SIDE
	tex.seamless = true
	tex.generate_mipmaps = true
	tex.noise = noise
	return tex


func _measure_time() -> void:
	if is_inside_tree():
		await ShaderClock.measure(self)


## Unit vector to the celestial pole: due north, as high as the latitude.
static func pole(latitude_deg: float) -> Vector3:
	return SkyLights.direction(latitude_deg, 0.0)


## Turn of the star sphere about the pole after `gmin` game minutes, in
## radians: 15° per hour, westward. A star-space direction s is seen at
## s.rotated(pole, star_angle); the shader applies the inverse.
static func star_angle(gmin: float) -> float:
	return -fmod(deg_to_rad(15.0 * gmin / 60.0), TAU * 1000.0)
