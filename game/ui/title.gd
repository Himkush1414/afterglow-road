extends Control
## Title screen (18 §2): Continue (newest save), New game (first free
## slot), Quit. Further entries arrive with their steps.

@onready var continue_button: Button = %Continue
@onready var new_game_button: Button = %NewGame
@onready var quit_button: Button = %Quit


func _ready() -> void:
	continue_button.disabled = Game.newest_slot() == ""
	new_game_button.disabled = Game.free_slot() == ""
	continue_button.pressed.connect(func() -> void: App.start_game(Game.newest_slot(), false))
	new_game_button.pressed.connect(func() -> void: App.start_character(Game.free_slot()))
	quit_button.pressed.connect(App.quit)
	var first := new_game_button if continue_button.disabled else continue_button
	if not first.disabled:
		_focus.call_deferred(first)


## Deferred: the title may already be gone when it runs.
func _focus(button: Button) -> void:
	if button.is_inside_tree():
		button.grab_focus()
