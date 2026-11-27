extends SceneTree
## Writes the retarget import settings of the player body models
## (<root>/assets/models/character/body_*.glb) and the animation sources
## (<root>/assets/anim/*.glb) of one content tree: a BoneMap onto
## SkeletonProfileHumanoid per file (HumanoidBones), saved as
## <root>/assets/anim/bone_maps/<file>.tres, with the importer's rest fixer
## (silhouette fix, global-pose retarget) so the animations of every source
## play on every body. Run `godot --import` afterwards.
## Usage: godot --headless -s res://src/tools/setup_retarget.gd -- <res:// root>
## Prints each file, then RESULT PASS / FAIL.

const OPTIONS := {
	"retarget/rest_fixer/fix_silhouette/enable": true,
	"retarget/rest_fixer/use_global_pose": true,
	"retarget/remove_tracks/unmapped_bones": true,
}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: -- <res:// content root>")
		quit(2)
		return
	var files := PackedStringArray()
	for dir: String in ["assets/models/character", "assets/anim"]:
		var full := args[0].path_join(dir)
		for f in DirAccess.get_files_at(full):
			if f.ends_with(".glb") and (dir.ends_with("anim") or f.begins_with("body_")):
				files.append(full.path_join(f))
	var maps := args[0].path_join("assets/anim/bone_maps")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(maps))
	var ok := not files.is_empty()
	for path in files:
		ok = _setup(path, maps) and ok
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _setup(path: String, maps: String) -> bool:
	var scene: Node = (load(path) as PackedScene).instantiate()
	var skeletons := scene.find_children("*", "Skeleton3D", true, false)
	if skeletons.size() != 1:
		print("%s: %d skeletons" % [path, skeletons.size()])
		return false
	var skel: Skeleton3D = skeletons[0]
	var made: Array = HumanoidBones.bone_map(skel)
	var missing: PackedStringArray = made[1]
	if not missing.is_empty():
		print("%s: required bones not mapped: %s" % [path, ", ".join(missing)])
		return false
	var map_path := maps.path_join(path.get_file().get_basename() + ".tres")
	if ResourceSaver.save(made[0], map_path) != OK:
		print("%s: cannot save %s" % [path, map_path])
		return false
	var cfg := ConfigFile.new()
	if cfg.load(path + ".import") != OK:
		print("%s: no .import file (import the project first)" % path)
		return false
	var node := {"retarget/bone_map": load(map_path)}
	node.merge(OPTIONS)
	cfg.set_value("params", "_subresources", {"nodes": {"PATH:%s" % scene.get_path_to(skel): node}})
	if cfg.save(path + ".import") != OK:
		print("%s: cannot write .import" % path)
		return false
	print("%s: %s mapped" % [path, scene.get_path_to(skel)])
	scene.free()
	return true
