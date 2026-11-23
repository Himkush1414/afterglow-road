class_name Rain
extends Node3D
## Rain (08 §4.4, §4.5). Exposure of a point is 1 when a ray straight up,
## tilted toward upwind by the local wind speed, hits nothing on the
## blocking layers (buildings, player pieces, tents), else 0; under dense
## forest canopy it is scaled down. The visible rain is a GPU particle
## volume that follows the camera and falls at fall_ms slanted by the wind
## (atan(w / fall_ms)). With collisions (Forward+) a camera-following height
## field stops drops at roofs and splashes rise where drops land. Without
## (Mobile, A-17 fallback: its height field is not re-captured after it
## moves) the volume hides while the camera's rain exposure is 0 and the
## splashes rise from a disc on the ground under the camera. All numbers
## come from the "rain" tuning.

const STREAK_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled;
uniform float alpha = 0.3;

void vertex() {
	// Billboard about the particle's own Y axis (aligned to its velocity).
	vec3 axis = MODEL_MATRIX[1].xyz;
	vec3 centre = MODEL_MATRIX[3].xyz;
	vec3 side = normalize(cross(normalize(axis), CAMERA_POSITION_WORLD - centre));
	vec3 world = centre + side * VERTEX.x * length(MODEL_MATRIX[0].xyz) + axis * VERTEX.y;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	NORMAL = vec3(0.0, 0.0, 1.0);
	ALBEDO = vec3(0.8, 0.85, 0.9);
	float across = 1.0 - abs(UV.x * 2.0 - 1.0);
	ALPHA = alpha * across * smoothstep(0.0, 0.3, UV.y) * smoothstep(1.0, 0.7, UV.y);
}
"""
const SPLASH_SHADER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled;
uniform float alpha = 0.6;
uniform float radius_m = 8.0;
varying float near;

void vertex() {
	vec3 centre = MODEL_MATRIX[3].xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	near = 1.0 - smoothstep(radius_m - 1.0, radius_m, distance(CAMERA_POSITION_WORLD, centre));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * s, INV_VIEW_MATRIX[1] * s, INV_VIEW_MATRIX[2] * s, MODEL_MATRIX[3]
	);
}

void fragment() {
	NORMAL = vec3(0.0, 0.0, 1.0);
	ALBEDO = vec3(0.8, 0.85, 0.9);
	float r = length(UV * 2.0 - 1.0);
	ALPHA = alpha * COLOR.a * near * (1.0 - smoothstep(0.4, 1.0, r));
}
"""

var errors: PackedStringArray = []
## Rain intensity 0..1 from the weather.
var intensity := 0.0
## Tilts the up ray; null or unconfigured means no tilt.
var wind: Wind
var world: WorldData
## Tree cover 0..1 at an engine position; defaults to the world's mask.
var canopy_of: Callable
## The particle volume (null until build_volume).
var particles: GPUParticles3D
var height_field: GPUParticlesCollisionHeightField3D
## Droplets thrown up where drops land (sub-emitter of `splash_drops`).
var splashes: GPUParticles3D
## Undrawn drops over a disc of the splash radius that bounce off on their first
## contact (splash_bounce: enough to leave contact, so one splash each) and
## throw a splash there (drops hidden on contact cannot sub-emit).
var splash_drops: GPUParticles3D
## False when the volume was built without collisions (fallback).
var collides := true
## Ground height under an engine position for fallback splashes; defaults
## to the world's terrain.
var ground_of: Callable

var _cfg := {}
var _mask := 0
var _pm: ParticleProcessMaterial
var _splash_pm: ParticleProcessMaterial
var _shelter_wait := 0.0


## Takes the "rain" tuning group. False and `errors` when a blocking layer
## is outside 1..32.
func configure(cfg: Dictionary) -> bool:
	errors.clear()
	_cfg = cfg
	_mask = 0
	for layer: Variant in cfg.block_layers:
		if int(layer) < 1 or int(layer) > 32:
			errors.append("rain: block layer %s outside 1..32" % layer)
		else:
			_mask |= 1 << (int(layer) - 1)
	if (cfg.get("volume_m", [0, 0, 0]) as Array).size() != 3:
		errors.append("rain: volume_m needs 3 sizes")
	if cfg.has("ripple_cell_m"):
		RenderingServer.global_shader_parameter_set("rain_ripple_cell_m", float(cfg.ripple_cell_m))
		RenderingServer.global_shader_parameter_set(
			"rain_ripple_period_s", float(cfg.ripple_period_s)
		)
		RenderingServer.global_shader_parameter_set(
			"rain_ripple_strength", float(cfg.ripple_strength)
		)
	return errors.is_empty()


func is_configured() -> bool:
	return not _cfg.is_empty()


## Takes the weather's blended parameters (rain intensity) and hands the
## intensity to the water shaders (ripples).
func set_from_weather(p: Dictionary) -> void:
	intensity = float(p.rain)
	RenderingServer.global_shader_parameter_set("rain_intensity", intensity)


## Builds the particle volume with `streaks` drops at full intensity (the
## quality preset's rain_streaks); with `collide` also the roof height field
## and the splash drops, else the fallback (see the class note).
func build_volume(streaks: int, collide := true) -> void:
	for n: Node in [particles, height_field, splashes, splash_drops]:
		if n != null:
			remove_child(n)  # frees the names for the new nodes
			n.queue_free()
	height_field = null
	splash_drops = null
	collides = collide
	var size := _volume()
	_pm = ParticleProcessMaterial.new()
	_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_pm.emission_box_extents = Vector3(size.x * 0.5, 0.0, size.z * 0.5)
	_pm.spread = 0.0
	_pm.gravity = Vector3.ZERO
	_pm.particle_flag_align_y = true
	_pm.collision_mode = (
		ParticleProcessMaterial.COLLISION_HIDE_ON_CONTACT
		if collide
		else ParticleProcessMaterial.COLLISION_DISABLED
	)
	particles = GPUParticles3D.new()
	particles.name = "Drops"
	particles.amount = maxi(streaks, 1)
	particles.lifetime = lifetime()
	particles.preprocess = lifetime()
	particles.process_material = _pm
	particles.collision_base_size = float(_cfg.collision_size_m)
	particles.visibility_aabb = AABB(
		Vector3(-size.x, -size.y * 1.5, -size.z), Vector3(size.x * 2.0, size.y * 2.0, size.z * 2.0)
	)
	var streak := QuadMesh.new()
	streak.size = Vector2(float(_cfg.streak_width_m), float(_cfg.streak_length_m))
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = STREAK_SHADER
	mat.set_shader_parameter("alpha", float(_cfg.streak_alpha))
	streak.material = mat
	particles.draw_pass_1 = streak
	particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(particles)
	splashes = _build_splashes(streaks)
	add_child(splashes)
	if not collide:
		follow(Vector3.ZERO)
		return
	splash_drops = _build_splash_drops(streaks)
	add_child(splash_drops)
	height_field = GPUParticlesCollisionHeightField3D.new()
	var hf := float(_cfg.height_field_m)
	height_field.size = Vector3(hf, hf, hf)
	height_field.resolution = (
		_resolution(int(_cfg.height_field_res)) as GPUParticlesCollisionHeightField3D.Resolution
	)
	height_field.follow_camera_enabled = true
	height_field.update_mode = GPUParticlesCollisionHeightField3D.UPDATE_MODE_ALWAYS
	add_child(height_field)
	follow(Vector3.ZERO)


## Seconds a drop takes to fall through the volume's height.
func lifetime() -> float:
	return _volume().y / float(_cfg.fall_ms)


## Drop velocity at `eye`: fall_ms down plus the wind's speed downwind, so
## the streak slant is atan(w / fall_ms).
func fall_velocity(eye: Vector3) -> Vector3:
	var v := Vector3(0.0, -float(_cfg.fall_ms), 0.0)
	if wind != null and wind.is_configured():
		v += Vector3(wind.dir.x, 0.0, wind.dir.y) * wind.speed_at(eye)
	return v


## Moves the volume to `eye` (its top above, shifted upwind so the slanted
## drops fill the box around the eye) and applies the wind and intensity.
## The Rain node itself stays at the origin.
func follow(eye: Vector3) -> void:
	if particles == null:
		return
	var v := fall_velocity(eye)
	var drift := Vector3(v.x, 0.0, v.z) * lifetime() * 0.5
	particles.position = eye + Vector3(0.0, _volume().y * 0.5, 0.0) - drift
	_pm.direction = v.normalized()
	_pm.initial_velocity_min = v.length()
	_pm.initial_velocity_max = v.length()
	particles.amount_ratio = clampf(intensity, 0.0, 1.0)
	particles.emitting = intensity > 0.0
	splashes.position = eye
	if not collides:
		splashes.position.y = _ground(eye)
		splashes.amount_ratio = particles.amount_ratio
		splashes.emitting = particles.emitting
		return
	splash_drops.position = particles.position
	_splash_pm.direction = _pm.direction
	_splash_pm.initial_velocity_min = v.length()
	_splash_pm.initial_velocity_max = v.length()
	splash_drops.amount_ratio = particles.amount_ratio
	splash_drops.emitting = particles.emitting


## Fallback only: hides the volume and the splashes while `eye` is
## sheltered (rain exposure 0); always shown with collisions.
func shelter(eye: Vector3) -> void:
	var shown := collides or exposure_at(eye) > 0.0
	particles.visible = shown
	splashes.visible = shown


func _process(delta: float) -> void:
	if particles == null or not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	follow(cam.global_position)
	_shelter_wait -= delta
	if _shelter_wait <= 0.0:
		_shelter_wait = float(_cfg.shelter_check_s)
		shelter(cam.global_position)


func _ground(eye: Vector3) -> float:
	if ground_of.is_valid():
		return float(ground_of.call(eye))
	if world != null and world.is_loaded():
		return world.height_at(eye.x, eye.z)
	return eye.y


func _build_splash_drops(streaks: int) -> GPUParticles3D:
	var r := float(_cfg.splash_radius_m)
	_splash_pm = _pm.duplicate() as ParticleProcessMaterial
	_splash_pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	_splash_pm.emission_ring_axis = Vector3.UP
	_splash_pm.emission_ring_radius = r
	_splash_pm.emission_ring_inner_radius = 0.0
	_splash_pm.emission_ring_height = 0.0
	_splash_pm.emission_ring_cone_angle = 90.0
	_splash_pm.collision_mode = ParticleProcessMaterial.COLLISION_RIGID
	_splash_pm.collision_bounce = float(_cfg.splash_bounce)
	_splash_pm.collision_friction = 0.0
	_splash_pm.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_COLLISION
	_splash_pm.sub_emitter_amount_at_collision = 1
	var p := GPUParticles3D.new()
	p.name = "SplashDrops"
	p.amount = maxi(int(streaks * float(_cfg.splash_share)), 1)
	p.lifetime = lifetime()
	p.preprocess = lifetime()
	p.process_material = _splash_pm
	p.collision_base_size = float(_cfg.collision_size_m)
	p.visibility_aabb = particles.visibility_aabb
	p.draw_pass_1 = null
	p.sub_emitter = NodePath("../Splashes")
	return p


func _build_splashes(streaks: int) -> GPUParticles3D:
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3.UP
	pm.spread = 45.0
	pm.initial_velocity_min = float(_cfg.splash_speed_ms) * 0.5
	pm.initial_velocity_max = float(_cfg.splash_speed_ms)
	pm.gravity = Vector3(0.0, -9.8, 0.0)
	var fade := Gradient.new()
	fade.set_color(0, Color(1, 1, 1, 1))
	fade.set_color(1, Color(1, 1, 1, 0))
	var ramp := GradientTexture1D.new()
	ramp.gradient = fade
	pm.color_ramp = ramp
	if not collides:  # no splash drops: rise from a disc on the ground
		pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
		pm.emission_ring_axis = Vector3.UP
		pm.emission_ring_radius = float(_cfg.splash_radius_m)
		pm.emission_ring_inner_radius = 0.0
		pm.emission_ring_height = 0.0
		pm.emission_ring_cone_angle = 90.0
	var p := GPUParticles3D.new()
	p.name = "Splashes"
	p.amount = maxi(int(streaks * float(_cfg.splash_share)), 1)
	p.lifetime = float(_cfg.splash_s)
	p.process_material = pm
	var r := float(_cfg.splash_radius_m)
	p.visibility_aabb = AABB(Vector3(-r, -r, -r), Vector3(r, r, r) * 2.0)
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * float(_cfg.splash_size_m)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = SPLASH_SHADER
	mat.set_shader_parameter("radius_m", r)
	quad.material = mat
	p.draw_pass_1 = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return p


func _volume() -> Vector3:
	var v: Array = _cfg.volume_m
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


## Height field resolution enum for a side in pixels (256 → 0 … 8192 → 5).
static func _resolution(px: int) -> int:
	var r := 0
	var side := 256
	while side < px and r < 5:
		side *= 2
		r += 1
	return r


## Rain exposure 0..1 at an engine position.
func exposure_at(pos: Vector3) -> float:
	if _roofed(pos):
		return 0.0
	var cover := 0.0
	if canopy_of.is_valid():
		cover = float(canopy_of.call(pos))
	elif world != null and world.is_loaded():
		cover = world.tree_cover_at(pos.x, pos.z)
	return float(_cfg.canopy_factor) if cover > float(_cfg.canopy_cover) else 1.0


## Unit vector of the up ray at `pos`: tilted toward upwind by
## tilt_deg_per_ms per m/s of the local wind.
func ray_direction(pos: Vector3) -> Vector3:
	if wind == null or not wind.is_configured():
		return Vector3.UP
	var tilt := deg_to_rad(float(_cfg.tilt_deg_per_ms) * wind.speed_at(pos))
	var upwind := -Vector3(wind.dir.x, 0.0, wind.dir.y)
	return Vector3.UP * cos(tilt) + upwind * sin(tilt)


func _roofed(pos: Vector3) -> bool:
	if not is_inside_tree():
		return false
	var from := pos + Vector3(0.0, float(_cfg.ray_start_m), 0.0)
	var to := from + ray_direction(pos) * float(_cfg.ray_length_m)
	var q := PhysicsRayQueryParameters3D.create(from, to, _mask)
	return not get_world_3d().direct_space_state.intersect_ray(q).is_empty()
