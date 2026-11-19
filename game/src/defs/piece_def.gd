class_name PieceDef
extends RefCounted
## One entry of build_pieces.json (04 §1.3), built from checked data.

var id: StringName
var name_key: String
var category: StringName
var tier: int
var slot: StringName
var size_m: Vector3
## Slots of options; each option is {"item": id, "qty": int} (read-only).
var cost: Array = []
## &"" when no tool is needed.
var tool_class: StringName
var hp: int
## -1 when the piece has no such support value.
var support_base: float = -1.0
var support_v: float = -1.0
var support_h: float = -1.0
var flammable: bool
var stages: int
var blocks_wind: bool
var blocks_rain: bool
var scene: String
var ghost_scene: String


static func from_dict(d: Dictionary) -> PieceDef:
	var p := PieceDef.new()
	p.id = d.id
	p.name_key = d.name_key
	p.category = d.category
	p.tier = int(d.tier)
	p.slot = d.slot
	p.size_m = Vector3(d.size_m[0], d.size_m[1], d.size_m[2])
	p.cost = d.cost
	p.tool_class = d.tool_class
	p.hp = int(d.hp)
	for key: String in ["support_base", "support_v", "support_h"]:
		if d[key] != null:
			p.set(key, float(d[key]))
	p.flammable = d.flammable
	p.stages = int(d.stages)
	p.blocks_wind = d.blocks_wind
	p.blocks_rain = d.blocks_rain
	p.scene = d.scene
	p.ghost_scene = d.ghost_scene
	return p
