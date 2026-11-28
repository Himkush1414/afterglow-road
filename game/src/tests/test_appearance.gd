extends TestCase
## Appearance (11 §3, §8): defaults, random looks, validation of saved looks,
## and T-11-1: every option of customization.json applied on every body
## scene the data lists, with no missing resource.

var _root: Node3D
var _cust := {}


func before_each() -> void:
	_root = Node3D.new()
	tree.root.add_child(_root)
	var c: Variant = ContentDB.file_data("customization.json")
	_cust = c if c is Dictionary else {}


func after_each() -> void:
	_root.free()


func test_defaults_validate_cleanly_and_round_trip() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var d := Appearance.default_of(_cust)
	var r: Array = Appearance.validated(d, _cust)
	check((r[1] as PackedStringArray).is_empty(), "defaults are valid: %s" % ", ".join(r[1]))
	check_eq(r[0], d, "round trip")


func test_unknown_values_fall_back_with_warnings() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var d := Appearance.default_of(_cust)
	var old := d.duplicate(true)
	old.hair = "no_such_style"
	old.skin = 999
	old.outfit_colours = PackedInt32Array([999])
	var r: Array = Appearance.validated(old, _cust)
	var out: Dictionary = r[0]
	check_eq(out.hair, d.hair, "unknown hair -> default")
	check_eq(out.skin, d.skin, "skin out of range -> default")
	check_eq((r[1] as PackedStringArray).size(), 3, "one warning each: %s" % ", ".join(r[1]))


func test_random_looks_are_valid() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var rng := RandomNumberGenerator.new()
	for seed in 50:
		rng.seed = seed
		var look := Appearance.randomised(_cust, rng)
		var r: Array = Appearance.validated(look, _cust)
		if not check(
			(r[1] as PackedStringArray).is_empty(), "seed %d: %s" % [seed, ", ".join(r[1])]
		):
			return


func _library() -> AnimationLibrary:
	var lib := AnimationLibrary.new()
	for clip: String in PlayerAnimator.clip_names():
		var a := Animation.new()
		a.length = 0.5
		lib.add_animation(clip, a)
	return lib


## T-11-1: every option on every body scene of the data, nothing missing.
func test_every_option_applies_on_every_body() -> void:
	if not check(not _cust.is_empty(), "content has customization data"):
		return
	var scenes: Dictionary = _cust.get("body_scenes", {})
	if scenes.is_empty():
		print("      (no body scenes in this content tree: data-level checks only)")
		return
	var motor := PlayerMotor.new()
	_root.add_child(motor)
	var cam := PlayerCamera.new()
	cam.reads_input = false
	_root.add_child(cam)
	var body := PlayerBody.new()
	_root.add_child(body)
	var mv := ContentDB.tuning("movement")
	motor.setup(mv)
	cam.setup(motor, ContentDB.tuning("camera"))
	var first := load(String(scenes.values()[0])) as PackedScene
	var ok := body.setup(
		motor,
		cam,
		first,
		_library(),
		mv,
		ContentDB.tuning("body"),
		_cust.get("head_segments", []),
		_cust.get("head_meshes", [])
	)
	if not check(ok, ", ".join(body.errors)):
		return
	var options := Appearance.options(_cust)
	var applied := 0
	for body_id: String in _cust.body_types:
		for key: String in options:
			for value: Variant in options[key]:
				var look := Appearance.default_of(_cust)
				look.body = body_id
				look[key] = value
				var missing := body.apply_appearance(look, _cust)
				applied += 1
				if not check(
					missing.is_empty(), "%s %s=%s: %s" % [body_id, key, value, ", ".join(missing)]
				):
					return
				if key == "hair" and String(value) != Appearance.NONE:
					var hair := (
						body.rig.find_child("hair_" + String(value), true, false) as MeshInstance3D
					)
					check(hair.visible, "%s shown" % hair.name)
					check_eq(
						hair.layers,
						PlayerBody.head_layer_mask(),
						"%s on the head layer" % hair.name
					)
	print("      %d looks applied" % applied)
	var eyes := body.rig.find_child("eyes", true, false) as MeshInstance3D
	if eyes != null:
		check_eq(eyes.layers, PlayerBody.head_layer_mask(), "eyes on the head layer")
	for g: Dictionary in _cust.outfit:
		for m in body.rig.find_children(String(g.garment) + "_*", "MeshInstance3D", true, false):
			var under := (
				body.rig.find_child(
					"skin_" + String(m.name).substr(String(g.garment).length() + 1), true, false
				)
				as MeshInstance3D
			)
			if under != null:
				check(not under.visible, "%s hidden under %s" % [under.name, m.name])
