extends TestCase
## New-game appearance (11 §5, §9): the chosen look is saved with the new
## game and survives continue (T-11-2 without the opening); while the
## dressing room is shown, every 3D camera is the player's eye or a mirror
## camera (T-11-7).

const DIR := "user://tests/dressing_saves"


func before_each() -> void:
	_wipe(DIR)
	SaveGame.saves_dir = DIR


func after_each() -> void:
	await App.show_title()
	SaveGame.saves_dir = SaveGame.SAVES_DIR
	_wipe(DIR)


func test_chosen_look_is_saved_with_the_new_game() -> void:
	var c: Variant = ContentDB.file_data("customization.json")
	if not check(c is Dictionary, "content has customization data"):
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var look := Appearance.randomised(c, rng)
	check_eq(await App.start_game("slot_1", true, look), OK)
	check_eq(Game.current.player_look, look, "the game holds the chosen look")
	await App.show_title()
	check_eq(await App.start_game("slot_1", false), OK)
	check_eq(Game.current.player_look, look, "saved and restored (T-11-2)")


func test_only_eye_and_mirror_cameras_in_the_dressing_room() -> void:
	if not DressingRoom.can_open():
		print("      (no body scenes in this content tree: room not built)")
		return
	App.pending_slot = "slot_2"
	check_eq(await App.show_scene(App.DRESSING_ROOM_SCENE), OK)
	var room := tree.current_scene as DressingRoom
	if not check(
		room != null and room.errors.is_empty(), "room built: %s" % ", ".join(room.errors)
	):
		return
	for f in 3:
		await tree.process_frame
	for cam: Camera3D in tree.root.find_children("*", "Camera3D", true, false):
		var mirror_cam := (
			cam.get_parent() is SubViewport and cam.get_parent().get_parent() is Mirror
		)
		check(cam == room.cam or mirror_cam, "camera %s is the eye or a mirror camera" % cam.name)
	check_eq(
		room.get_viewport().get_camera_3d(), room.cam, "the view renders from the eye (T-11-7)"
	)
	check(room.mirror.live, "the mirror is live")
	check_eq(room.screen.state, MirrorScreen.State.OPEN, "screen open")


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for sub in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(sub))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
