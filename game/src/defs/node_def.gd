class_name NodeDef
extends RefCounted
## One entry of nodes.json (04 §1), built from checked data.

var id: StringName
var name_key: String
var tool_class: StringName
var min_tier: int
var hp: int
## [{"item", "qty", "chance", "condition"}] (read-only).
var drops: Array = []
var biomes: Array[StringName] = []
## -1 when the node is placed at run time rather than by the generator.
var world_count: int = -1
var respawn_gdays: float
var scene: String


static func from_dict(d: Dictionary) -> NodeDef:
	var n := NodeDef.new()
	n.id = d.id
	n.name_key = d.name_key
	n.tool_class = d.tool_class
	n.min_tier = int(d.min_tier)
	n.hp = int(d.hp)
	n.drops = d.drops
	for b: String in d.biomes:
		n.biomes.append(StringName(b))
	if d.world_count != null:
		n.world_count = int(d.world_count)
	n.respawn_gdays = d.respawn_gdays
	n.scene = d.scene
	return n
