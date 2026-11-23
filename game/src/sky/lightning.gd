class_name Lightning
extends Node3D
## Lightning (08 §4.5): while the weather allows it, a strike every
## interval_min_s..interval_max_s real seconds from a random azimuth and
## distance. A strike is a white directional flash in pulses plus a bolt
## drawn on the horizon toward the azimuth; the thunder follows after
## distance / sound_ms seconds as a signal for the audio. All numbers come
## from the "lightning" tuning.

## A strike began: compass azimuth it comes from (0 north, 90 east), metres.
signal flashed(azimuth_deg: float, distance_m: float)
## The strike's sound arrives now.
signal thunder(distance_m: float)

const BOLT_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;
uniform float seed;
uniform float glow = 1.0;

float hash11(float x) { return fract(sin(x * 127.1 + seed * 311.7) * 43758.5453); }

float path(float y) {
	float x = 0.0;
	float amp = 0.18;
	for (int k = 0; k < 4; k++) {
		float f = exp2(float(k) + 2.0);
		float i = floor(y * f);
		x += mix(hash11(i + f * 13.0), hash11(i + 1.0 + f * 13.0), fract(y * f)) * amp - amp * 0.5;
		amp *= 0.5;
	}
	return 0.5 + x;
}

void fragment() {
	float d = abs(UV.x - path(UV.y));
	float core = 1.0 - smoothstep(0.004, 0.02, d);
	float halo = 1.0 - smoothstep(0.0, 0.12, d);
	ALBEDO = vec3(0.85, 0.9, 1.0) * glow * (core * 3.0 + halo * 0.25);
}
"""

var errors: PackedStringArray = []
## True while the weather state has lightning.
var active := false
var rng: RandomNumberGenerator
var light: DirectionalLight3D
var bolt: MeshInstance3D
## Seconds since configure (real time).
var time_s := 0.0
## Time of the next strike while active; INF when none is planned.
var next_strike_s := INF
var azimuth_deg := 0.0
var distance_m := 0.0

var _cfg := {}
var _flash_start := -INF
## [due time, distance] of thunder still on its way.
var _thunder: Array[Vector2] = []


## Takes the "lightning" tuning group and builds the light and the bolt.
## False and `errors` when a range is reversed.
func configure(cfg: Dictionary) -> bool:
	errors.clear()
	_cfg = cfg
	if float(cfg.interval_min_s) > float(cfg.interval_max_s):
		errors.append("lightning: interval_min_s above interval_max_s")
	if float(cfg.distance_min_m) > float(cfg.distance_max_m):
		errors.append("lightning: distance_min_m above distance_max_m")
	rng = Rng.for_save_key(int(cfg.seed_key))
	if light == null:
		light = DirectionalLight3D.new()
		light.shadow_enabled = false
		light.light_energy = 0.0
		light.visible = false
		add_child(light)
		bolt = MeshInstance3D.new()
		bolt.mesh = QuadMesh.new()
		bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = Shader.new()
		mat.shader.code = BOLT_SHADER
		bolt.material_override = mat
		bolt.visible = false
		add_child(bolt)
	return errors.is_empty()


func is_configured() -> bool:
	return not _cfg.is_empty()


## Takes the weather's blended parameters (whether lightning is on).
func set_from_weather(p: Dictionary) -> void:
	set_active(bool(p.lightning))


func set_active(on: bool) -> void:
	if on and not active:
		next_strike_s = time_s + _interval()
	elif not on:
		next_strike_s = INF
	active = on


func _process(delta: float) -> void:
	if is_configured():
		advance(delta)


## Moves `dt` real seconds on: strikes that fall due, thunder that arrives,
## the flash light and the bolt.
func advance(dt: float) -> void:
	time_s += dt
	while active and time_s >= next_strike_s:
		var at := next_strike_s
		strike(rng.randf_range(0.0, 360.0), _distance(), at)
		next_strike_s = at + _interval()
	var i := 0
	while i < _thunder.size():
		if time_s >= _thunder[i].x:
			thunder.emit(_thunder[i].y)
			_thunder.remove_at(i)
		else:
			i += 1
	_show()


## Starts a strike at `at` (default now) from `azimuth` at `distance`.
func strike(azimuth: float, distance: float, at := NAN) -> void:
	_flash_start = time_s if is_nan(at) else at
	azimuth_deg = azimuth
	distance_m = distance
	_thunder.append(Vector2(_flash_start + distance / float(_cfg.sound_ms), distance))
	var mat := bolt.material_override as ShaderMaterial
	mat.set_shader_parameter("seed", rng.randf() * 100.0)
	flashed.emit(azimuth, distance)
	_show()


## Flash light energy `t` seconds after the strike: `pulses` equal pulses
## with equal gaps inside flash_s, 0 outside.
func flash_energy(t: float) -> float:
	var length := float(_cfg.flash_s)
	if t < 0.0 or t >= length:
		return 0.0
	var slots := 2 * int(_cfg.pulses) - 1
	var slot := floori(t / length * slots)
	return float(_cfg.flash_energy) if slot % 2 == 0 else 0.0


## Unit vector from the viewer toward the flash.
func toward_flash() -> Vector3:
	var az := deg_to_rad(azimuth_deg)
	var el := deg_to_rad(float(_cfg.flash_elevation_deg))
	return Vector3(sin(az) * cos(el), sin(el), -cos(az) * cos(el))


func pending_thunder() -> int:
	return _thunder.size()


func _show() -> void:
	var e := flash_energy(time_s - _flash_start)
	light.light_energy = e
	light.visible = e > 0.0
	bolt.visible = e > 0.0
	if e <= 0.0:
		return
	light.basis = Basis.looking_at(-toward_flash())
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var eye := cam.global_position if cam != null else Vector3.ZERO
	var az := deg_to_rad(azimuth_deg)
	var flat := Vector3(sin(az), 0.0, -cos(az))
	var d := float(_cfg.bolt_draw_m)
	var h := d * tan(deg_to_rad(float(_cfg.bolt_top_deg)))
	var w := d * tan(deg_to_rad(float(_cfg.bolt_width_deg)))
	var xf := Transform3D(
		Basis.looking_at(flat) * Basis.from_scale(Vector3(w, h, 1.0)),
		eye + flat * d + Vector3(0.0, h * 0.5, 0.0)
	)
	if is_inside_tree():
		bolt.global_transform = xf
	else:
		bolt.transform = xf


func _interval() -> float:
	return rng.randf_range(float(_cfg.interval_min_s), float(_cfg.interval_max_s))


func _distance() -> float:
	return rng.randf_range(float(_cfg.distance_min_m), float(_cfg.distance_max_m))
