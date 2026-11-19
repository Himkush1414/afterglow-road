extends TestCase
## Quality: T-23-1, every preset value is applied or readable back
## (table-driven over the presets in the active content).

var _vp: SubViewport
var _fps := 0
var _before := {}


func before_each() -> void:
	_vp = SubViewport.new()
	tree.root.add_child(_vp)
	_fps = Engine.max_fps
	_before = {}
	for key: String in ["render_scale", "max_fps", "preset"]:
		_before[key] = Settings.get_value("video", key)


func after_each() -> void:
	for key: String in ["render_scale", "max_fps", "preset"]:
		Settings.set_value("video", key, _before[key])
	Engine.max_fps = _fps
	_vp.queue_free()


func test_every_preset_value_is_applied_and_readable_back() -> void:
	var presets := Quality.presets()
	check(presets.size() >= 2, "presets in data: %d" % presets.size())
	for id: String in presets:
		var p: Dictionary = presets[id]
		check(Quality.apply(id, _vp), id)
		check_eq(Quality.preset_id, id)
		for key: String in p:
			check_eq(Quality.value(key), p[key], "%s.%s" % [id, key])
		check_near(_vp.scaling_3d_scale, p.render_scale, 1e-6, "%s scale" % id)
		check_eq(_vp.scaling_3d_mode, Quality.SCALING[p.scaling_filter], "%s filter" % id)
		check_eq(_vp.use_taa, p.aa == "taa", "%s taa" % id)
		check_eq(_vp.msaa_3d == Viewport.MSAA_2X, p.aa == "msaa2_fxaa", "%s msaa" % id)
		check_eq(
			_vp.screen_space_aa == Viewport.SCREEN_SPACE_AA_FXAA, p.aa != "taa", "%s fxaa" % id
		)
		check_eq(Engine.max_fps, int(p.frame_cap), "%s frame cap" % id)


func test_player_settings_override_scale_and_cap() -> void:
	var id: String = Quality.presets().keys()[0]
	Settings.set_value("video", "render_scale", 0.55)
	Settings.set_value("video", "max_fps", 0)
	Quality.apply(id, _vp)
	check_near(_vp.scaling_3d_scale, 0.55, 1e-6, "render scale override")
	check_eq([Engine.max_fps, Quality.value("frame_cap")], [0, 0], "unlimited override")


func test_choice_and_unknown_presets() -> void:
	var q := ContentDB.tuning("quality")
	var platform: String = q.default_mobile if OS.has_feature("mobile") else q.default_desktop
	Settings.set_value("video", "preset", "")
	check_eq(Quality.chosen(), platform, "platform default")
	check(Quality.presets().has(platform), "default names a preset")
	var other: String = Quality.presets().keys()[-1]
	Settings.set_value("video", "preset", other)
	check_eq(Quality.chosen(), other, "player's preset")
	Settings.set_value("video", "preset", "no_such_preset")
	check_eq(Quality.chosen(), platform, "unknown saved preset falls back")
	check(not Quality.apply("no_such_preset", _vp), "unknown preset refused")
