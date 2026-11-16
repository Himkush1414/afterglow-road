extends SceneTree
## Renders a scene and saves one PNG. Used by tools/screenshot/shot.sh.
##   -- --scene <res path> --out <png path> [--frames N]
## The scene may define capture_ready() -> bool; frames are rendered until it
## returns true (or N frames have passed), then the image is taken.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path := _arg(args, "--scene", "")
	var out := _arg(args, "--out", "")
	var frames := int(_arg(args, "--frames", "30"))
	if scene_path == "" or out == "":
		printerr("screenshot: --scene and --out are required")
		quit(2)
		return
	if DisplayServer.get_name() == "headless":
		printerr("screenshot: needs a display (run without --headless)")
		quit(3)
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		printerr("screenshot: cannot load %s" % scene_path)
		quit(2)
		return
	var node := packed.instantiate()
	root.add_child(node)
	for i in frames:
		await process_frame
		if node.has_method("capture_ready") and node.call("capture_ready"):
			break
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var err := img.save_png(out)
	print(
		(
			"screenshot: %s (%dx%d, %s, %s) -> %s"
			% [
				scene_path,
				img.get_width(),
				img.get_height(),
				RenderingServer.get_current_rendering_method(),
				RenderingServer.get_video_adapter_name(),
				error_string(err)
			]
		)
	)
	quit(0 if err == OK else 1)


func _arg(args: PackedStringArray, key: String, fallback: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else fallback
