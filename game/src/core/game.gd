class_name Game
extends Node3D
## Root of game.tscn (03 §3) and typed accessor to its systems. Starts a new
## game or continues a save in `slot`, and registers the save sections of
## the systems it holds.

const SCENE := "res://scenes/game.tscn"
const SLOTS: Array[String] = ["slot_1", "slot_2", "slot_3"]
const CONSOLE_SCENE := "res://ui/debug_console.tscn"
const PERF_SCENE := "res://ui/perf_overlay.tscn"

static var current: Game

var slot := ""
var play_seconds := 0.0

## Ground cover; configured only when the content has "grass" tuning.
var grass_field: GrassField

@onready var clock: GameClock = $Clock
@onready var weather: Weather = $Weather
@onready var wind: Wind = $Wind
@onready var rain: Rain = $Rain
@onready var lightning: Lightning = $Lightning
@onready var sky_lights: SkyLights = $SkyLights
@onready var sky_dome: SkyDome = $SkyDome
@onready var world: WorldData = $WorldData
@onready var terrain: Terrain = $Terrain
@onready var water: Water = $Water
@onready var outer_ring: OuterRing = $OuterRing
@onready var streamer: Streamer = $Streamer
@onready var tree_field: TreeField = $TreeField


## Ground cover (06 §B): radius, density and level of detail from the
## quality preset, water depth from the water.
func _setup_grass() -> void:
	grass_field = GrassField.new()
	grass_field.name = "GrassField"
	add_child(grass_field)
	var cfg := ContentDB.tuning("grass")
	if cfg.is_empty():
		return
	var radius: Variant = Quality.value("grass_radius_m")
	var density: Variant = Quality.value("grass_density")
	var texture_set: Variant = Quality.value("texture_set")
	if radius != null:
		grass_field.radius_m = float(radius)
	var mult := float(density) if density != null else 1.0
	if grass_field.configure(world, cfg, ContentDB.tuning("terrain"), mult):
		grass_field.depth_of = water.depth_at
		var lod := "lo" if Quality.preset_id.begins_with("phone") else "hi"
		var set_name := String(texture_set) if texture_set != null else "hi"
		grass_field.start(grass_field.load_meshes(ContentDB.root, lod, set_name))
	if not grass_field.errors.is_empty():
		Log.error("grass", "; ".join(grass_field.errors))


func _enter_tree() -> void:
	current = self


func _exit_tree() -> void:
	SaveGame.active_slot = ""
	for name: String in ["clock", "ids", "weather"]:
		SaveGame.unregister_section(name)
	SaveGame.meta_source = func() -> Dictionary: return {}
	SaveGame.region_source = func() -> Dictionary: return {}
	if current == self:
		current = null


func _ready() -> void:
	if not sky_lights.setup(clock, ContentDB.tuning("sky")):
		Log.error("sky", "; ".join(sky_lights.errors))
	else:
		var radiance: Variant = Quality.value("sky_radiance_size")
		var size := 128 if radiance == null else int(radiance)
		if not sky_dome.setup(clock, sky_lights, size, ContentDB.tuning("environment")):
			Log.error("sky", "; ".join(sky_dome.errors))
		weather.sky_dome = sky_dome
		weather.sky_lights = sky_lights
		var forward := RenderingServer.get_current_rendering_method() == "forward_plus"
		sky_dome.volumetric = forward and Quality.value("volumetric_fog") == true
	if not world.load_dir(WorldData.default_dir()):
		Log.error("world", "; ".join(world.errors))
	else:
		if not terrain.setup(world):
			Log.error("terrain", "; ".join(terrain.errors))
		var layers: Array = ContentDB.tuning("terrain").get("layers", [])
		if not outer_ring.setup(world, layers, terrain.layer_means):
			Log.error("outer ring", "; ".join(outer_ring.errors))
		if not water.setup(world):
			Log.error("water", "; ".join(water.errors))
		elif terrain.is_ready():
			water.build(terrain.height_texture())
		streamer.setup(world)
		var trees: Array = ContentDB.ids("trees").map(
			func(id: String) -> Dictionary: return ContentDB.entry("trees", id)
		)
		var tiers: Variant = Quality.value("tree_tiers_m")
		tree_field.t2_shadows = Quality.value("t2_tree_shadows") == true
		var shadow_m: Variant = Quality.value("shadow_distance_m")
		tree_field.shadow_distance_m = float(shadow_m) if shadow_m != null else 0.0
		var sectors: Variant = Quality.value("tree_near_sectors")
		tree_field.near_sectors = int(sectors) if sectors != null else 1
		if not tree_field.setup(
			world, trees, ContentDB.tuning("trees"), tiers if tiers is Array else []
		):
			Log.error("trees", "; ".join(tree_field.errors))
		var leaves := LeafParticles.new()
		leaves.name = "LeafParticles"
		tree_field.add_child(leaves)
		var mult: Variant = Quality.value("particle_mult")
		leaves.setup(
			tree_field,
			world,
			trees,
			wind,
			ContentDB.tuning("trees").get("leaf_particles", {}),
			float(mult) if mult != null else 1.0
		)
		_setup_grass()
		weather.terrain = terrain
		wind.world = world
		rain.world = world
		sky_dome.find_glow_target(world)
		SaveGame.region_source = streamer.deltas
	if App.is_dev():
		var console: DebugConsole = (load(CONSOLE_SCENE) as PackedScene).instantiate()
		var perf: PerfOverlay = (load(PERF_SCENE) as PackedScene).instantiate()
		$UI.add_child(perf)
		$UI.add_child(console)
		console.register(
			"perf", func(_a: PackedStringArray) -> String: return perf.toggle(), "perf"
		)
		console.register("weather", _weather_command, "weather <state>")


## Focus loss and OS pause stop a single-player game behind the pause menu;
## focus loss also saves (an OS pause is saved by SaveGame at once).
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_APPLICATION_PAUSED:
		var menu := get_node_or_null("UI/PauseMenu")
		if menu and not menu.visible:
			menu.open()
		if what == NOTIFICATION_APPLICATION_FOCUS_OUT and slot != "":
			SaveGame.save_slot_async(slot)


func _process(delta: float) -> void:
	play_seconds += delta


static func clock_of() -> GameClock:
	return current.clock if current else null


static func world_of() -> WorldData:
	return current.world if current else null


## Prepares the systems for a new game in `slot` and saves it at once.
func start_new(new_slot: String) -> Error:
	_begin(new_slot)
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	Rng.save_seed = rng.randi()
	Ids.set_counter(Ids.FIRST_DYNAMIC)
	clock.new_game()
	weather.new_game(clock.now_gmin)
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
	if not weather.configure(ContentDB.tuning("weather"), clock):
		Log.error("weather", "; ".join(weather.errors))
	if not wind.configure(ContentDB.tuning("wind")):
		Log.error("wind", "; ".join(wind.errors))
	weather.wind = wind
	if not rain.configure(ContentDB.tuning("rain")):
		Log.error("rain", "; ".join(rain.errors))
	else:
		rain.wind = wind
		var streaks: Variant = Quality.value("rain_streaks")
		if streaks == null:  # no preset applied yet (headless): the chosen one's value
			streaks = (Quality.presets().get(Quality.chosen(), {}) as Dictionary).get(
				"rain_streaks"
			)
		if streaks != null:
			# Mobile: A-17 fallback (no height field collisions).
			var collide := RenderingServer.get_current_rendering_method() == "forward_plus"
			rain.build_volume(int(streaks), collide)
		weather.rain = rain
	if not lightning.configure(ContentDB.tuning("lightning")):
		Log.error("lightning", "; ".join(lightning.errors))
	weather.lightning = lightning
	SaveGame.register_section("ids", func() -> Variant: return {"next": Ids.counter()}, _load_ids)
	SaveGame.register_section("weather", weather.save_data, weather.load_data)
	SaveGame.meta_source = _meta
	SaveGame.active_slot = slot


func _weather_command(args: PackedStringArray) -> String:
	if args.size() != 1 or not weather.force(args[0], clock.now_gmin):
		return "usage: weather <%s>" % "|".join(weather.state_ids())
	return "weather set to %s" % args[0]


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
