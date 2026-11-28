class_name Warmup
extends Node3D
## Warm-up scene (03 §15.2): one instance of every rendering feature the
## game uses, drawn for a few frames at boot so their pipelines compile
## before play. The environment follows the applied quality preset. Every
## custom shader is drawn once: spatial shaders on a quad in view, the sky
## shader as the sky; a live mirror renders its viewport at the preset's
## size. Later steps add particle systems and effects to SCENES.

const SCENE := "res://scenes/warmup.tscn"
const FRAMES := 2
## Internal scenes drawn during the warm-up (effects).
const SCENES: Array[String] = []
## Every custom shader (tests require each file under res://shaders).
const SHADERS: Array[String] = [
	"res://shaders/body.gdshader",
	"res://shaders/body_double.gdshader",
	"res://shaders/foliage.gdshader",
	"res://shaders/grass.gdshader",
	"res://shaders/impostor.gdshader",
	"res://shaders/mirror.gdshader",
	"res://shaders/outer_ring.gdshader",
	"res://shaders/rock.gdshader",
	"res://shaders/sky.gdshader",
	"res://shaders/terrain.gdshader",
	"res://shaders/water.gdshader",
	"res://shaders/water_desktop.gdshader",
]
const QUAD_M := 0.4
const ROW := 6

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
	_shaders(env)
	_mirror()
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


## A quad per spatial shader in front of the camera; the sky shader as the sky.
func _shaders(env: Environment) -> void:
	var i := 0
	for path in SHADERS:
		var sh := load(path) as Shader
		var mat := ShaderMaterial.new()
		mat.shader = sh
		if sh.get_mode() == Shader.MODE_SKY:
			env.sky.sky_material = mat
			continue
		var quad := MeshInstance3D.new()
		quad.name = "Shader_" + path.get_file().get_basename()
		var mesh := QuadMesh.new()
		mesh.size = Vector2(QUAD_M, QUAD_M)
		quad.mesh = mesh
		quad.material_override = mat
		quad.position = Vector3(
			(i % ROW - (ROW - 1) * 0.5) * QUAD_M * 1.2, 0.8 + (i / ROW) * QUAD_M * 1.2, 1.5
		)
		add_child(quad)
		i += 1


## A live mirror so the mirror viewport's pipelines compile too.
func _mirror() -> void:
	var cfg := ContentDB.tuning("mirror")
	var size: Variant = Quality.value("mirror_size")
	var hz: Variant = Quality.value("mirror_hz")
	if cfg.is_empty():
		return
	var m := Mirror.new()
	m.name = "Mirror"
	m.width_m = 0.6
	m.height_m = 1.2
	add_child(m)
	m.position = Vector3(1.6, 1.0, 0.5)
	if not m.configure(
		cfg, int(size) if size else 256, float(hz) if hz else 60.0, OS.has_feature("mobile")
	):
		m.queue_free()
		return
	m.set_live(true)
	m.update_view($Camera3D.global_position, 0.0)


func _on(key: String) -> bool:
	return Quality.value(key) == true
