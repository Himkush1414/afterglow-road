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
## "reverse": true plays it backwards (a backward walk from a forward one).
## "pose_keys": "<set>" adds the key poses of preset["pose_sets"][set]
## (written fallback for clips the sources lack, 02 §3 A-08):
##   {"keys": [{"t": share, "bones": {"<profile bone>": [x, y, z] degrees},
##              "hips": [x, y, z] metres}, ...]}
## rotations about the body's axes (x toward the left hand, y up, z forward:
## the bodies face +Z) at each bone,
## splined (Catmull-Rom, looping) over the clip and applied on top of it;
## "mirror": true swaps Left/Right bones and mirrors across the body's
## middle plane. Writes an AnimationLibrary. Usage:
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
		if bool(spec.get("reverse", false)):
			anim = reversed(anim)
		if spec.has("pose_keys"):
			var sets: Dictionary = preset.get("pose_sets", {})
			if not sets.has(spec.pose_keys):
				print("%s: no pose set %s" % [id, spec.pose_keys])
				ok = false
				continue
			add_pose_keys(
				anim, sets[spec.pose_keys], bool(spec.get("mirror", false)), _rests(player)
			)
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


## Global rest rotation of every bone of the skeleton a source animates.
func _rests(player: AnimationPlayer) -> Dictionary:
	var out := {}
	var skel := player.get_node(player.root_node).find_children("*", "Skeleton3D", true, false)
	if skel.is_empty():
		return out
	var s: Skeleton3D = skel[0]
	for b in s.get_bone_count():
		out[s.get_bone_name(b)] = s.get_bone_global_rest(b).basis.get_rotation_quaternion()
	return out


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


## `anim` played backwards: a loop's key at time τ moves to (length - τ)
## mod length, a one-shot's to (last key time - τ).
static func reversed(anim: Animation) -> Animation:
	var out := anim.duplicate() as Animation
	var loop := anim.loop_mode != Animation.LOOP_NONE
	for t in out.get_track_count():
		var n := anim.track_get_key_count(t)
		if n == 0:
			continue
		var last := anim.track_get_key_time(t, n - 1)
		var keys: Array = []
		for k in n:
			var at := anim.track_get_key_time(t, k)
			var time := fmod(anim.length - at, anim.length) if loop else last - at
			keys.append([time, anim.track_get_key_value(t, k)])
		while out.track_get_key_count(t) > 0:
			out.track_remove_key(t, 0)
		for kv: Array in keys:
			out.track_insert_key(t, kv[0], kv[1])
	return out


## Adds a pose set's key poses on top of `anim` (see the file comment).
## `rests`: global rest rotation per bone of the source skeleton.
static func add_pose_keys(
	anim: Animation, pose_set: Dictionary, mirror: bool, rests: Dictionary
) -> void:
	var keys: Array = pose_set.get("keys", [])
	var bones := {}
	for key: Dictionary in keys:
		for b: String in key.get("bones", {}) as Dictionary:
			bones[_side(b, mirror)] = true
	var fps := 30.0
	var frames := roundi(anim.length * fps)
	for bone: String in bones:
		var path := NodePath("%GeneralSkeleton:" + bone)
		var t := anim.find_track(path, Animation.TYPE_ROTATION_3D)
		if t < 0:
			continue  # a bone the base clip does not move keeps its rest
		var g: Quaternion = rests.get(bone, Quaternion.IDENTITY)
		var src := _side(bone, mirror)  # the key poses are written for the unmirrored side
		for k in frames:
			var time := k / fps
			var e := _spline(
				keys,
				float(k) / frames,
				func(key: Dictionary) -> Vector3:
					var v: Array = (key.get("bones", {}) as Dictionary).get(src, [0, 0, 0])
					return Vector3(v[0], v[1], v[2])
			)
			if mirror:
				e = Vector3(e.x, -e.y, -e.z)
			var world := Quaternion.from_euler(e * (PI / 180.0))
			var local := g.inverse() * world * g
			var base := anim.rotation_track_interpolate(t, time)
			anim.rotation_track_insert_key(t, time, base * local)
	var hips := anim.find_track(NodePath("%GeneralSkeleton:Hips"), Animation.TYPE_POSITION_3D)
	if hips >= 0:
		for k in frames:
			var time := k / fps
			var d := _spline(
				keys,
				float(k) / frames,
				func(key: Dictionary) -> Vector3:
					var v: Array = key.get("hips", [0, 0, 0])
					return Vector3(v[0], v[1], v[2])
			)
			if mirror:
				d.x = -d.x
			anim.position_track_insert_key(
				hips, time, anim.position_track_interpolate(hips, time) + d
			)


## The other side's bone name when mirroring (Left <-> Right), else `bone`.
static func _side(bone: String, mirror: bool) -> String:
	if not mirror:
		return bone
	if bone.begins_with("Left"):
		return "Right" + bone.substr(4)
	if bone.begins_with("Right"):
		return "Left" + bone.substr(5)
	return bone


## Catmull-Rom over the keys' values (key "t" in 0..1, looping) at share u.
static func _spline(keys: Array, u: float, value: Callable) -> Vector3:
	var n := keys.size()
	if n == 0:
		return Vector3.ZERO
	var i := n - 1
	for j in n:
		if float(keys[j].t) > u:
			i = j - 1
			break
	i = posmod(i, n)
	var t0 := float(keys[i].t)
	var t1 := float(keys[(i + 1) % n].t) + (1.0 if i + 1 >= n else 0.0)
	var uu := u + (1.0 if u < t0 else 0.0)
	var f := clampf((uu - t0) / maxf(1e-6, t1 - t0), 0.0, 1.0)
	var p0: Vector3 = value.call(keys[posmod(i - 1, n)])
	var p1: Vector3 = value.call(keys[i])
	var p2: Vector3 = value.call(keys[(i + 1) % n])
	var p3: Vector3 = value.call(keys[(i + 2) % n])
	return (
		0.5
		* (
			2.0 * p1
			+ (p2 - p0) * f
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f * f
			+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * f * f * f
		)
	)
