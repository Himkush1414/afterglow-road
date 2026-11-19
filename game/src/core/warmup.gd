class_name Warmup
extends Node3D
## Warm-up scene (03 §15.2): one instance of every rendering feature the
## game uses, drawn for a few frames at boot so their pipelines compile
## before play. The environment follows the applied quality preset. Later
## steps add their shader quads, particle systems and effects to SCENES.

const SCENE := "res://scenes/warmup.tscn"
const FRAMES := 2
## Internal scenes drawn during the warm-up (custom shaders, effects).
const SCENES: Array[String] = []

@onready var environment: WorldEnvironment = $WorldEnvironment


func _ready() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	env.sky.sky_material = ProceduralSkyMaterial.new()
	env.glow_enabled = true
	env.ssao_enabled = _on("ssao")
	env.ssil_enabled = _on("ssil")
	env.ssr_enabled = _on("water_ssr")
	env.volumetric_fog_enabled = _on("volumetric_fog")
	env.sdfgi_enabled = _on("sdfgi")
	environment.environment = env
	for path in SCENES:
		add_child((load(path) as PackedScene).instantiate())


## Draws the warm-up under `parent` for FRAMES rendered frames, then frees it.
static func run(parent: Node) -> void:
	var w: Warmup = (load(SCENE) as PackedScene).instantiate()
	parent.add_child(w)
	# Headless runs draw nothing, so frame_post_draw never comes there.
	var drawn := DisplayServer.get_name() != "headless"
	for i in FRAMES:
		await parent.get_tree().process_frame
		if drawn:
			await RenderingServer.frame_post_draw
	w.queue_free()


func _on(key: String) -> bool:
	return Quality.value(key) == true
