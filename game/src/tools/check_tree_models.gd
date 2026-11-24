extends SceneTree
## Checks the imported tree models of one content tree (22 §7 T-22-3, engine
## side): every <root>/assets/models/trees/tree_*.glb has the meshes _t0, _t1
## and _t2, each with a bark and a leaves surface (or bark only, for leafless
## models), and _t3 (the billboard quad, one surface); all carry vertex
## colours, and the colours arrive unconverted (flutter weight G is 0 on bark
## and billboards and 0.5 or 1.0 on cards, as written by tools/assetgen/trees.py),
## and trunk vertices (bark, branch phase R = 0) have branch distance B = 0.
## Usage: godot --headless -s res://src/tools/check_tree_models.gd -- <res:// root>
## Prints each error, then RESULT PASS / FAIL; exit code 0 / 1.

const MODEL_DIR := "assets/models/trees"
const TIERS: Array[String] = ["t0", "t1", "t2", "t3"]
const SURFACES := 2  # bark, leaves; leafless models have bark only
const TOLERANCE := 0.01


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: -- <res:// content root>")
		quit(2)
		return
	var dir := args[0].path_join(MODEL_DIR)
	var files := PackedStringArray()
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("tree_") and f.ends_with(".glb"):
			files.append(dir.path_join(f))
	var errors := PackedStringArray()
	if files.is_empty():
		errors.append("%s: no tree models" % dir)
	for path in files:
		errors.append_array(check_model(path))
	for e in errors:
		printerr(e)
	print(
		(
			"RESULT %s (%d models, %d errors)"
			% ["PASS" if errors.is_empty() else "FAIL", files.size(), errors.size()]
		)
	)
	quit(0 if errors.is_empty() else 1)


func check_model(path: String) -> PackedStringArray:
	var errors := PackedStringArray()
	var scene := load(path) as PackedScene
	if scene == null:
		return PackedStringArray(["%s: does not load" % path])
	var node := scene.instantiate()
	var meshes := {}
	for child in node.find_children("*", "MeshInstance3D", true, false):
		meshes[String(child.name).get_slice("_", child.name.get_slice_count("_") - 1)] = child
	for tier in TIERS:
		if not meshes.has(tier):
			errors.append("%s: no _%s mesh" % [path, tier])
			continue
		var mesh: Mesh = (meshes[tier] as MeshInstance3D).mesh
		if mesh.get_surface_count() < 1 or mesh.get_surface_count() > SURFACES:
			errors.append(
				(
					"%s _%s: %d surfaces, not 1 or %d"
					% [path, tier, mesh.get_surface_count(), SURFACES]
				)
			)
			continue
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var colors: PackedColorArray = (
				arrays[Mesh.ARRAY_COLOR] if arrays[Mesh.ARRAY_COLOR] != null else PackedColorArray()
			)
			var count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			if colors.size() != count:
				errors.append(
					(
						"%s _%s surface %d: %d colours for %d vertices"
						% [path, tier, s, colors.size(), count]
					)
				)
				continue
			var bad := 0
			var swaying_trunk := 0
			for c in colors:
				# Trunk vertices (bark with branch phase 0) are 0 along the branch.
				if s == 0 and c.r == 0.0 and c.b > TOLERANCE:
					swaying_trunk += 1
				var ok := (
					absf(c.g) < TOLERANCE
					if s == 0
					else (absf(c.g - 0.5) < TOLERANCE or absf(c.g - 1.0) < TOLERANCE)
				)
				if not ok:
					bad += 1
			if bad:
				var where := "%s _%s surface %d" % [path, tier, s]
				errors.append("%s: %d unexpected flutter weights (converted?)" % [where, bad])
			if swaying_trunk:
				var at := "%s _%s" % [path, tier]
				errors.append("%s: %d trunk vertices with a branch distance" % [at, swaying_trunk])
	node.free()
	return errors
