class_name PseudoLocale
extends RefCounted
## Test harness for T-18-7: a pseudo-locale in which the text of every
## known key is wrapped in brackets. With it active, any visible text
## without brackets was not given as a key (hard-coded or missing).

const LOCALE := "zz"
const UI_TABLE := "res://ui/i18n/ui.csv"

static var _translation: Translation
static var _previous := ""


## Builds the pseudo-locale from the source text tables (the interface table
## and the active content tree's tables) and selects it. Imported tables
## cannot list their keys, so the CSV files are read.
static func enable() -> void:
	_translation = Translation.new()
	_translation.locale = LOCALE
	var files: PackedStringArray = [UI_TABLE]
	var text_dir := ContentDB.root.path_join("text")
	if DirAccess.dir_exists_absolute(text_dir):
		for f in DirAccess.get_files_at(text_dir):
			if f.ends_with(".csv"):
				files.append(text_dir.path_join(f))
	for path in files:
		var csv := FileAccess.open(path, FileAccess.READ)
		var header := csv.get_csv_line()
		var en := header.find("en")
		while not csv.eof_reached():
			var row := csv.get_csv_line()
			if row.size() > en and row[0] != "":
				_translation.add_message(row[0], "[%s]" % row[en])
	TranslationServer.add_translation(_translation)
	_previous = TranslationServer.get_locale()
	TranslationServer.set_locale(LOCALE)


static func disable() -> void:
	TranslationServer.set_locale(_previous)
	TranslationServer.remove_translation(_translation)


## "path: shown text" for every visible label, button or line edit under
## `root` whose shown text is not bracketed. Empty text is skipped.
static func raw_texts(root: Node) -> PackedStringArray:
	var out: PackedStringArray = []
	for node: Node in [root] + root.find_children("*", "Control", true, false):
		var c := node as Control
		if c == null or not c.is_visible_in_tree():
			continue
		var text := ""
		if c is Label or c is Button:
			text = c.get("text")
		elif c is LineEdit:
			text = (c as LineEdit).placeholder_text
		if text == "":
			continue
		var shown := (
			c.tr(text) if c.auto_translate_mode != Node.AUTO_TRANSLATE_MODE_DISABLED else text
		)
		if not (shown.begins_with("[") and shown.ends_with("]")):
			out.append("%s: %s" % [root.get_path_to(c), shown])
	return out
