extends Node
## Script of the boot scene: hands over to the title screen. Later steps add
## the renderer check, content loading and pipeline warm-up here.


func _ready() -> void:
	App.show_title.call_deferred()
