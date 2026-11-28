class_name Appearance
extends RefCounted
## The player's look (11 §3, 04 §3.2): a Dictionary with body, build, skin,
## face, hair, hair_colour, eye_colour, facial_hair, outfit_colours (one
## index per garment of the customization data's outfit list), voice and
## voice_pitch. Every option comes from customization.json (`cust`); these
## helpers make defaults, random looks and checked copies of saved looks.

const NONE := "none"
const KEYS: Array[String] = [
	"body",
	"build",
	"skin",
	"face",
	"hair",
	"hair_colour",
	"eye_colour",
	"facial_hair",
	"outfit_colours",
	"voice",
	"voice_pitch",
]


## The data's default look ("Reset").
static func default_of(cust: Dictionary) -> Dictionary:
	var src: Dictionary = cust.defaults
	var d := {}
	for key: String in ["body", "build", "hair", "facial_hair", "voice"]:
		d[key] = String(src.get(key, ""))
	for key: String in ["skin", "face", "hair_colour", "eye_colour", "voice_pitch"]:
		d[key] = int(src.get(key, 0))
	d.outfit_colours = PackedInt32Array(src.get("outfit_colours", []))
	return d


## A random look ("Randomise"): every category picked with `rng`.
static func randomised(cust: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var colours := PackedInt32Array()
	for g: Dictionary in cust.outfit:
		colours.append(rng.randi_range(0, (g.colours as Array).size() - 1))
	var pitch: Array = cust.voice_pitch
	return {
		"body": _pick(cust.body_types, rng),
		"build": _pick((cust.builds as Dictionary).keys(), rng),
		"skin": rng.randi_range(0, (cust.skin_tones as Array).size() - 1),
		"face": rng.randi_range(0, int(cust.faces) - 1),
		"hair": _pick(cust.hair_styles, rng),
		"hair_colour": rng.randi_range(0, (cust.hair_colours as Array).size() - 1),
		"eye_colour": rng.randi_range(0, (cust.eye_colours as Array).size() - 1),
		"facial_hair": _pick(cust.facial_hair, rng),
		"outfit_colours": colours,
		"voice": _pick(cust.voices, rng),
		"voice_pitch": rng.randi_range(int(pitch[0]), int(pitch[1])),
	}


## [checked look, warnings]: every unknown or out-of-range value of `look`
## is replaced by the default (11 §8: old saves, missing assets).
static func validated(look: Dictionary, cust: Dictionary) -> Array:
	var out := default_of(cust)
	var warnings: PackedStringArray = []
	var pitch: Array = cust.voice_pitch
	var choices := {
		"body": cust.body_types,
		"build": (cust.builds as Dictionary).keys(),
		"hair": cust.hair_styles,
		"facial_hair": cust.facial_hair,
		"voice": cust.voices,
	}
	for key: String in choices:
		if look.has(key):
			if String(look[key]) in (choices[key] as Array):
				out[key] = String(look[key])
			else:
				warnings.append(
					"appearance: unknown %s '%s', using '%s'" % [key, look[key], out[key]]
				)
	var counts := {
		"skin": (cust.skin_tones as Array).size(),
		"face": int(cust.faces),
		"hair_colour": (cust.hair_colours as Array).size(),
		"eye_colour": (cust.eye_colours as Array).size(),
	}
	for key: String in counts:
		if look.has(key):
			var v := int(look[key])
			if v >= 0 and v < int(counts[key]):
				out[key] = v
			else:
				warnings.append("appearance: %s %d out of range, using %d" % [key, v, out[key]])
	if look.has("voice_pitch"):
		var p := int(look.voice_pitch)
		if p >= int(pitch[0]) and p <= int(pitch[1]):
			out.voice_pitch = p
		else:
			warnings.append("appearance: voice_pitch %d out of range" % p)
	if look.has("outfit_colours"):
		var given: Array = Array(look.outfit_colours)
		var colours := PackedInt32Array(out.outfit_colours)
		var outfit: Array = cust.outfit
		colours.resize(outfit.size())
		for i in outfit.size():
			var n := ((outfit[i] as Dictionary).colours as Array).size()
			if i < given.size() and int(given[i]) >= 0 and int(given[i]) < n:
				colours[i] = int(given[i])
			elif i < given.size():
				warnings.append("appearance: outfit colour %d out of range" % i)
		out.outfit_colours = colours
	return [out, warnings]


## Every value each category offers, for checks that try them all (T-11-1).
static func options(cust: Dictionary) -> Dictionary:
	var pitch: Array = cust.voice_pitch
	return {
		"body": cust.body_types,
		"build": (cust.builds as Dictionary).keys(),
		"skin": range((cust.skin_tones as Array).size()),
		"face": range(int(cust.faces)),
		"hair": cust.hair_styles,
		"hair_colour": range((cust.hair_colours as Array).size()),
		"eye_colour": range((cust.eye_colours as Array).size()),
		"facial_hair": cust.facial_hair,
		"voice": cust.voices,
		"voice_pitch": range(int(pitch[0]), int(pitch[1]) + 1),
	}


static func _pick(values: Array, rng: RandomNumberGenerator) -> String:
	return String(values[rng.randi_range(0, values.size() - 1)])
