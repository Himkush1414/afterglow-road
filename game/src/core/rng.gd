class_name Rng
extends RefCounted
## Deterministic random streams (03 §7). The world seed comes from the baked
## world; the save seed varies only loot and weather.

## Set when the world loads.
static var world_seed := 0
## Set when a save is created or loaded.
static var save_seed := 0


## Stream for a world-fixed key (tree drops, node drops, animal spawns).
static func for_key(key: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, key])
	return rng


## Stream for a key that also varies per save (loot, weather).
static func for_save_key(key: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([world_seed, save_seed, key])
	return rng
