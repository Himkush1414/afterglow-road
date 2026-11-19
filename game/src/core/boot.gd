extends Node
## Script of the boot scene (03 §15): checks content and the renderer, applies
## the quality preset, then hands over to the title screen or to the "not
## supported" screen. The pipeline warm-up is added here by a later step.

const NOT_SUPPORTED_SCENE := "res://ui/not_supported.tscn"
const SUPPORTED_METHODS: Array[String] = ["forward_plus", "mobile"]


func _ready() -> void:
	if not ContentDB.is_ok():
		# shortcut: errors go to the log and boot stops; an error screen comes with the menus.
		Log.error("boot", "content has %d errors; stopping" % ContentDB.errors.size())
		get_tree().quit(1)
		return
	var method := RenderingServer.get_current_rendering_method()
	if not renderer_supported(method):
		Log.error("boot", "rendering method %s is not supported" % method)
		App.show_scene.call_deferred(NOT_SUPPORTED_SCENE)
		return
	Quality.apply(Quality.chosen(), get_viewport())
	App.show_title.call_deferred()


## Only the Vulkan-based renderers run the game (D-22); the compatibility
## renderer is not a fallback.
static func renderer_supported(method: String) -> bool:
	return method in SUPPORTED_METHODS
