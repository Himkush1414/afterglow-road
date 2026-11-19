extends Control
## Pause menu (18 §2): Resume, Save, Quit to title. Opens on the pause
## intent, closes on back or pause; pauses the scene tree (and so the game
## clock) while open. Quit to title saves first. Further entries arrive
## with their steps.

@onready var resume_button: Button = %Resume
@onready var save_button: Button = %Save
@onready var quit_button: Button = %QuitToTitle
@onready var status: Label = %Status


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()
	InputRouter.intent.connect(_on_intent)
	resume_button.pressed.connect(close)
	save_button.pressed.connect(_save)
	quit_button.pressed.connect(_quit_to_title)


func open() -> void:
	status.text = ""
	show()
	get_tree().paused = true
	resume_button.grab_focus()


func close() -> void:
	hide()
	get_tree().paused = false


func _on_intent(name: StringName, kind: StringName) -> void:
	if kind != &"press":
		return
	if name == &"pause" and not visible:
		open()
	elif (name == &"pause" or name == &"back") and visible:
		close()


func _save() -> void:
	var ok := SaveGame.save_slot(Game.current.slot) == OK
	status.text = "ui.pause.saved" if ok else "ui.pause.save_failed"


func _quit_to_title() -> void:
	SaveGame.save_slot(Game.current.slot)
	close()
	App.show_title()
