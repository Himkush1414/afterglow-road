class_name ShaderClock
extends RefCounted
## The shaders' TIME as seen from scripts. TIME is the renderer's own clock
## (wrapped at rendering/limits/time/time_rollover_secs) and no API returns
## it, so `measure` draws one frame of a probe that writes TIME into its
## pixel and reads it back; `now()` is then the wall clock plus that offset.
## Without a display (headless), the offset stays 0.

const PROBE := """shader_type canvas_item;
void fragment() {
	float ms = floor(TIME * 1000.0);
	COLOR = vec4(floor(ms / 65536.0) / 255.0, floor(mod(ms, 65536.0) / 256.0) / 255.0,
			mod(ms, 256.0) / 255.0, 1.0);
}
"""

## TIME minus the wall clock, seconds.
static var offset_s := 0.0
static var measured := false
static var _busy := false


static func rollover_s() -> float:
	return float(ProjectSettings.get_setting("rendering/limits/time/time_rollover_secs", 3600.0))


## The shaders' TIME now (to about one frame after a measurement).
static func now() -> float:
	return fposmod(Time.get_ticks_usec() / 1e6 + offset_s, rollover_s())


## Measures `offset_s` with a 2 x 2 probe viewport added under `parent`.
## Returns false without a display or while a measurement runs.
static func measure(parent: Node) -> bool:
	if DisplayServer.get_name() == "headless" or _busy:
		return false
	_busy = true
	var vp := SubViewport.new()
	vp.size = Vector2i(2, 2)
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var rect := ColorRect.new()
	rect.size = Vector2(2.0, 2.0)
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = PROBE
	rect.material = mat
	vp.add_child(rect)
	parent.add_child(vp)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var wall := Time.get_ticks_usec() / 1e6
	var c := vp.get_texture().get_image().get_pixel(0, 0)
	var ms := roundi(c.r * 255.0) * 65536 + roundi(c.g * 255.0) * 256 + roundi(c.b * 255.0)
	offset_s = fposmod(ms / 1000.0 - wall, rollover_s())
	vp.queue_free()
	measured = true
	_busy = false
	return true
