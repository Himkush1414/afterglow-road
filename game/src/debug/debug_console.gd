class_name DebugConsole
extends Control
## Developer console (03 §14), present in dev builds only. Systems add
## commands with `register`; `run` parses one line and returns the reply.
## Opens and closes on the console intent; works while the game is paused.

const TIME_USAGE := "time <hh:mm>"

## name -> {"call": Callable(PackedStringArray) -> String, "usage": String}
var _commands := {}

@onready var output: Label = %Output
@onready var line: LineEdit = %Line


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	hide()
	InputRouter.intent.connect(_on_intent)
	line.text_submitted.connect(_submit)
	register("help", _help, "help")
	register("time", _time, TIME_USAGE)
	register("save", _save, "save")
	register("load", _load, "load")


## Adds command `name`; `call(args)` returns the reply. False if taken.
func register(name: String, call: Callable, usage: String) -> bool:
	if _commands.has(name):
		return false
	_commands[name] = {"call": call, "usage": usage}
	return true


## Runs one command line and returns the reply.
func run(text: String) -> String:
	var words := text.strip_edges().split(" ", false)
	if words.is_empty():
		return ""
	var cmd: Dictionary = _commands.get(words[0], {})
	if cmd.is_empty():
		return "unknown command '%s' (help lists them)" % words[0]
	return (cmd.call as Callable).call(words.slice(1))


func _on_intent(name: StringName, kind: StringName) -> void:
	if name != &"console" or kind != &"press":
		return
	visible = not visible
	if visible:
		line.grab_focus()


func _submit(text: String) -> void:
	output.text += "> %s\n%s\n" % [text, run(text)]
	line.clear()


func _help(_args: PackedStringArray) -> String:
	var usages: PackedStringArray = []
	for name: String in _commands:
		usages.append(_commands[name].usage)
	return ", ".join(usages)


func _time(args: PackedStringArray) -> String:
	var parts := args[0].split(":") if args.size() == 1 else PackedStringArray()
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return "usage: " + TIME_USAGE
	var h := parts[0].to_int()
	var m := parts[1].to_int()
	if h < 0 or h > 23 or m < 0 or m > 59:
		return "usage: " + TIME_USAGE
	var clock := Game.clock_of()
	clock.set_now(
		floorf(clock.now_gmin / GameClock.GMIN_PER_DAY) * GameClock.GMIN_PER_DAY + h * 60 + m
	)
	return "time set to day %d, %02d:%02d" % [clock.day(), clock.hour, clock.minute()]


func _save(_args: PackedStringArray) -> String:
	var err := SaveGame.save_slot(Game.current.slot)
	return "saved %s" % Game.current.slot if err == OK else "save failed: %s" % error_string(err)


func _load(_args: PackedStringArray) -> String:
	var slot := Game.current.slot
	App.start_game.call_deferred(slot, false)
	return "loading %s" % slot
