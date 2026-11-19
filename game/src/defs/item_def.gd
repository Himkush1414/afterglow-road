class_name ItemDef
extends RefCounted
## One entry of items.json (04 §1.1), built from checked data.


class Tool:
	extends RefCounted
	var tool_class: StringName
	var tier: int
	var power: float
	var durability: int
	var swing_s: float
	var stamina: float


var id: StringName
var name_key: String
var category: StringName
var stack: int
var weight_kg: float
var material: StringName
var hold: StringName
var held_pose: StringName
var world_scene: String
var icon: String
## null when the item is not a tool.
var tool: Tool
## 0 and &"" when the item does not burn.
var fuel_gmin: float
var fuel_class: StringName
## Sparse effect fields as in the data (read-only); empty when none.
var effect: Dictionary = {}
## Build piece the item deploys, or &"".
var place_piece: StringName


static func from_dict(d: Dictionary) -> ItemDef:
	var it := ItemDef.new()
	it.id = d.id
	it.name_key = d.name_key
	it.category = d.category
	it.stack = int(d.stack)
	it.weight_kg = d.weight_kg
	it.material = d.material
	it.hold = d.hold
	it.held_pose = d.held_pose
	it.world_scene = d.world_scene
	it.icon = d.icon
	if d.tool != null:
		var t := Tool.new()
		t.tool_class = d.tool["class"]
		t.tier = int(d.tool.tier)
		t.power = d.tool.power
		t.durability = int(d.tool.durability)
		t.swing_s = d.tool.swing_s
		t.stamina = d.tool.stamina
		it.tool = t
	if d.fuel != null:
		it.fuel_gmin = d.fuel.gmin
		it.fuel_class = d.fuel["class"]
	if d.effect != null:
		it.effect = d.effect
	if d.place != null:
		it.place_piece = d.place.piece
	return it
