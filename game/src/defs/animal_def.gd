class_name AnimalDef
extends RefCounted
## One entry of animals.json (04 §1), built from checked data.

var id: StringName
var name_key: String
## -1 when the animal has no body to hit (fish are caught, not hunted).
var hp: int = -1
var walk_ms: float
var flee_ms: float
var sense_m: float
## run | tree | fly | curl | hole | none
var flee_mode: StringName
## -1 when the flight has no set distance.
var flee_m: float = -1.0
## (from_h, to_h) spans; an end below its start wraps past midnight.
var active_hours: Array[Vector2i] = []
var biomes: Array[StringName] = []
## [{"item", "qty", "chance", "condition"}] (read-only).
var drops: Array = []
var catch: Array[StringName] = []
var max_active_phone: int
var max_active_desktop: int
var scene: String


static func from_dict(d: Dictionary) -> AnimalDef:
	var a := AnimalDef.new()
	a.id = d.id
	a.name_key = d.name_key
	if d.hp != null:
		a.hp = int(d.hp)
	a.walk_ms = _num(d.walk_ms)
	a.flee_ms = _num(d.flee_ms)
	a.sense_m = _num(d.sense_m)
	a.flee_mode = d.flee.mode
	if d.flee.m != null:
		a.flee_m = d.flee.m
	for h: Dictionary in d.active_hours:
		a.active_hours.append(Vector2i(int(h.from), int(h.to)))
	for b: String in d.biomes:
		a.biomes.append(StringName(b))
	a.drops = d.drops
	for c: String in d.catch:
		a.catch.append(StringName(c))
	a.max_active_phone = int(d.max_active_phone)
	a.max_active_desktop = int(d.max_active_desktop)
	a.scene = d.scene
	return a


## Hours of the day the animal is about (wrapping spans counted once).
func active_hours_per_day() -> int:
	var n := 0
	for h in active_hours:
		var span := posmod(h.y - h.x, 24)
		n += span if span != 0 else 24
	return n


static func _num(v: Variant) -> float:
	return 0.0 if v == null else float(v)
