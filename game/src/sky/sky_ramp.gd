class_name SkyRamp
extends RefCounted
## The sky colour ramp (08 §2.3): rows by sun elevation, linearly
## interpolated, held at the first and last row beyond the ends. A row
## without a sun colour takes the nearest one above it (or below, at the
## top); a row without a horizon colour toward the sun takes its sun colour.
## Colours are "#RRGGBB" strings in the data and sRGB Colors here.

const COLOURS: Array[String] = ["zenith", "horizon", "horizon_sun", "sun_colour"]
const NUMBERS: Array[String] = ["sun_energy", "ambient_energy"]

var errors: PackedStringArray = []
## Filled rows, sorted by elevation: {elev_deg, zenith, ...} with Colors.
var rows: Array[Dictionary] = []


## Reads the "ramp" list of the sky tuning group. False and `errors` when a
## colour does not parse, elevations do not rise or no row has a sun colour.
func setup(ramp: Array) -> bool:
	errors.clear()
	rows.clear()
	var last := -INF
	for i in ramp.size():
		var src: Dictionary = ramp[i]
		var row := {"elev_deg": float(src.elev_deg)}
		if row.elev_deg <= last:
			errors.append("ramp[%d]: elevations must rise" % i)
		last = row.elev_deg
		for key in COLOURS:
			if src.has(key):
				row[key] = _colour(src[key], "ramp[%d].%s" % [i, key])
		for key in NUMBERS:
			row[key] = float(src[key])
		rows.append(row)
	var given: Array[int] = []
	for i in rows.size():
		if rows[i].has("sun_colour"):
			given.append(i)
	if given.is_empty():
		errors.append("ramp: no row has a sun_colour")
		return false
	for i in rows.size():
		if not rows[i].has("sun_colour"):
			var src: int = given[-1]
			for g in given:
				if g > i:
					src = g
					break
			rows[i].sun_colour = rows[src].sun_colour
		if not rows[i].has("horizon_sun"):
			rows[i].horizon_sun = rows[i].sun_colour
	return errors.is_empty()


## Ramp values at sun elevation `elev_deg`.
func at(elev_deg: float) -> Dictionary:
	if rows.is_empty():
		return {}
	if elev_deg <= rows[0].elev_deg:
		return rows[0].duplicate()
	for i in range(1, rows.size()):
		var b: Dictionary = rows[i]
		if elev_deg <= b.elev_deg:
			var a: Dictionary = rows[i - 1]
			var w: float = (elev_deg - a.elev_deg) / (b.elev_deg - a.elev_deg)
			var out := {"elev_deg": elev_deg}
			for key in COLOURS:
				out[key] = (a[key] as Color).lerp(b[key], w)
			for key in NUMBERS:
				out[key] = lerpf(a[key], b[key], w)
			return out
	return rows[-1].duplicate()


func _colour(value: Variant, path: String) -> Color:
	if value is String and Color.html_is_valid(value) and (value as String).begins_with("#"):
		return Color.html(value)
	errors.append("%s: '%s' is not a #RRGGBB colour" % [path, value])
	return Color.BLACK
