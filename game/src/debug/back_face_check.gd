extends Node3D
## T-10-8 (10 §2 rule 3): looking down at -80 degrees shows the body and no
## back face or interior polygon. Every body surface draws its debug face
## colour (front green, back red, unlit); 8 yaws, standing and crouched,
## must show green pixels and no red pixel. A control that lets double-sided
## surfaces show their back faces to the first-person camera must show red,
## so the check can fail.
## Needs a display:
##   tools/godot.sh res://scenes/debug/back_face_check.tscn -- \
##       --body <res:// body scene> --clips <res:// clip library> [--frames <dir>]
## Prints one line per pose, then RESULT PASS or FAIL (exit 0 or 1).

const PITCH_DEG := -80.0
const YAW_STEPS := 8
## Fewest body (green) pixels a pose must show.
const MIN_BODY_PIXELS := 500

var _frames_dir := ""


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("back face check: needs a display (run without --headless)")
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
	var mats := _materials(rig.body)
	for m in mats:
		m.set_shader_parameter("debug_faces", true)
	rig.cam.pitch = deg_to_rad(PITCH_DEG)
	# Control first, standing at yaw 0 (later poses change the animation).
	for m in mats:
		m.set_shader_parameter("back_faces_first_person", true)
	var control := _red(await rig.shot("control", _frames_dir))
	print("control (back faces shown in first person): %d back" % control)
	var failed := control == 0
	for m in mats:
		m.set_shader_parameter("back_faces_first_person", false)
	for i in YAW_STEPS * 2:
		rig.motor.crouched = i >= YAW_STEPS
		rig.cam.yaw = TAU * float(i % YAW_STEPS) / YAW_STEPS
		var img := await rig.shot("pose_%02d" % i, _frames_dir)
		var red := _red(img)
		var green := _green(img)
		print(
			(
				"pose %02d yaw %3d %s: %d front, %d back"
				% [
					i,
					roundi(rad_to_deg(rig.cam.yaw)),
					"crouch" if rig.motor.crouched else "stand",
					green,
					red
				]
			)
		)
		failed = failed or red > 0 or green < MIN_BODY_PIXELS
	print("RESULT %s" % ("FAIL" if failed else "PASS"))
	get_tree().quit(1 if failed else 0)


func _materials(body: PlayerBody) -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for n in body.rig.find_children("*", "MeshInstance3D", true, false):
		var mesh := n as MeshInstance3D
		for s in mesh.mesh.get_surface_count():
			var m := mesh.get_surface_override_material(s) as ShaderMaterial
			if m != null:
				out.append(m)
	return out


static func _red(img: Image) -> int:
	return PlayerCheckRig.count(
		img, func(c: Color) -> bool: return c.r > 0.5 and c.g < 0.2 and c.b < 0.2
	)


static func _green(img: Image) -> int:
	return PlayerCheckRig.count(
		img, func(c: Color) -> bool: return c.g > 0.5 and c.r < 0.2 and c.b < 0.2
	)
