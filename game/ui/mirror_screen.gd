class_name MirrorScreen
extends Control
## The appearance screen in front of a mirror (11 §5). A panel on the left
## third: a tab row, option rows (label, previous, value, next), Randomise,
## Reset, Confirm, Cancel. Every change calls `apply` with the new look at
## once. New game: all tabs; Cancel asks before leaving. In the world: only
## hair style and facial hair; Cancel restores the look it opened with.
## Keys: Q/E tabs, Up/Down rows, Left/Right values, R randomise, Backspace
## reset, Enter confirm, Esc cancel; A/D (held) turn the body (`turn`, -1..1
## of MAX_TURN), W/S or the mouse wheel lean in or out (`leaning`); the
## owner applies both. Text: translation keys only.

signal confirmed(look: Dictionary)
signal cancelled

enum State { CLOSED, OPEN, CONFIRMED, CANCELLED }
enum Mode { NEW_GAME, IN_WORLD }

## Largest body turn (11 §5.1), radians, and how fast A/D turn (share/s).
const MAX_TURN := deg_to_rad(70.0)
const TURN_PER_S := 1.5

## Tab -> rows [label key, category]; "outfit:<n>" is the n-th garment.
const TABS := {
	"body": [["mirror.body_type", "body"], ["mirror.build", "build"]],
	"skin": [["mirror.skin_tone", "skin"]],
	"face": [["mirror.face", "face"], ["mirror.eyes", "eye_colour"]],
	"hair":
	[
		["mirror.hair_style", "hair"],
		["mirror.hair_colour", "hair_colour"],
		["mirror.facial_hair", "facial_hair"],
	],
	"outfit": [],
	"voice": [["mirror.voice", "voice"], ["mirror.pitch", "voice_pitch"]],
}
const FULL_TABS: Array[String] = ["body", "skin", "face", "hair", "outfit", "voice"]
## In the world (C2): hair style and facial hair only.
const WORLD_ROWS := [["mirror.hair_style", "hair"], ["mirror.facial_hair", "facial_hair"]]

var state := State.CLOSED
var mode := Mode.NEW_GAME
var look := {}
var tabs: Array[String] = []
var tab := 0
var row := 0
## Body turn as a share of MAX_TURN (-1..1) and whether the eye leans in.
var turn := 0.0
var leaning := false

var _cust := {}
var _apply := Callable()
var _start := {}
var _rng := RandomNumberGenerator.new()
var _tab_bar: HBoxContainer
var _rows_box: VBoxContainer
var _prompt: ConfirmationDialog


func _ready() -> void:
	_build_ui()
	hide()


## Opens on `start` (an Appearance look) with the customization data;
## `apply` (Callable(look)) is called after every change.
func open(cust: Dictionary, start: Dictionary, open_mode: Mode, apply: Callable) -> void:
	_cust = cust
	_apply = apply
	mode = open_mode
	look = start.duplicate(true)
	_start = start.duplicate(true)
	var world_tabs: Array[String] = ["hair"]
	tabs = FULL_TABS.duplicate() if mode == Mode.NEW_GAME else world_tabs
	tab = 0
	row = 0
	turn = 0.0
	leaning = false
	state = State.OPEN
	_rng.randomize()
	show()
	_refresh()


## Rows [label key, category] of the current tab.
func rows() -> Array:
	if mode == Mode.IN_WORLD:
		return WORLD_ROWS
	if tabs[tab] == "outfit":
		var out := []
		var outfit: Array = _cust.outfit
		for i in outfit.size():
			out.append(["mirror." + String((outfit[i] as Dictionary).garment), "outfit:%d" % i])
		return out
	return TABS[tabs[tab]]


func select_tab(i: int) -> void:
	tab = posmod(i, tabs.size())
	row = 0
	_refresh()


func select_row(i: int) -> void:
	row = clampi(i, 0, rows().size() - 1)
	_refresh()


## Steps the current row's value by `step` through the data's choices.
func change(step: int) -> void:
	if state != State.OPEN:
		return
	var category: String = rows()[row][1]
	var choices := _choices(category)
	var i := choices.find(_value(category))
	_set_value(category, choices[posmod(i + step, choices.size())])
	_changed()


## A random look: every category, or (in the world) the offered ones.
func randomise() -> void:
	var r := Appearance.randomised(_cust, _rng)
	if mode == Mode.NEW_GAME:
		look = r
	else:
		for rw: Array in WORLD_ROWS:
			look[rw[1]] = r[rw[1]]
	_changed()


## Back to the defaults (new game) or to the look it opened with (world).
func reset() -> void:
	look = Appearance.default_of(_cust) if mode == Mode.NEW_GAME else _start.duplicate(true)
	_changed()


func confirm() -> void:
	if state != State.OPEN:
		return
	state = State.CONFIRMED
	hide()
	confirmed.emit(look.duplicate(true))


## In the world: restore and close. New game: ask first (leave_confirmed).
func cancel() -> void:
	if state != State.OPEN:
		return
	if mode == Mode.NEW_GAME:
		_prompt.popup_centered()
		return
	look = _start.duplicate(true)
	if _apply.is_valid():
		_apply.call(look)
	_close_cancelled()


## The new-game leave prompt was accepted.
func leave_confirmed() -> void:
	_close_cancelled()


func _close_cancelled() -> void:
	state = State.CANCELLED
	hide()
	cancelled.emit()


## Body turn in radians for the owner.
func turn_angle() -> float:
	return turn * MAX_TURN


func _process(delta: float) -> void:
	if state != State.OPEN:
		return
	var dir := float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A))
	turn_by(dir * TURN_PER_S * delta)


## Turns the body by `share` of MAX_TURN, within -1..1.
func turn_by(share: float) -> void:
	turn = clampf(turn + share, -1.0, 1.0)


func _unhandled_input(event: InputEvent) -> void:
	if state != State.OPEN or not event is InputEventMouseButton or not event.is_pressed():
		return
	var b := (event as InputEventMouseButton).button_index
	if b == MOUSE_BUTTON_WHEEL_UP or b == MOUSE_BUTTON_WHEEL_DOWN:
		leaning = b == MOUSE_BUTTON_WHEEL_UP
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if state != State.OPEN or not event.is_pressed() or event.is_echo():
		return
	var key := (event as InputEventKey).keycode
	var handled := true
	match key:
		KEY_Q:
			select_tab(tab - 1)
		KEY_E:
			select_tab(tab + 1)
		KEY_UP:
			select_row(row - 1)
		KEY_DOWN:
			select_row(row + 1)
		KEY_LEFT:
			change(-1)
		KEY_RIGHT:
			change(1)
		KEY_R:
			randomise()
		KEY_BACKSPACE:
			reset()
		KEY_ENTER, KEY_KP_ENTER:
			confirm()
		KEY_ESCAPE:
			cancel()
		KEY_W:
			leaning = true
		KEY_S:
			leaning = false
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


func _changed() -> void:
	if _apply.is_valid():
		_apply.call(look)
	_refresh()


func _choices(category: String) -> Array:
	if category.begins_with("outfit:"):
		var g: Dictionary = (_cust.outfit as Array)[int(category.substr(7))]
		return range((g.colours as Array).size())
	return Array(Appearance.options(_cust)[category])


func _value(category: String) -> Variant:
	if category.begins_with("outfit:"):
		return int((look.outfit_colours as PackedInt32Array)[int(category.substr(7))])
	return look[category]


func _set_value(category: String, v: Variant) -> void:
	if category.begins_with("outfit:"):
		var colours := PackedInt32Array(look.outfit_colours)
		colours[int(category.substr(7))] = int(v)
		look.outfit_colours = colours
	else:
		look[category] = v


## The text or colour that shows `category`'s current value.
func value_text(category: String) -> String:
	var v: Variant = _value(category)
	var out := ""
	match category:
		"body":
			out = tr("mirror.body_type.n").format({"n": (_cust.body_types as Array).find(v) + 1})
		"build":
			out = tr("mirror.build." + String(v))
		"face":
			out = tr("mirror.face.n").format({"n": int(v) + 1})
		"hair", "facial_hair":
			var list: Array = _cust.hair_styles if category == "hair" else _cust.facial_hair
			out = (
				tr("mirror.hair_none")
				if String(v) == Appearance.NONE
				else tr("mirror.style.n").format({"n": list.find(v)})
			)
		"voice":
			out = tr("mirror.voice." + String(v))
		"voice_pitch":
			out = "%+d" % int(v) if int(v) != 0 else "0"
	return out


func _swatch(category: String) -> Variant:
	var v: Variant = _value(category)
	match category:
		"skin":
			return Color.from_string(String(_cust.skin_tones[int(v)]), Color.WHITE)
		"eye_colour":
			return Color.from_string(String(_cust.eye_colours[int(v)]), Color.WHITE)
		"hair_colour":
			return Color.from_string(String(_cust.hair_colours[int(v)]), Color.WHITE)
	if category.begins_with("outfit:"):
		var g: Dictionary = (_cust.outfit as Array)[int(category.substr(7))]
		return Color.from_string(String(g.colours[int(v)]), Color.WHITE)
	return null


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	panel.anchor_right = 1.0 / 3.0
	panel.anchor_bottom = 1.0
	add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	_tab_bar = HBoxContainer.new()
	box.add_child(_tab_bar)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_rows_box)
	var buttons := HBoxContainer.new()
	box.add_child(buttons)
	for b: Array in [
		["mirror.randomise", randomise],
		["mirror.reset", reset],
		["common.confirm", confirm],
		["common.cancel", cancel],
	]:
		var button := Button.new()
		button.text = b[0]
		button.pressed.connect(b[1])
		buttons.add_child(button)
	_prompt = ConfirmationDialog.new()
	_prompt.title = "mirror.leave.title"
	_prompt.dialog_text = "mirror.leave.body"
	_prompt.ok_button_text = "common.yes"
	_prompt.cancel_button_text = "common.no"
	_prompt.confirmed.connect(leave_confirmed)
	add_child(_prompt)


func _step_row(i: int, step: int) -> void:
	select_row(i)
	change(step)


func _refresh() -> void:
	if _tab_bar == null:
		return
	for c in _tab_bar.get_children():
		c.queue_free()
	for i in tabs.size():
		var t := Button.new()
		t.text = "mirror.tab." + tabs[i]
		t.toggle_mode = true
		t.button_pressed = i == tab
		t.pressed.connect(select_tab.bind(i))
		_tab_bar.add_child(t)
	for c in _rows_box.get_children():
		c.queue_free()
	var list := rows()
	for i in list.size():
		var line := HBoxContainer.new()
		var label := Label.new()
		label.text = list[i][0]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(label)
		var prev := Button.new()
		prev.text = "common.previous"
		prev.pressed.connect(_step_row.bind(i, -1))
		line.add_child(prev)
		var swatch: Variant = _swatch(list[i][1])
		if swatch is Color:
			var rect := ColorRect.new()
			rect.color = swatch
			rect.custom_minimum_size = Vector2(48, 24)
			line.add_child(rect)
		else:
			var value := Label.new()
			value.text = value_text(list[i][1])
			value.custom_minimum_size = Vector2(96, 0)
			line.add_child(value)
		var next := Button.new()
		next.text = "common.next"
		next.pressed.connect(_step_row.bind(i, 1))
		line.add_child(next)
		line.modulate = Color.WHITE if i == row else Color(1, 1, 1, 0.7)
		_rows_box.add_child(line)
