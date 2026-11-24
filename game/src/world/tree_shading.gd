class_name TreeShading
extends RefCounted
## Shader globals shared by every tree material (06 §A3, §A4): the tree wind
## coefficients and fades from the `trees` tuning group, the tier ranges from
## the quality preset, and the camera position the fades measure from.

const WIND_KEYS := {
	"wind_ref_ms": "tree_wind_ref_ms",
	"bend_exponent": "tree_bend_exponent",
	"height_exponent": "tree_height_exponent",
	"branch_amp_m": "tree_branch_amp_m",
	"branch_rate": "tree_branch_rate",
	"leaf_amp_m": "tree_leaf_amp_m",
	"leaf_rate": "tree_leaf_rate",
	"leaf_ref_ms": "tree_leaf_ref_ms",
	"fade_band_m": "tree_fade_band_m",
}


## The globals for a `trees` tuning group and a preset's tree_tiers_m
## ([T0 end, T1 end, T2 end, T3 end] in metres): {global name: value}.
## Empty when cfg is empty.
static func globals(cfg: Dictionary, tiers_m: Array) -> Dictionary:
	var out := {}
	if cfg.is_empty():
		return out
	for key: String in WIND_KEYS:
		out[WIND_KEYS[key]] = float(cfg[key])
	out["tree_leaf_clamp"] = _vec2(cfg.leaf_clamp)
	out["tree_leaf_wave"] = _vec2(cfg.leaf_wave)
	out["tree_tint"] = Vector2(float(cfg.tint_value), float(cfg.tint_hue_rad))
	if tiers_m.size() == 4:
		out["tree_tiers_m"] = Vector4(
			float(tiers_m[0]), float(tiers_m[1]), float(tiers_m[2]), float(tiers_m[3])
		)
	return out


## Sets globals(cfg, tiers_m). False when cfg is empty.
static func push(cfg: Dictionary, tiers_m: Array) -> bool:
	var g := globals(cfg, tiers_m)
	for key: String in g:
		RenderingServer.global_shader_parameter_set(key, g[key])
	return not g.is_empty()


## Trunk lean at the reference wind (metres at the top) of a species; 0 when
## the species is not listed.
static func flex(cfg: Dictionary, species: String) -> float:
	return float((cfg.get("flex_m", {}) as Dictionary).get(species, 0.0))


## (fade-in, fade-out) visibility of tier k at horizontal distance d: the
## same rule as tree_tier_visibility in tree_fade.gdshaderinc.
static func visibility(k: int, d: float, tiers_m: Array, band_m: float) -> Vector2:
	var start := 0.0 if k == 0 else float(tiers_m[k - 1])
	var end := float(tiers_m[k])
	if end <= start:
		return Vector2.ZERO
	var band := maxf(band_m, 0.001)
	var vin := 1.0 if start <= 0.0 else clampf((d - start) / band + 0.5, 0.0, 1.0)
	var vout := 1.0 - clampf((d - end) / band + 0.5, 0.0, 1.0)
	return Vector2(vin, vout)


static func set_camera(pos: Vector3) -> void:
	RenderingServer.global_shader_parameter_set("tree_camera_pos", pos)


static func _vec2(pair: Array) -> Vector2:
	return Vector2(float(pair[0]), float(pair[1]))
