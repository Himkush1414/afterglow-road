extends Node
## Autoload "App". Owns the boot sequence and scene changes.

signal scene_shown(path: String)

const TITLE_SCENE := "res://ui/title.tscn"
const LOADING_SCENE := "res://ui/loading_screen.tscn"
const DRESSING_ROOM_SCENE := "res://scenes/dressing_room.tscn"

var current_path := ""
## The slot a new game will use while the dressing room is shown.
var pending_slot := ""
## Instanced once and kept (03 §15.6).
var loading: LoadingScreen


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Log.info("app", "start %s, %s build" % [version(), "dev" if is_dev() else "release"])
	loading = (load(LOADING_SCENE) as PackedScene).instantiate()
	add_child(loading)


## True in the editor and in exports with the "dev" feature tag; debug
## tools exist only then.
func is_dev() -> bool:
	return OS.has_feature("dev") or OS.has_feature("editor")


func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0"))


## Replaces the current scene. Used by every screen change.
func show_scene(path: String) -> Error:
	if not ResourceLoader.exists(path):
		Log.error("app", "no scene at %s" % path)
		return ERR_FILE_NOT_FOUND
	var packed := load(path) as PackedScene
	if packed == null:
		Log.error("app", "cannot load scene %s" % path)
		return ERR_CANT_OPEN
	var err := get_tree().change_scene_to_packed(packed)
	if err != OK:
		Log.error("app", "cannot show scene %s (%s)" % [path, error_string(err)])
		return err
	current_path = path
	await get_tree().scene_changed
	Log.info("app", "scene %s" % path.get_file().get_basename())
	scene_shown.emit(path)
	return OK


func show_title() -> void:
	await show_scene(TITLE_SCENE)


## Quits cleanly: the active slot is saved and running writes finish first.
func quit() -> void:
	SaveGame.flush()
	get_tree().quit()


## New game in `slot`: the dressing room first (11 §5.1) when the content
## has the player body scenes, else straight into the game with the default
## appearance.
func start_character(slot: String) -> Error:
	pending_slot = slot
	if not DressingRoom.can_open():
		return await start_game(slot, true)
	return await show_scene(DRESSING_ROOM_SCENE)


## Shows the game scene and starts a new game in `slot` (or continues it);
## `look`: the appearance chosen for a new game (empty: the default).
func start_game(slot: String, is_new: bool, look: Dictionary = {}) -> Error:
	loading.begin(PackedStringArray([Game.SCENE]))
	if not loading.loader.is_done():
		await loading.scenes_ready
	var err: Error = await show_scene(Game.SCENE)
	if err != OK:
		return err
	err = Game.current.start_new(slot, look) if is_new else Game.current.start_continue(slot)
	if err != OK:
		Log.error("app", "cannot start %s (%s)" % [slot, error_string(err)])
		await show_title()
	return err
