class_name RecipeDef
extends RefCounted
## One entry of recipes.json (04 §1.2), built from checked data.

var id: StringName
var output: StringName
var qty: int
## &"hand" or a build piece id.
var station: StringName
## Any one of these tool classes is needed; empty = none.
var tool_classes: Array[StringName] = []
## Slots of options; each option is {"item": id, "qty": int} (read-only).
var inputs: Array = []
var time: float
var time_unit: StringName
## Any one entry unlocks: "start", "item:<id>", "station:<id>".
var unlock: PackedStringArray = []
## [{"item": id, "qty": int}] (read-only).
var byproducts: Array = []


static func from_dict(d: Dictionary) -> RecipeDef:
	var r := RecipeDef.new()
	r.id = d.id
	r.output = d.output
	r.qty = int(d.qty)
	r.station = d.station
	for t: String in d.tool_class:
		r.tool_classes.append(StringName(t))
	r.inputs = d.inputs
	r.time = d.time
	r.time_unit = d.time_unit
	r.unlock = PackedStringArray(d.unlock)
	r.byproducts = d.byproducts
	return r
