extends Node3D
## T-10-5 (10 §2 rule 4): the first-person camera draws no head-layer pixel,
## while the sun's shadow contains the head. The player body (PlayerBody on
## the given body scene and clip library) stands on a lit plane; its head
## meshes are drawn flat magenta. 20 view poses (5 yaws x 4 pitches,
## alternately standing and crouched) must show no magenta pixel; a control
## pose with the head layer added to the camera's mask must show some (so
## the check can fail); and the ground shadow must change when the head
## meshes are hidden (so the shadow map holds the head).
## Needs a display:
##   tools/godot.sh res://scenes/debug/head_layer_check.tscn -- \
##       --body <res:// body scene> --clips <res:// clip library> [--frames <dir>]
## Prints one line per pose, then RESULT PASS or FAIL (exit 0 or 1).

const YAWS_DEG: Array[float] = [0.0, 72.0, 144.0, 216.0, 288.0]
const PITCHES_DEG: Array[float] = [-80.0, -40.0, 0.0, 60.0]
const SETTLE_FRAMES := 4
## Fewest ground pixels that must change when the head is hidden.
const MIN_SHADOW_PIXELS := 50

var _frames_dir := ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("head layer check: needs a display (run without --headless)")
		get_tree().quit(3)
		return
	var args := PlayerCheckRig.args()
	_frames_dir = String(args.get("frames", ""))
	var rig := PlayerCheckRig.new()
	add_child(rig)
	if not rig.build(args):
		print("setup failed: %s" % ", ".join(rig.errors))
		get_tree().quit(2)
		return
	var cam := rig.cam
	var heads := _head_meshes(rig.body)
	var magenta := StandardMaterial3D.new()
	magenta.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	magenta.albedo_color = Color(1, 0, 1)
	for m in heads:
		m.material_override = magenta
	var failed := heads.is_empty()
	print("head-layer meshes: %d" % heads.size())
	var pose := 0
	for yaw in YAWS_DEG:
		for pitch in PITCHES_DEG:
			rig.motor.crouched = pose % 2 == 1
			cam.yaw = deg_to_rad(yaw)
			cam.pitch = deg_to_rad(pitch)
			var n := _magenta(await rig.shot("pose_%02d" % pose, _frames_dir))
			print(
				(
					"pose %02d yaw %3d pitch %3d %s: %d magenta"
					% [pose, yaw, pitch, "crouch" if rig.motor.crouched else "stand", n]
				)
			)
			failed = failed or n > 0
			pose += 1
	rig.motor.crouched = false
	cam.pitch = deg_to_rad(-80.0)
	cam.cull_mask |= PlayerBody.head_layer_mask()
	var control := _magenta(await rig.shot("control", _frames_dir))
	print("control (camera draws the head layer): %d magenta" % control)
	failed = failed or control == 0
	cam.cull_mask &= ~PlayerBody.head_layer_mask()
	cam.yaw = 0.0
	cam.pitch = deg_to_rad(-25.0)
	var with_head := await rig.shot("shadow_head", _frames_dir)
	for m in heads:
		m.visible = false
	var without := await rig.shot("shadow_no_head", _frames_dir)
	var changed := _changed(with_head, without)
	print(
		"ground pixels changed by hiding the head: %d (need >= %d)" % [changed, MIN_SHADOW_PIXELS]
	)
	failed = failed or changed < MIN_SHADOW_PIXELS
	print("RESULT %s" % ("FAIL" if failed else "PASS"))
	get_tree().quit(1 if failed else 0)


func _head_meshes(body: PlayerBody) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in body.rig.find_children("*", "MeshInstance3D", true, false):
		if (n as MeshInstance3D).layers == PlayerBody.head_layer_mask():
			out.append(n as MeshInstance3D)
	return out


static func _magenta(img: Image) -> int:
	return PlayerCheckRig.count(
		img, func(c: Color) -> bool: return c.r > 0.8 and c.g < 0.25 and c.b > 0.8
	)


static func _changed(a: Image, b: Image) -> int:
	var n := 0
	for y in a.get_height():
		for x in a.get_width():
			var d := a.get_pixel(x, y) - b.get_pixel(x, y)
			if absf(d.r) + absf(d.g) + absf(d.b) > 0.1:
				n += 1
	return n
