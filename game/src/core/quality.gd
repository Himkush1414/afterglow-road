class_name Quality
extends RefCounted
## Quality presets (23 §3) from the "quality" tuning group. `apply` sets the
## settings the engine owns on a viewport and keeps every preset value
## readable through `value(key)` for the systems that own the rest.
## The player's video settings override the preset's render scale and
## frame cap (Settings conventions: render_scale 0 and max_fps -1 = preset).

const SCALING := {
	"bilinear": Viewport.SCALING_3D_MODE_BILINEAR,
	"none": Viewport.SCALING_3D_MODE_BILINEAR,
	"fsr": Viewport.SCALING_3D_MODE_FSR,
	"fsr2": Viewport.SCALING_3D_MODE_FSR2,
}

## Values of the applied preset with the player's overrides.
static var current: Dictionary = {}
static var preset_id := ""


static func presets() -> Dictionary:
	return ContentDB.tuning("quality").get("presets", {})


## The player's preset, else the platform default from data.
static func chosen() -> String:
	var p: String = Settings.get_value("video", "preset")
	if presets().has(p):
		return p
	var key := "default_mobile" if OS.has_feature("mobile") else "default_desktop"
	# shortcut: platform default only; the GPU-name and benchmark choice of 23 §1 comes later.
	return ContentDB.tuning("quality").get(key, "")


## Applies `preset` to `viewport` and the engine. False for an unknown preset.
static func apply(preset: String, viewport: Viewport) -> bool:
	if not presets().has(preset):
		Log.error("quality", "unknown preset '%s'" % preset)
		return false
	var v: Dictionary = (presets()[preset] as Dictionary).duplicate(true)
	var scale: float = Settings.get_value("video", "render_scale")
	if scale > 0.0:
		v.render_scale = scale
	var fps: int = Settings.get_value("video", "max_fps")
	if fps >= 0:
		v.frame_cap = fps
	viewport.scaling_3d_scale = v.render_scale
	viewport.scaling_3d_mode = SCALING[v.scaling_filter]
	viewport.use_taa = v.aa == "taa"
	viewport.msaa_3d = Viewport.MSAA_2X if v.aa == "msaa2_fxaa" else Viewport.MSAA_DISABLED
	viewport.screen_space_aa = (
		Viewport.SCREEN_SPACE_AA_DISABLED if v.aa == "taa" else Viewport.SCREEN_SPACE_AA_FXAA
	)
	Engine.max_fps = int(v.frame_cap)
	var vsync: bool = Settings.get_value("video", "vsync")
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
	)
	RenderingServer.directional_shadow_atlas_set_size(int(v.shadow_map), true)
	current = v
	preset_id = preset
	Log.info("quality", "preset %s" % preset)
	return true


## Value of `key` in the applied preset, or null before any apply.
static func value(key: String) -> Variant:
	return current.get(key)
