class_name PlayerStamina
extends Node
## Stamina (10 §4.1, 13): 0..max. Sprinting and swimming drain it per
## second (swimming more while moving), a jump and a mantle cost a fixed
## amount; after regen_delay_s without drain it regenerates, times the
## vitals multiplier. At 0 the motor may not sprint or jump until stamina is
## back at recover_at; swimming at 0 deals drowning damage every tick
## (`drown_damage`, applied by Vitals). Vitals report hunger, thirst, warmth
## and rest through `apply_vitals`. Runs each physics tick after the motor.
## Numbers: the "stamina" tuning group.

## Drowning damage of this tick, in HP (swimming at 0 stamina).
signal drown_damage(hp: float)

const KEYS: Array[String] = [
	"max",
	"swim_move_ps",
	"swim_still_ps",
	"regen_ps",
	"regen_delay_s",
	"drown_hp_ps",
	"sprint_ps",
	"jump_cost",
	"mantle_cost",
	"recover_at",
	"low_hunger",
	"low_thirst",
	"low_warmth",
	"low_rest",
	"low_mult",
	"min_mult",
	"tired_max",
]
## Horizontal speed (m/s) above which a swimmer counts as moving.
const MOVING_MS := 0.1

var errors: PackedStringArray = []
var motor: PlayerMotor
var value := 0.0
var max_value := 0.0
## Regeneration multiplier from hunger, thirst, warmth and rest (13 §3).
var regen_mult := 1.0
var drowning := false
## At 0 until back at recover_at: no sprint, no jump.
var exhausted := false

var _cfg := {}
var _since_drain_s := 0.0


## Follows `body` with the "stamina" tuning group; starts full.
func setup(body: PlayerMotor, cfg: Dictionary) -> bool:
	errors.clear()
	for key in KEYS:
		if not cfg.has(key):
			errors.append("stamina: missing %s" % key)
	if body == null:
		errors.append("stamina: no motor")
	if not errors.is_empty():
		return false
	motor = body
	_cfg = cfg
	max_value = float(cfg.max)
	value = max_value
	process_physics_priority = motor.process_physics_priority + 1
	if not motor.jumped.is_connected(_on_jumped):
		motor.jumped.connect(_on_jumped)
		motor.mantle_started.connect(_on_mantle)
	return true


## Regeneration multiplier and maximum from the vitals (13 §3): each of
## hunger, thirst, warmth, rest below its threshold halves regeneration
## (together never below min_mult); low rest also caps stamina at tired_max.
func apply_vitals(hunger: float, thirst: float, warmth: float, rest: float) -> void:
	var m := 1.0
	var low := float(_cfg.low_mult)
	for pair: Array in [
		[hunger, _cfg.low_hunger],
		[thirst, _cfg.low_thirst],
		[warmth, _cfg.low_warmth],
		[rest, _cfg.low_rest]
	]:
		if float(pair[0]) < float(pair[1]):
			m *= low
	regen_mult = maxf(m, float(_cfg.min_mult))
	max_value = float(_cfg.tired_max if rest < float(_cfg.low_rest) else _cfg.max)
	value = minf(value, max_value)


func _on_jumped() -> void:
	spend(float(_cfg.jump_cost))


func _on_mantle(_rise_m: float) -> void:
	spend(float(_cfg.mantle_cost))


## Takes `amount` at once (sprint, jump, mantle: P6-10); counts as drain.
func spend(amount: float) -> void:
	value = maxf(0.0, value - amount)
	_since_drain_s = 0.0


func _physics_process(delta: float) -> void:
	if motor != null:
		tick(delta)


## One physics tick of `delta` seconds.
func tick(delta: float) -> void:
	var rate := 0.0
	if motor.is_swimming():
		var flat := Vector2(motor.velocity.x, motor.velocity.z).length()
		rate = float(_cfg.swim_move_ps if flat > MOVING_MS else _cfg.swim_still_ps)
	elif motor.sprinting:
		rate = float(_cfg.sprint_ps)
	if rate > 0.0:
		value = maxf(0.0, value - rate * delta)
		_since_drain_s = 0.0
	else:
		_since_drain_s += delta
		if _since_drain_s >= float(_cfg.regen_delay_s):
			value = minf(max_value, value + float(_cfg.regen_ps) * regen_mult * delta)
	if value <= 0.0:
		exhausted = true
	elif exhausted and value >= float(_cfg.recover_at):
		exhausted = false
	motor.sprint_allowed = not exhausted
	motor.jump_allowed = not exhausted
	drowning = motor.is_swimming() and value <= 0.0
	if drowning:
		drown_damage.emit(float(_cfg.drown_hp_ps) * delta)
