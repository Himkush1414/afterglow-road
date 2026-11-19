extends Control
## Shown at boot when the device has no supported renderer (18 §2, D-22):
## one plain message and a Quit button.

@onready var quit_button: Button = %Quit


func _ready() -> void:
	quit_button.pressed.connect(App.quit)
	quit_button.grab_focus()
