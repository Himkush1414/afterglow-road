class_name Game
extends Node3D
## Root of game.tscn (03 §3) and typed accessor to its systems. Starts a new
## game or continues a save in `slot`, and registers the save sections of
## the systems it holds.

const SCENE := "res://scenes/game.tscn"
const SLOTS: Array[String] = ["slot_1", "slot_2", "slot_3"]
const CONSOLE_SCENE := "res://ui/debug_console.tscn"

static var current: Game

var slot := ""
var play_seconds := 0.0

@onready var clock: GameClock = $Clock


func _enter_tree() -> void:
	current = self


func _exit_tree() -> void:
	SaveGame.active_slot = ""
	for name: String in ["clock", "ids"]:
		SaveGame.unregister_section(name)
	SaveGame.meta_source = func() -> Dictionary: return {}
	if current == self:
		current = null


func _ready() -> void:
	if App.is_dev():
		$UI.add_child((load(CONSOLE_SCENE) as PackedScene).instantiate())


func _process(delta: float) -> void:
	play_seconds += delta


static func clock_of() -> GameClock:
	return current.clock if current else null


## Prepares the systems for a new game in `slot` and saves it at once.
func start_new(new_slot: String) -> Error:
	_begin(new_slot)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	Rng.save_seed = rng.randi()
	Ids.set_counter(Ids.FIRST_DYNAMIC)
	clock.new_game()
	return SaveGame.save_slot(slot)


## Restores the systems from the save in `new_slot`.
func start_continue(new_slot: String) -> Error:
	_begin(new_slot)
	var meta: Variant = SaveGame.read_meta(slot)
	if meta is Dictionary:
		Rng.save_seed = int(meta.get("save_seed", 0))
		play_seconds = float(meta.get("play_seconds", 0.0))
	return SaveGame.load_slot(slot)


func _begin(new_slot: String) -> void:
	slot = new_slot
	clock.configure(ContentDB.tuning("clock"))
	SaveGame.register_section("clock", clock.save_data, clock.load_data)
	SaveGame.register_section("ids", func() -> Variant: return {"next": Ids.counter()}, _load_ids)
	SaveGame.meta_source = _meta
	SaveGame.active_slot = slot


func _load_ids(data: Variant) -> bool:
	return data is Dictionary and (data.get("next") is int) and Ids.set_counter(data.next)


func _meta() -> Dictionary:
	return {
		"day": clock.day(),
		"clock": "%02d:%02d" % [clock.hour, clock.minute()],
		"play_seconds": int(play_seconds),
		"difficulty": "standard",
		"save_seed": Rng.save_seed,
	}


## Newest slot with a save, or "".
static func newest_slot() -> String:
	var best := ""
	var best_time := ""
	for s in SLOTS:
		var meta: Variant = SaveGame.read_meta(s)
		if meta is Dictionary and str(meta.get("saved_utc", "")) > best_time:
			best = s
			best_time = meta.saved_utc
	return best


## First slot without a save, or "" when all are used.
static func free_slot() -> String:
	for s in SLOTS:
		if not SaveGame.has_save(s):
			return s
	return ""
