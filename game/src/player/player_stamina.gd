class_name PlayerStamina
extends Node
## Stamina (10 §4.1, 13): 0..max. Swimming drains it (more while moving);
## after regen_delay_s without drain it regenerates; swimming at 0 deals
## drowning damage every tick (`drown_damage`, applied by Vitals). Sprint,
## jump and mantle costs, the limits at 0 and the regeneration multipliers
## hook in through `spend` and `regen_mult` (P6-10). Runs each physics tick
## after the motor. Numbers: the "stamina" tuning group.

## Drowning damage of this tick, in HP (swimming at 0 stamina).
signal drown_damage(hp: float)

const KEYS: Array[String] = [
	"max", "swim_move_ps", "swim_still_ps", "regen_ps", "regen_delay_s", "drown_hp_ps"
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
	return true


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
	if rate > 0.0:
		value = maxf(0.0, value - rate * delta)
		_since_drain_s = 0.0
	else:
		_since_drain_s += delta
		if _since_drain_s >= float(_cfg.regen_delay_s):
			value = minf(max_value, value + float(_cfg.regen_ps) * regen_mult * delta)
	drowning = motor.is_swimming() and value <= 0.0
	if drowning:
		drown_damage.emit(float(_cfg.drown_hp_ps) * delta)
