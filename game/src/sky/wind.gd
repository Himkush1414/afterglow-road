class_name Wind
extends Node3D
## The wind (08 §5): direction (where it blows to), base speed and
## gustiness from the weather; a gust field from a tiling noise image
## scrolled downwind, the same on the CPU (`speed_at`) and in shaders
## (shaders/common/wind.gdshaderinc); exposure of a point from the biome's
## shelter factor and rays toward upwind that hit wind blockers. Shader
## globals are set every frame. All numbers come from the "wind" tuning.

var errors: PackedStringArray = []
## Unit vector on the map plane (x east, y south) the wind blows toward.
var dir := Vector2(1.0, 0.0)
var base := 0.0
var gust := 0.0
## Gust field offset in metres (accumulated downwind, wrapped at the tile).
var scroll := Vector2.ZERO
var time_s := 0.0
## Biome id at an engine position; defaults to the world's biome map.
var biome_of: Callable
var world: WorldData
var noise: Image
var noise_texture: ImageTexture

var _cfg := {}


## Takes the "wind" tuning group: builds the noise and sets the fixed
## shader globals. False and `errors` when the ray lists do not match.
func configure(cfg: Dictionary) -> bool:
	errors.clear()
	_cfg = cfg
	if (cfg.ray_lengths_m as Array).size() != (cfg.ray_weights as Array).size():
		errors.append("wind: ray_lengths_m and ray_weights differ in length")
	var fn := FastNoiseLite.new()
	fn.noise_type = FastNoiseLite.TYPE_PERLIN
	fn.fractal_type = FastNoiseLite.FRACTAL_FBM
	fn.fractal_octaves = 3
	fn.seed = int(cfg.noise_seed)
	fn.frequency = float(cfg.noise_frequency)
	var side := int(cfg.noise_side)
	noise = fn.get_seamless_image(side, side)
	noise.convert(Image.FORMAT_L8)
	noise_texture = ImageTexture.create_from_image(noise)
	RenderingServer.global_shader_parameter_set("wind_noise", noise_texture)
	RenderingServer.global_shader_parameter_set("wind_tile_m", float(cfg.tile_m))
	RenderingServer.global_shader_parameter_set(
		"wind_altitude_scale_m", float(cfg.altitude_scale_m)
	)
	RenderingServer.global_shader_parameter_set("wind_max_ms", float(cfg.max_ms))
	_push()
	return errors.is_empty()


func is_configured() -> bool:
	return not _cfg.is_empty()


## Takes the weather's blended parameters: direction (from wind_from_deg),
## base speed and gustiness.
func set_from_weather(p: Dictionary) -> void:
	var toward := deg_to_rad(float(p.wind_from_deg) + 180.0)
	dir = Vector2(sin(toward), -cos(toward))
	base = float(p.wind_speed)
	gust = float(p.gustiness)


func _process(delta: float) -> void:
	if is_configured():
		advance(delta)


## Moves the gust field downwind by `dt` seconds and sets the globals.
func advance(dt: float) -> void:
	var tile := float(_cfg.tile_m)
	scroll = (scroll + dir * base * dt).posmod(tile)
	time_s += dt
	_push()


## Base speed at height `y`: raised with altitude, capped.
func base_at(y: float) -> float:
	var k := 1.0 + maxf(y, 0.0) / float(_cfg.altitude_scale_m)
	return minf(base * k, float(_cfg.max_ms))


## Wind speed in m/s at an engine position.
func speed_at(pos: Vector3) -> float:
	var n := noise_at((Vector2(pos.x, pos.z) - scroll) / float(_cfg.tile_m))
	return base_at(pos.y) * (1.0 + gust * (2.0 * n - 1.0))


func vector_at(pos: Vector3) -> Vector3:
	return Vector3(dir.x, 0.0, dir.y) * speed_at(pos)


## The noise at texture coordinates `uv` (one repeat per unit), bilinear
## between texel centres with wrapping, as a linear-filtered texture reads.
func noise_at(uv: Vector2) -> float:
	var side := noise.get_width()
	var u := uv.x * side - 0.5
	var v := uv.y * side - 0.5
	var x0 := floori(u)
	var y0 := floori(v)
	var fx := u - x0
	var fy := v - y0
	var a := lerpf(_texel(x0, y0), _texel(x0 + 1, y0), fx)
	var b := lerpf(_texel(x0, y0 + 1), _texel(x0 + 1, y0 + 1), fx)
	return lerpf(a, b, fy)


## Shelter factor of a biome id (1.0 for ids the table lacks).
func shelter_factor(biome: int) -> float:
	var table: Array = _cfg.shelter_by_biome
	return float(table[biome]) if biome >= 0 and biome < table.size() else 1.0


## Exposure 0..1.3 at an engine position outdoors: the biome's shelter
## factor times (1 − Σ weight × hit) for rays from ray_height_m above the
## point toward upwind, at least min_exposure.
func exposure_at(pos: Vector3) -> float:
	var biome := -1
	if biome_of.is_valid():
		biome = int(biome_of.call(pos))
	elif world != null and world.is_loaded():
		biome = world.biome_at(pos.x, pos.z)
	var k := 1.0
	var lengths: Array = _cfg.ray_lengths_m
	var weights: Array = _cfg.ray_weights
	for i in lengths.size():
		if _blocked(pos, float(lengths[i])):
			k -= float(weights[i])
	return maxf(float(_cfg.min_exposure), shelter_factor(biome) * k)


func _blocked(pos: Vector3, length: float) -> bool:
	if not is_inside_tree():
		return false
	var space := get_world_3d().direct_space_state
	var from := pos + Vector3(0.0, float(_cfg.ray_height_m), 0.0)
	var to := from - Vector3(dir.x, 0.0, dir.y) * length
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 << (int(_cfg.blocker_layer) - 1))
	return not space.intersect_ray(q).is_empty()


func _texel(x: int, y: int) -> float:
	var side := noise.get_width()
	return noise.get_pixel(posmod(x, side), posmod(y, side)).r


func _push() -> void:
	RenderingServer.global_shader_parameter_set("wind_dir", dir)
	RenderingServer.global_shader_parameter_set("wind_base", base)
	RenderingServer.global_shader_parameter_set("wind_gust", gust)
	RenderingServer.global_shader_parameter_set("wind_scroll", scroll)
	RenderingServer.global_shader_parameter_set("wind_time", time_s)
