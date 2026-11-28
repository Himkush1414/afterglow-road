class_name Mirror
extends Node3D
## A planar mirror (10 §3, D-09): a quad of width_m x height_m facing this
## node's +Z, centred on it. While live, its own camera sits at the eye
## mirrored in the mirror plane, looks out through the mirror (forward =
## the mirror's normal, right = minus the mirror's right) with an off-axis
## frustum whose near rectangle is the quad, so nothing behind the mirror is
## drawn, and renders into a SubViewport of the preset's size with the
## quad's aspect; the surface shows it with U flipped and a tint. Not live:
## a dull grey gradient. Damage: the first hit or an impact of at least
## crack_impact_j cracks it (still live), the second shatters it (surface
## gone, never live again). Numbers: the "mirror" tuning group.

enum State { INTACT, CRACKED, SHATTERED }

## Render layer (1-based) of mirror surfaces; mirror cameras skip it.
const SURFACE_LAYER := 3
const MIN_NEAR_M := 0.05
const KEYS: Array[String] = ["far_desktop_m", "far_phone_m", "crack_impact_j", "tint"]
const SHADER := preload("res://shaders/mirror.gdshader")

@export var width_m := 0.6
@export var height_m := 1.2

var errors: PackedStringArray = []
var state := State.INTACT
var live := false
var viewport: SubViewport
var camera: Camera3D
var surface: MeshInstance3D

var _cfg := {}
var _material: ShaderMaterial
var _interval_s := 0.0
var _since_s := 0.0


## Sets up the surface, viewport and camera: `cfg` the "mirror" tuning
## group, `size_px` and `hz` the quality preset's mirror size and rate
## (hz >= 60: every frame), `phone` picks the far distance. False with
## `errors`.
func configure(cfg: Dictionary, size_px: int, hz: float, phone: bool) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("mirror: missing %s" % key)
	if size_px <= 0 or hz <= 0.0 or width_m <= 0.0 or height_m <= 0.0:
		errors.append("mirror: size, rate and dimensions must be positive")
	if not errors.is_empty():
		return false
	_cfg = cfg
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_material.set_shader_parameter("tint", float(cfg.tint))
	surface = MeshInstance3D.new()
	surface.name = "Surface"
	var quad := QuadMesh.new()
	quad.size = Vector2(width_m, height_m)
	surface.mesh = quad
	surface.layers = 1 << (SURFACE_LAYER - 1)
	surface.material_override = _material
	add_child(surface)
	viewport = SubViewport.new()
	viewport.name = "Reflection"
	viewport.size = viewport_size(size_px, width_m, height_m)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	camera = Camera3D.new()
	camera.name = "MirrorCamera"
	camera.top_level = true
	camera.projection = Camera3D.PROJECTION_FRUSTUM
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.cull_mask = 0xFFFFF & ~(1 << (SURFACE_LAYER - 1))
	camera.far = float(cfg.far_phone_m if phone else cfg.far_desktop_m)
	viewport.add_child(camera)
	_material.set_shader_parameter("reflection", viewport.get_texture())
	_interval_s = 0.0 if hz >= 60.0 else 1.0 / hz
	_refresh()
	return true


## Viewport size for the preset's mirror size: the quad's longer side gets
## `size_px`, the other keeps the aspect.
static func viewport_size(size_px: int, w: float, h: float) -> Vector2i:
	if h >= w:
		return Vector2i(maxi(1, roundi(size_px * w / h)), size_px)
	return Vector2i(size_px, maxi(1, roundi(size_px * h / w)))


## Front normal, right and up of the quad (global).
func axes() -> Array[Vector3]:
	var b := global_basis.orthonormalized()
	return [b.z, b.x, b.y]


## Signed distance of `eye` in front of the mirror plane.
func distance_to_eye(eye: Vector3) -> float:
	return (eye - global_position).dot(axes()[0])


## Makes the mirror live or dull; a shattered mirror stays dull.
func set_live(on: bool) -> void:
	live = on and state != State.SHATTERED
	_since_s = _interval_s  # render on the first live frame
	_refresh()


## Places the mirror camera for `eye` (10 §3.2) and renders when due:
## every frame, or every 1/hz seconds at a lower rate. `delta`: seconds
## since the last call.
func update_view(eye: Vector3, delta: float) -> void:
	if not live:
		return
	place_camera(eye)
	if _interval_s <= 0.0:
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		return
	_since_s += delta
	if _since_s >= _interval_s:
		_since_s = fmod(_since_s, _interval_s)
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## The 10 §3.2 camera: mirrored eye, basis forward = n, up = u, right = -r,
## frustum near = max(d, 0.05), size = h x near / d, offset to the quad.
func place_camera(eye: Vector3) -> void:
	var a := axes()
	var n := a[0]
	var u := a[2]
	var c := global_position
	var d := maxf((eye - c).dot(n), 1e-4)
	var mirrored := eye - 2.0 * d * n
	camera.global_transform = Transform3D(Basis.looking_at(n, u), mirrored)
	var near := maxf(d, MIN_NEAR_M)
	var off := Vector2((c - mirrored).dot(camera.global_basis.x), (c - mirrored).dot(u)) * near / d
	camera.set_frustum(height_m * near / d, off, near, camera.far)


## A tool or thrown hit: cracks an intact mirror, shatters a cracked one.
func hit() -> void:
	match state:
		State.INTACT:
			state = State.CRACKED
		State.CRACKED:
			state = State.SHATTERED
	if state == State.SHATTERED:
		live = false
	_refresh()


## An impact of `energy_j` joules counts as a hit at the crack threshold.
func impact(energy_j: float) -> void:
	if energy_j >= float(_cfg.crack_impact_j):
		hit()


func _refresh() -> void:
	if _material == null:
		return
	_material.set_shader_parameter("live", live)
	_material.set_shader_parameter("cracked", state == State.CRACKED)
	surface.visible = state != State.SHATTERED
	if not live:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
