extends TestCase
## TreeShading: the tree shader globals from a `trees` tuning group.

const CFG := {
	"wind_ref_ms": 20.0,
	"bend_exponent": 1.5,
	"height_exponent": 2.0,
	"branch_amp_m": 0.3,
	"branch_rate": 1.5,
	"leaf_amp_m": 0.05,
	"leaf_rate": 8.0,
	"leaf_ref_ms": 7.0,
	"leaf_clamp": [0.1, 1.4],
	"leaf_wave": [3.0, 2.5],
	"flex_m": {"a": 1.25},
	"fade_band_m": 10.0,
	"tint_value": 0.05,
	"tint_hue_rad": 0.04,
}


func test_globals_from_the_tuning_group() -> void:
	check_eq(TreeShading.globals({}, []), {}, "an empty group gives nothing")
	check(not TreeShading.push({}, []), "and pushes nothing")
	var g := TreeShading.globals(CFG, [40, 120, 450, 2400])
	check_eq(g.size(), 13)
	check_eq(g.tree_wind_ref_ms, 20.0)
	check_eq(g.tree_bend_exponent, 1.5)
	check_eq(g.tree_leaf_rate, 8.0)
	check_eq(g.tree_fade_band_m, 10.0)
	check_eq(g.tree_leaf_clamp, Vector2(0.1, 1.4))
	check_eq(g.tree_leaf_wave, Vector2(3.0, 2.5))
	check_eq(g.tree_tint, Vector2(0.05, 0.04))
	check_eq(g.tree_tiers_m, Vector4(40, 120, 450, 2400))
	check(not TreeShading.globals(CFG, []).has("tree_tiers_m"), "no preset, no ranges")
	check(TreeShading.push(CFG, []))


func test_flex_by_species() -> void:
	check_eq(TreeShading.flex(CFG, "a"), 1.25)
	check_eq(TreeShading.flex(CFG, "missing"), 0.0)


func test_visibility_matches_the_hand_over_rule() -> void:
	var tiers := [40.0, 120.0, 450.0, 2400.0]
	check_eq(TreeShading.visibility(0, 10.0, tiers, 12.0), Vector2(1, 1), "T0 near")
	check_eq(TreeShading.visibility(0, 40.0, tiers, 12.0), Vector2(1, 0.5), "T0 at its end")
	check_eq(TreeShading.visibility(1, 40.0, tiers, 12.0), Vector2(0.5, 1), "T1 at its start")
	check_eq(TreeShading.visibility(1, 30.0, tiers, 12.0), Vector2(0, 1), "T1 before its band")
	check_eq(TreeShading.visibility(3, 2500.0, tiers, 12.0), Vector2(1, 0), "T3 past its end")
	var phone := [0.0, 70.0, 260.0, 1400.0]
	check_eq(TreeShading.visibility(0, 5.0, phone, 12.0), Vector2.ZERO, "an empty tier is hidden")
	check_eq(
		TreeShading.visibility(1, 1.0, phone, 12.0), Vector2(1, 1), "T1 from 0 m does not fade in"
	)
