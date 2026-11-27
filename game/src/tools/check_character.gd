extends SceneTree
## Checks the player body models of one content tree (22 §7 T-22-5): every
## <root>/assets/models/character/body_*.glb holds one skeleton with every
## required SkeletonProfileHumanoid bone mapped (HumanoidBones) and the
## forearm twist bones; all bodies have identical skeletons (bone names,
## parents and rest transforms); an eye_marker under the head bone stands at
## the eye height in <root>/assetgen/character.json ± 0.01 m; each body has
## one skinned mesh per segment of the preset (skin_<segment>) and per segment
## of each base-outfit garment (<garment>_<segment>, with a material named
## after the garment), and no other mesh; each mesh with a
## blend shape build_<name> per build of the preset, every build moving some
## vertex of the body by at least 5 mm; and the bodies' meshes differ.
## Usage: godot --headless -s res://src/tools/check_character.gd -- <res:// root>
## Prints each error, then RESULT PASS / FAIL; exit code 0 / 1.

const MODEL_DIR := "assets/models/character"
const PRESET := "assetgen/character.json"
const EYE_TOLERANCE_M := 0.01
const REST_TOLERANCE := 1e-4
const BUILD_MIN_MOVE_M := 0.005
const SKIN_PREFIX := "skin_"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: -- <res:// content root>")
		quit(2)
		return
	var errors := PackedStringArray()
	var preset: Variant = JSON.parse_string(
		FileAccess.get_file_as_string(args[0].path_join(PRESET))
	)
	if not preset is Dictionary:
		errors.append("%s: missing or not JSON" % PRESET)
	var dir := args[0].path_join(MODEL_DIR)
	var files := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("body_") and f.ends_with(".glb"):
			files.append(f)
	files.sort()
	if files.size() < 2:
		errors.append("%s: expected two or more body_*.glb, found %d" % [dir, files.size()])
	var first: Skeleton3D
	var first_vertices := PackedVector3Array()
	for f in files:
		var scene := _load(dir.path_join(f), errors)
		if scene == null:
			continue
		root.add_child(scene)
		var skel := _check_one(f, scene, preset, errors)
		if skel != null:
			var verts := _vertices(scene)
			if first == null:
				first = skel
				first_vertices = verts
			else:
				_compare(f, first, skel, errors)
				if verts == first_vertices:
					errors.append("%s: same mesh as %s" % [f, files[0]])
	for e in errors:
		print(e)
	print("bodies %d, bones %d" % [files.size(), first.get_bone_count() if first else 0])
	print("RESULT %s" % ("PASS" if errors.is_empty() else "FAIL"))
	quit(0 if errors.is_empty() else 1)


func _load(path: String, errors: PackedStringArray) -> Node:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		errors.append("%s: not a readable glTF" % path)
		return null
	return doc.generate_scene(state)


func _check_one(f: String, scene: Node, preset: Variant, errors: PackedStringArray) -> Skeleton3D:
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	if skeletons.size() != 1:
		errors.append("%s: %d skeletons" % [f, skeletons.size()])
		return null
	var skel: Skeleton3D = skeletons[0]
	var missing: PackedStringArray = HumanoidBones.bone_map(skel)[1]
	if not missing.is_empty():
		errors.append("%s: required humanoid bones missing: %s" % [f, ", ".join(missing)])
	for twist: String in HumanoidBones.TWIST:
		var i := skel.find_bone(twist)
		if i < 0 or skel.get_bone_name(skel.get_bone_parent(i)) != HumanoidBones.TWIST[twist]:
			errors.append("%s: %s missing or not under %s" % [f, twist, HumanoidBones.TWIST[twist]])
	var skinned := 0
	var weighted := {}  # bone name -> vertices with weight on it
	for m: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		if m.skin != null and m.get_node_or_null(m.skeleton) == skel:
			skinned += 1
			_count_weights(m, skel, weighted)
	if skinned == 0:
		errors.append("%s: no skinned mesh" % f)
	if preset is Dictionary:
		_check_segments(f, scene, skel, _expected_meshes(preset), errors)
		_check_builds(f, scene, (preset.get("builds", {}) as Dictionary).keys(), errors)
	for twist: String in HumanoidBones.TWIST:
		if int(weighted.get(twist, 0)) == 0:
			errors.append("%s: no vertex weighted to %s" % [f, twist])
	print(
		(
			"%s: twist vertices %s"
			% [
				f,
				str(
					HumanoidBones.TWIST.keys().map(
						func(k: String) -> int: return int(weighted.get(k, 0))
					)
				)
			]
		)
	)
	var markers := scene.find_children("eye_marker", "Node3D", true, false)
	if markers.size() != 1:
		errors.append("%s: %d eye markers" % [f, markers.size()])
	elif preset is Dictionary:
		var y := (markers[0] as Node3D).global_position.y
		var want := float(preset.get("eye_height_m", 0.0))
		if absf(y - want) > EYE_TOLERANCE_M:
			errors.append("%s: eye at %.4f m, want %.2f ± %.2f" % [f, y, want, EYE_TOLERANCE_M])
		else:
			print("%s: eye at %.4f m" % [f, y])
	return skel


## Mesh name -> material name ("" for skin) the preset asks for.
func _expected_meshes(preset: Dictionary) -> Dictionary:
	var out := {}
	for seg: String in preset.get("segments", {}):
		out[SKIN_PREFIX + seg] = ""
	var garments: Dictionary = preset.get("garments", {})
	for g: String in garments:
		for seg: String in (garments[g] as Dictionary).get("segments", []):
			out["%s_%s" % [g, seg]] = g
	return out


## Errors unless the skinned meshes are exactly the expected ones, garments
## carrying their garment's material.
func _check_segments(
	f: String, scene: Node, skel: Skeleton3D, expected: Dictionary, errors: PackedStringArray
) -> void:
	var found := {}
	for m: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		if m.skin == null or m.get_node_or_null(m.skeleton) != skel:
			continue
		var n := String(m.name)
		if found.has(n):
			errors.append("%s: two meshes %s" % [f, n])
		found[n] = true
		if not expected.has(n):
			errors.append("%s: unexpected mesh %s" % [f, n])
		elif expected[n] != "":
			var mat := m.mesh.surface_get_material(0)
			if mat == null or not String(mat.resource_name).begins_with(expected[n]):
				errors.append("%s: %s has no %s material" % [f, n, expected[n]])
	for n: String in expected:
		if not found.has(n):
			errors.append("%s: no mesh %s" % [f, n])


## Errors unless every mesh has a blend shape per build and each build moves
## some vertex of the body by BUILD_MIN_MOVE_M.
func _check_builds(f: String, scene: Node, builds: Array, errors: PackedStringArray) -> void:
	var most := {}
	for m: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		var mesh := m.mesh as ArrayMesh
		if mesh == null:
			continue
		var names := {}
		for k in mesh.get_blend_shape_count():
			names[String(mesh.get_blend_shape_name(k))] = k
		var base: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var shapes := mesh.surface_get_blend_shape_arrays(0)
		var relative := mesh.blend_shape_mode == Mesh.BLEND_SHAPE_MODE_RELATIVE
		for build: String in builds:
			var key := "build_" + build
			if not names.has(key):
				errors.append("%s: %s has no blend shape %s" % [f, m.name, key])
				continue
			var pts: PackedVector3Array = (shapes[names[key]] as Array)[Mesh.ARRAY_VERTEX]
			for i in mini(pts.size(), base.size()):
				var d := pts[i] if relative else pts[i] - base[i]
				most[key] = maxf(float(most.get(key, 0.0)), d.length())
	for build: String in builds:
		var key := "build_" + build
		var m := float(most.get(key, 0.0))
		if m < BUILD_MIN_MOVE_M:
			errors.append("%s: %s moves at most %.4f m" % [f, key, m])
		else:
			print("%s: %s moves up to %.3f m" % [f, key, m])


## Adds to `out` (bone name -> count) the vertices of `m` with a non-zero
## weight on each bone.
func _count_weights(m: MeshInstance3D, skel: Skeleton3D, out: Dictionary) -> void:
	for surface in m.mesh.get_surface_count():
		var arrays := m.mesh.surface_get_arrays(surface)
		var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
		var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
		for k in bones.size():
			if weights[k] <= 0.0:
				continue
			var bind := bones[k]
			var bone := m.skin.get_bind_bone(bind)
			var name := (
				skel.get_bone_name(bone) if bone >= 0 else String(m.skin.get_bind_name(bind))
			)
			out[name] = int(out.get(name, 0)) + 1


func _compare(f: String, a: Skeleton3D, b: Skeleton3D, errors: PackedStringArray) -> void:
	if a.get_bone_count() != b.get_bone_count():
		errors.append("%s: %d bones, first body %d" % [f, b.get_bone_count(), a.get_bone_count()])
		return
	for i in a.get_bone_count():
		var name := a.get_bone_name(i)
		var j := b.find_bone(name)
		if j < 0:
			errors.append("%s: no bone %s" % [f, name])
			continue
		var pa := a.get_bone_parent(i)
		var pb := b.get_bone_parent(j)
		if (pa < 0) != (pb < 0) or (pa >= 0 and a.get_bone_name(pa) != b.get_bone_name(pb)):
			errors.append("%s: bone %s has another parent" % [f, name])
		var ra := a.get_bone_rest(i)
		var rb := b.get_bone_rest(j)
		if not _near(ra, rb):
			errors.append("%s: bone %s rest differs" % [f, name])


func _near(a: Transform3D, b: Transform3D) -> bool:
	if a.origin.distance_to(b.origin) > REST_TOLERANCE:
		return false
	for k in 3:
		if a.basis[k].distance_to(b.basis[k]) > REST_TOLERANCE:
			return false
	return true


func _vertices(scene: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	for m: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		if m.mesh != null and m.mesh.get_surface_count() > 0:
			out.append_array(m.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])
	return out
