extends TestCase
## MirrorScreen (11 §5): states, tabs per mode, option cycling with the
## apply callback, Cancel restoring the look in the world (T-11-3),
## confirm handing the look back, the new-game leave prompt.

var _screen: MirrorScreen
var _cust := {}
var _applied: Array[Dictionary] = []


func before_each() -> void:
	var c: Variant = ContentDB.file_data("customization.json")
	_cust = c if c is Dictionary else {}
	_screen = (load("res://ui/mirror_screen.tscn") as PackedScene).instantiate()
	tree.root.add_child(_screen)
	_applied.clear()


func after_each() -> void:
	_screen.free()


func _apply(look: Dictionary) -> void:
	_applied.append(look.duplicate(true))


func test_in_world_offers_only_hair_and_cancel_restores() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var start := Appearance.default_of(_cust)
	_screen.open(_cust, start, MirrorScreen.Mode.IN_WORLD, _apply)
	check_eq(_screen.state, MirrorScreen.State.OPEN, "open")
	check_eq(_screen.tabs, ["hair"] as Array[String], "one tab")
	var cats := []
	for r: Array in _screen.rows():
		cats.append(r[1])
	check_eq(cats, ["hair", "facial_hair"], "hair style and facial hair only (T-11-3)")
	_screen.change(1)
	check(_applied.size() == 1 and _applied[0].hair != start.hair, "change applied at once")
	_screen.select_row(1)
	_screen.change(1)
	check(_applied[-1].facial_hair != start.facial_hair, "facial hair changed")
	_screen.cancel()
	check_eq(_screen.state, MirrorScreen.State.CANCELLED, "cancelled")
	check_eq(_applied[-1], start, "Cancel restores the previous look (T-11-3)")
	check(not _screen.visible, "closed")


func test_new_game_tabs_cycle_and_confirm() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var start := Appearance.default_of(_cust)
	var got := [{}]
	_screen.confirmed.connect(func(l: Dictionary) -> void: got[0] = l)
	_screen.open(_cust, start, MirrorScreen.Mode.NEW_GAME, _apply)
	check_eq(_screen.tabs.size(), 6, "six tabs")
	var styles: Array = _cust.hair_styles
	_screen.select_tab(_screen.tabs.find("hair"))
	for i in styles.size():
		_screen.change(1)
	check_eq(_screen.look.hair, start.hair, "a full cycle comes back to the start")
	_screen.change(-1)
	var want: Variant = styles[posmod(styles.find(start.hair) - 1, styles.size())]
	check_eq(_screen.look.hair, want, "previous value")
	_screen.select_tab(_screen.tabs.find("outfit"))
	check_eq(_screen.rows().size(), (_cust.outfit as Array).size(), "one row per garment")
	_screen.change(1)
	check_eq(
		int(_screen.look.outfit_colours[0]),
		(int(start.outfit_colours[0]) + 1) % (_cust.outfit[0].colours as Array).size(),
		"garment colour"
	)
	_screen.randomise()
	var r: Array = Appearance.validated(_screen.look, _cust)
	check((r[1] as PackedStringArray).is_empty(), "randomised look is valid")
	_screen.reset()
	check_eq(_screen.look, start, "reset to defaults")
	_screen.confirm()
	check_eq(_screen.state, MirrorScreen.State.CONFIRMED, "confirmed")
	check_eq(got[0], start, "confirm hands the look back")


func test_new_game_cancel_asks_first() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var left := [false]
	_screen.cancelled.connect(func() -> void: left[0] = true)
	_screen.open(_cust, Appearance.default_of(_cust), MirrorScreen.Mode.NEW_GAME, _apply)
	_screen.cancel()
	check_eq(_screen.state, MirrorScreen.State.OPEN, "still open: the prompt asks first")
	check(not left[0], "not left yet")
	_screen.leave_confirmed()
	check(left[0] and _screen.state == MirrorScreen.State.CANCELLED, "left after the prompt")


func test_value_texts_use_translation_keys() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	_screen.open(_cust, Appearance.default_of(_cust), MirrorScreen.Mode.NEW_GAME, _apply)
	for category: String in ["body", "build", "face", "hair", "facial_hair", "voice"]:
		var t := _screen.value_text(category)
		check(
			t != "" and not t.begins_with("mirror."),
			"%s shows text, not a key: '%s'" % [category, t]
		)
