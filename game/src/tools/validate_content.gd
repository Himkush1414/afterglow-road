extends SceneTree
## Checks one content tree with ContentDB, as boot does.
## Usage: godot --headless -s res://src/tools/validate_content.gd -- <res:// root>
## Prints each error, then RESULT PASS / FAIL; exit code 0 / 1.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("usage: -- <res:// content root>")
		quit(2)
		return
	# Autoloads are not known when this script is compiled.
	var db: Node = root.get_node("ContentDB")
	var ok: bool = db.load_root(args[0])
	var problems: PackedStringArray = db.text_problems() if ok else PackedStringArray()
	for p in problems:
		printerr("text: " + p)
	ok = ok and problems.is_empty()
	var count: int = db.errors.size() + problems.size()
	print("RESULT %s (%s, %d errors)" % ["PASS" if ok else "FAIL", args[0], count])
	quit(0 if ok else 1)
