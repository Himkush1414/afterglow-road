extends TestCase
## Boot: renderer check (03 §15.1) and the "not supported" screen.

const BootScript := preload("res://src/core/boot.gd")


func after_each() -> void:
	await App.show_title()


func test_only_the_vulkan_renderers_are_supported() -> void:
	for method: String in ["forward_plus", "mobile"]:
		check(BootScript.renderer_supported(method), method)
	for method: String in ["gl_compatibility", "dummy", ""]:
		check(not BootScript.renderer_supported(method), method)
	check(BootScript.renderer_supported(RenderingServer.get_current_rendering_method()), "here")


func test_not_supported_screen_shows_keyed_text_and_quit() -> void:
	check_eq(await App.show_scene(BootScript.NOT_SUPPORTED_SCENE), OK)
	var screen := tree.current_scene
	check_eq(screen.tr("err.no_vulkan"), "This device cannot run the game: Vulkan is required.")
	PseudoLocale.enable()
	check_eq(PseudoLocale.raw_texts(screen), PackedStringArray(), "only keyed text")
	PseudoLocale.disable()
	check(screen.quit_button.pressed.is_connected(App.quit), "Quit quits cleanly")
