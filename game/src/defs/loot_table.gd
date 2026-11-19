class_name LootTable
extends RefCounted
## One table of loot.json (04 §1.4), built from checked data. Each roll
## picks one entry by weight; the entry &"nothing" yields no item.

const NOTHING := &"nothing"

var id: StringName
var rolls: int
## [{"item", "weight", "min", "max"}] (read-only).
var entries: Array = []


static func from_dict(d: Dictionary) -> LootTable:
	var t := LootTable.new()
	t.id = d.id
	t.rolls = int(d.rolls)
	t.entries = d.entries
	return t
