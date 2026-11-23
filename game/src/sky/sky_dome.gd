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
## The shaders' clock is measured again this often (game minutes), and
## after any frame longer than HITCH_S (a hitch moves TIME against the wall
## clock; between hitches the offset holds to a few milliseconds).
const MEASURE_EVERY_GMIN := 60
const HITCH_S := 0.2
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
	"glow",
]
## The glow band's azimuth and end are handed to the shader again only
## when they move by more than this (degrees).
const GLOW_STEP_DEG := 0.25
## Cloud noise textures: side in pixels and FastNoiseLite settings
## (frequency per pixel, octaves, seed).
const NOISE_SIDE := 512
const CUMULUS_NOISE := [0.008, 5, 11]
const CIRRUS_NOISE := [0.006, 4, 23]
## Metres per repeat of the cumulus noise, in the sky and in its shadow.
const CUMULUS_TILE_M := 2000.0

var errors: PackedStringArray = []
var material: ShaderMaterial
var sky: Sky
## Set by the weather: cloud cover 0..1 (also dims the stars), darkness of
## the cloud undersides 0..1, and the wind in m/s on the map plane (x east,
## y south) that the clouds drift with.
var cloud_cover := 0.0
var cloud_darkness := 0.0
var wind := Vector2.ZERO
## Set by the weather: visibility in metres (0 = no fog) and whether the
## dawn mist may form (clear weather).
var visibility_m := 0.0
var mist_allowed := true
## Volumetric fog on (desktop presets that ask for it, Forward+ only).
var volumetric := false
## The glow band (08 §2.6): the point it leads to (engine coordinates),
## whether one is known, and whether the story has ended (the band then
## stops at the target and brightens).
var glow_target := Vector3.ZERO
var has_glow_target := false
var story_ended := false
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
var _env := {}
var _glow := {}
var _glow_azimuth := -1000.0
var _glow_end := -1000.0


## Builds the sky for `clock`, coloured by the ramp of `lights`, with a
## radiance map of `radiance_size` pixels, and sets the environment from the
## "environment" tuning group `env_cfg` (tone mapping, glow, ambient floor)
## when given. False and `errors` when the size is not supported, the ramp
## is empty or a colour does not parse.
func setup(
	clock: GameClock, lights: SkyLights, radiance_size: int, env_cfg: Dictionary = {}
) -> bool:
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
	material.set_shader_parameter("cumulus_tile_m", CUMULUS_TILE_M)
	RenderingServer.global_shader_parameter_set("cloud_shadow_tex", cumulus_texture)
	RenderingServer.global_shader_parameter_set("cloud_shadow_tile_m", CUMULUS_TILE_M)
	RenderingServer.global_shader_parameter_set("cloud_time_rollover_s", rollover)
	_drift = Vector2.ZERO
	_drift_t0 = -1.0
	_setup_glow(lights.sky_config().get("glow", {}))
	if not env_cfg.is_empty():
		_setup_environment(env_cfg)
	_next.clear()
	_shown_gmin = -1
	_measure_time.call_deferred()
	return errors.is_empty()


func _process(delta: float) -> void:
	if _clock == null or not _clock.is_configured() or material == null:
		return
	if delta > HITCH_S:
		_measure_time.call_deferred()
	var g := int(_clock.now_gmin)
	if g != _shown_gmin:
		show_minute(g)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		follow_glow(cam.global_position)


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
	RenderingServer.global_shader_parameter_set("cloud_shadow_drift", _drift)
	RenderingServer.global_shader_parameter_set("cloud_shadow_wind", wind)
	RenderingServer.global_shader_parameter_set("cloud_shadow_t0", t0)
	RenderingServer.global_shader_parameter_set("cloud_shadow_cover", cloud_cover)
	material.set_shader_parameter("blend_s", _clock.gmin_real_s() / scale)
	material.set_shader_parameter("blend_t0", t0)
	environment.ambient_light_energy = float(now.ambient_energy)
	_apply_fog(now, _hours(gmin))
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
		"glow": glow_strength(e),
		"ambient_energy": r.ambient_energy,
	}


## Glow band strength at sun elevation `sun_deg`: 0 with the sun up, full
## at full_below_deg, dimmed by cloud cover, times ended_gain after the end.
func glow_strength(sun_deg: float) -> float:
	if _glow.is_empty():
		return 0.0
	var k := clampf(sun_deg / float(_glow.full_below_deg), 0.0, 1.0)
	k *= 1.0 - float(_glow.cloud_dim) * cloud_cover
	return k * (float(_glow.ended_gain) if story_ended else 1.0)


## Compass azimuth (degrees) of the band's bright end seen from `viewer`
## (engine coordinates): the bearing to the target, clamped to the tuning's
## range; the middle of the range without a target.
func glow_azimuth_deg(viewer: Vector3) -> float:
	var lo := float(_glow.get("azimuth_min_deg", 0.0))
	var hi := float(_glow.get("azimuth_max_deg", 0.0))
	if not has_glow_target:
		return (lo + hi) * 0.5
	var to := glow_target - viewer
	var bearing := rad_to_deg(atan2(to.x, -to.z))
	var mid := (lo + hi) * 0.5
	return clampf(mid + wrapf(bearing - mid, -180.0, 180.0), lo, hi)


## Hands the shader the band's azimuth and end for `viewer` when they moved
## by more than GLOW_STEP_DEG.
func follow_glow(viewer: Vector3) -> void:
	if _glow.is_empty() or material == null:
		return
	var az := glow_azimuth_deg(viewer)
	if absf(az - _glow_azimuth) > GLOW_STEP_DEG:
		_glow_azimuth = az
		material.set_shader_parameter("glow_azimuth", deg_to_rad(az))
	var end := 0.0
	if story_ended and has_glow_target:
		var to := glow_target - viewer
		end = rad_to_deg(atan2(to.y, Vector2(to.x, to.z).length()))
	if absf(end - _glow_end) > GLOW_STEP_DEG:
		_glow_end = end
		material.set_shader_parameter("glow_end_elev", deg_to_rad(maxf(end, 0.0)))


## Finds the band's target place in the world's pois.json.
func find_glow_target(world: WorldData) -> void:
	has_glow_target = false
	if _glow.is_empty() or not world.has_layer("pois.json"):
		return
	var doc: Variant = JSON.parse_string(world.read_text("pois.json"))
	if not doc is Dictionary:
		return
	for p: Dictionary in doc.get("pois", []):
		if p.id == _glow.target_poi:
			glow_target = world.map_to_world(Vector3(float(p.x), float(p.y), float(p.z)))
			has_glow_target = true


func _hours(gmin: float) -> float:
	return fmod(gmin, GameClock.GMIN_PER_DAY) / 60.0


## Exponential fog density for a visibility in metres (08 §4.4): `k` over
## the visibility, so `k` is the optical depth at that distance.
static func fog_density(visibility: float, k: float) -> float:
	return k / visibility if visibility > 0.0 else 0.0


## How much the fog covers the sky: 0 at clear_m and beyond, 1 at full_m
## and nearer, falling with the logarithm of the visibility between.
static func sky_affect(visibility: float, clear_m: float, full_m: float) -> float:
	if visibility <= 0.0:
		return 0.0
	var k := 1.0 - log(maxf(visibility, full_m) / full_m) / log(clear_m / full_m)
	return clampf(k, 0.0, 1.0) ** 2


## Dawn mist strength at clock `hours`: 1 between from_h and to_h, fading
## in and out over fade_h at both ends.
static func mist_factor(hours: float, from_h: float, to_h: float, fade_h: float) -> float:
	if hours < from_h - fade_h or hours > to_h + fade_h:
		return 0.0
	var f := 1.0
	if fade_h > 0.0:
		f = minf(clampf((hours - (from_h - fade_h)) / fade_h, 0.0, 1.0), f)
		f = minf(clampf((to_h + fade_h - hours) / fade_h, 0.0, 1.0), f)
	return f


## Depth fog from the visibility in the horizon colour, the sky covered by
## it as far as sky_affect says, the dawn mist as height fog below
## mist_top_y, and volumetric fog of the same density when on.
func _apply_fog(now: Dictionary, hours: float) -> void:
	if _env.is_empty():
		return
	var density := fog_density(visibility_m, float(_env.fog_k))
	var mist := 0.0
	if mist_allowed:
		mist = mist_factor(
			hours, float(_env.mist_from_h), float(_env.mist_to_h), float(_env.mist_fade_h)
		)
	environment.fog_enabled = density > 0.0
	environment.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	environment.fog_density = density
	environment.fog_light_color = now.horizon
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = 0.0
	environment.fog_aerial_perspective = 0.0
	environment.fog_sky_affect = sky_affect(
		visibility_m, float(_env.sky_fog_clear_m), float(_env.sky_fog_full_m)
	)
	environment.fog_height = float(_env.mist_top_y)
	environment.fog_height_density = density * float(_env.mist_mult) * mist
	environment.volumetric_fog_enabled = volumetric and density > 0.0
	environment.volumetric_fog_density = density
	environment.volumetric_fog_albedo = now.horizon


## Tone mapping AgX, exposure and white, glow, and the ambient floor
## (08 §2.2, §2.4).
func _setup_environment(cfg: Dictionary) -> void:
	_env = cfg
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = float(cfg.exposure)
	environment.tonemap_white = float(cfg.tonemap_white)
	environment.glow_enabled = true
	environment.glow_intensity = float(cfg.glow_intensity)
	environment.glow_hdr_threshold = float(cfg.glow_threshold)
	var c: Variant = cfg.ambient_floor_colour
	if c is String and Color.html_is_valid(c):
		var lin := Color.html(c).srgb_to_linear() * float(cfg.ambient_floor_energy)
		material.set_shader_parameter("ambient_floor", Vector3(lin.r, lin.g, lin.b))
	else:
		errors.append("ambient_floor_colour: '%s' is not a #RRGGBB colour" % [c])


func _setup_glow(cfg: Dictionary) -> void:
	_glow = cfg
	_glow_azimuth = -1000.0
	_glow_end = -1000.0
	if cfg.is_empty():
		return
	for key: String in ["centre_colour", "edge_colour"]:
		var c: Variant = cfg[key]
		if c is String and Color.html_is_valid(c):
			material.set_shader_parameter("glow_" + key.trim_suffix("_colour"), Color.html(c))
		else:
			errors.append("glow.%s: '%s' is not a #RRGGBB colour" % [key, c])
	# 08 §2.6 gives the width as the full width at half maximum.
	material.set_shader_parameter("glow_sigma", deg_to_rad(float(cfg.width_deg)) / 2.3548)
	material.set_shader_parameter(
		"glow_scroll", Vector2(float(cfg.scroll_rad_s[0]), float(cfg.scroll_rad_s[1]))
	)
	material.set_shader_parameter("glow_intensity", float(cfg.intensity))
	material.set_shader_parameter("glow_end_gain", float(cfg.target_end_gain))


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
