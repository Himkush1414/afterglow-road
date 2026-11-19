class_name MaterialDef
extends RefCounted
## One entry of materials.json (04 §1), built from checked data.

var id: StringName
var density_kg_m3: float
var flammable: bool
var ignite_s: float
var burn_gmin_per_kg: float
## Damage factor per tool class (chop, mine, cut, hammer, dig).
var tool_factor: Dictionary[StringName, float] = {}
var impact_break_j: float
var footstep: StringName
var impact_sound: StringName
var hit_particles: StringName


static func from_dict(d: Dictionary) -> MaterialDef:
	var m := MaterialDef.new()
	m.id = d.id
	m.density_kg_m3 = d.density_kg_m3
	m.flammable = d.flammable
	m.ignite_s = d.ignite_s
	m.burn_gmin_per_kg = d.burn_gmin_per_kg
	for c: String in ["chop", "mine", "cut", "hammer", "dig"]:
		m.tool_factor[StringName(c)] = float(d[c])
	m.impact_break_j = d.impact_break_j
	m.footstep = d.footstep
	m.impact_sound = d.impact_sound
	m.hit_particles = d.hit_particles
	return m
