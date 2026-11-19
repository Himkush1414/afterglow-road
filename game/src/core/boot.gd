extends Node
## Script of the boot scene: hands over to the title screen. Later steps add
## the renderer check and pipeline warm-up here.


func _ready() -> void:
	if not ContentDB.is_ok():
		# shortcut: errors go to the log and boot stops; an error screen comes with the menus.
		Log.error("boot", "content has %d errors; stopping" % ContentDB.errors.size())
		get_tree().quit(1)
		return
	Quality.apply(Quality.chosen(), get_viewport())
	App.show_title.call_deferred()
