extends SceneTree
## Bakes the player clip library of one content tree from the clip preset
## <root>/assetgen/animations.json (22 §5):
##   {"fps": 30, "library": "<path under root>.res",
##    "clips": {"<id>": {"source": "<file in assets/anim>", "from": "<clip>",
##                       "frames": n, "loop": bool,
##                       "window": [start s, end s], "cycles": k}}}
## Each clip is resampled to `frames` keys at `fps` from the source clip
## (imported, retargeted onto the profile skeleton): the window (default
## the whole clip) is stretched over the clip, `cycles` times for loops.
## Writes an AnimationLibrary. Usage:
##   godot --headless -s res://src/tools/bake_animations.gd -- <res:// root>
## Prints each clip, then RESULT PASS / FAIL.

const PRESET := "assetgen/animations.json"
const SOURCE_DIR := "assets/anim"
const TRACK_TYPES: Array[int] = [
	Animation.TYPE_POSITION_3D, Animation.TYPE_ROTATION_3D, Animation.TYPE_SCALE_3D
]

var _scenes: Array[Node] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: -- <res:// content root>")
		quit(2)
		return
	var preset: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(args[0].path_join(PRESET))
	)
	if not preset is Dictionary:
		printerr("%s: missing or not JSON" % PRESET)
		quit(1)
		return
	var fps := float(preset.get("fps", 30))
	var sources := {}
	var library := AnimationLibrary.new()
	var ok := true
	var clips: Dictionary = preset.get("clips", {})
	for id: String in clips:
		var spec: Dictionary = clips[id]
		var src: String = spec.get("source", "")
		if not sources.has(src):
			sources[src] = _source(args[0].path_join(SOURCE_DIR).path_join(src + ".glb"))
		var player: AnimationPlayer = sources[src]
		if player == null or not player.has_animation(String(spec.get("from", ""))):
			print("%s: no clip %s in %s" % [id, spec.get("from", ""), src])
			ok = false
			continue
		var anim := resample(player.get_animation(String(spec.from)), spec, fps)
		library.add_animation(id, anim)
		print("%s: %d frames from %s/%s" % [id, int(spec.frames), src, spec.from])
	var out := args[0].path_join(String(preset.get("library", "")))
	if ok and ResourceSaver.save(library, out) != OK:
		print("cannot save %s" % out)
		ok = false
	for scene in _scenes:
		scene.free()
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _source(path: String) -> AnimationPlayer:
	if not ResourceLoader.exists(path):
		return null
	var scene := (load(path) as PackedScene).instantiate()
	_scenes.append(scene)
	var players := scene.find_children("*", "AnimationPlayer", true, false)
	return players[0] if not players.is_empty() else null


## `src` resampled to spec.frames keys at `fps` (see the file comment).
static func resample(src: Animation, spec: Dictionary, fps: float) -> Animation:
	var frames := int(spec.frames)
	var loop := bool(spec.get("loop", false))
	var window: Array = spec.get("window", [0.0, src.length])
	var a := float(window[0])
	var span := float(window[1]) - a
	var cycles := float(spec.get("cycles", 1))
	var out := Animation.new()
	out.length = frames / fps
	out.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	for t in src.get_track_count():
		var kind := src.track_get_type(t)
		if not TRACK_TYPES.has(kind):
			continue
		var dst := out.add_track(kind)
		out.track_set_path(dst, src.track_get_path(t))
		for k in frames:
			var u := float(k) / frames if loop else float(k) / maxf(1.0, frames - 1)
			var at := a + fmod(u * cycles * span, span) if loop else a + u * span
			var time := k / fps
			match kind:
				Animation.TYPE_POSITION_3D:
					out.position_track_insert_key(dst, time, src.position_track_interpolate(t, at))
				Animation.TYPE_ROTATION_3D:
					out.rotation_track_insert_key(dst, time, src.rotation_track_interpolate(t, at))
				Animation.TYPE_SCALE_3D:
					out.scale_track_insert_key(dst, time, src.scale_track_interpolate(t, at))
	return out
