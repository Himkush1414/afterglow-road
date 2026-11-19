class_name TreeDef
extends RefCounted
## One entry of trees.json (04 §1), built from checked data.

var id: StringName
var name_key: String
var species: StringName
var size: StringName
var height_m: float
var trunk_r_m: float
var canopy_r_m: float
var hp: int
var logs: int
var poles: int
var sticks: int
## [{"item", "qty", "chance", "condition"}] (read-only).
var extra_drops: Array = []
var variants: int
## {"item", "qty", "tool", "cooldown_gday"} (read-only); empty when none.
var harvest: Dictionary = {}
var models: PackedStringArray = []


static func from_dict(d: Dictionary) -> TreeDef:
	var t := TreeDef.new()
	t.id = d.id
	t.name_key = d.name_key
	t.species = d.species
	t.size = d.size
	t.height_m = d.height_m
	t.trunk_r_m = d.trunk_r_m
	t.canopy_r_m = d.canopy_r_m
	t.hp = int(d.hp)
	t.logs = int(d.logs)
	t.poles = int(d.poles)
	t.sticks = int(d.sticks)
	t.extra_drops = d.extra_drops
	t.variants = int(d.variants)
	if d.harvest_no_fell != null:
		t.harvest = d.harvest_no_fell
	t.models = PackedStringArray(d.models)
	return t
