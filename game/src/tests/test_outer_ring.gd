extends TestCase
## OuterRing: mesh layout (cells outside the map, skirt), colours by height
## band and slope, layer means, and setup on the real and sample worlds.

const RED := Color(1.0, 0.0, 0.0)
const BLUE := Color(0.0, 0.0, 1.0)
const GREY := Color(0.5, 0.5, 0.5)


func _flat(n: int, y: float) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	h.resize(n * n)
	h.fill(y)
	return h


func test_the_full_grid_has_the_planned_triangles() -> void:
	var shape := {
		"n": OuterRing.CELLS + 1,
		"cell_m": OuterRing.CELL_M,
		"lo_m": OuterRing.LO_M,
		"map_m": 8192.0,
		"origin": 8192.0 * 0.5,
		"skirt_m": 16.0
	}
	var mesh := OuterRing.build_mesh(_flat(OuterRing.CELLS + 1, 10.0), shape, [], [])
	var tris := mesh.surface_get_array_index_len(0) / 3
	# (160^2 - 64^2) cells x 2, plus 256 inner edges x 2 quads x 2 triangles
	check_eq(tris, 43008 + 1024, "cells outside the map and the skirt")


func test_small_grid_layout_and_skirt() -> void:
	# 4 x 4 cells of 100 m from -100: the map (0..200) covers the middle 2 x 2
	var shape := {
		"n": 5, "cell_m": 100.0, "lo_m": -100.0, "map_m": 200.0, "origin": 100.0, "skirt_m": 5.0
	}
	var mesh := OuterRing.build_mesh(_flat(5, 3.0), shape, [], [])
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check_eq(verts[0], Vector3(-200.0, 3.0, -200.0), "first vertex in engine coordinates")
	check_eq(verts[24], Vector3(200.0, 3.0, 200.0), "last grid vertex")
	check_eq(idx.size() / 3, (16 - 4) * 2 + 8 * 4, "12 cells and 8 skirt edges")
	var lowest := INF
	for v in verts:
		lowest = minf(lowest, v.y)
	check_eq(lowest, -2.0, "the skirt hangs 5 m below the edge")
	for t in range(0, 24 * 3, 3):  # no grid triangle has all corners strictly inside the map
		var inside := true
		for k in 3:
			var v := verts[idx[t + k]]
			inside = inside and absf(v.x) < 100.0 + 1e-3 and absf(v.z) < 100.0 + 1e-3
		check(not inside, "triangle %d is outside the map" % (t / 3))


func test_colour_by_height_band_then_slope() -> void:
	var bands := [[2.5, RED], [600.0, GREY]]
	var slopes := [[30.0, BLUE]]
	check_eq(OuterRing.colour_at(1.0, 5.0, bands, slopes), RED, "low and flat")
	check_eq(OuterRing.colour_at(100.0, 5.0, bands, slopes), GREY, "middle band")
	check_eq(OuterRing.colour_at(100.0, 31.0, bands, slopes), BLUE, "steep overrides")
	check_eq(
		OuterRing.colour_at(900.0, 5.0, bands, slopes),
		OuterRing.FALLBACK.srgb_to_linear(),
		"above every band"
	)


func test_mean_colour_is_the_mean_albedo() -> void:
	var a := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	a.fill(Color8(200, 100, 50))
	var b := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in 8:
			b.set_pixel(x, y, Color8(0, 0, 0) if (x + y) % 2 == 0 else Color8(255, 255, 255))
	b.generate_mipmaps()
	check(OuterRing.mean_colour(a).is_equal_approx(Color8(200, 100, 50).srgb_to_linear()), "solid")
	check(absf(OuterRing.mean_colour(b).linear_to_srgb().r - 0.5) < 0.02, "checkerboard averages")
	var means: Array[Color] = [RED]
	check_eq(OuterRing._colour(means, ["a", "b"], "a"), RED, "known layer")
	check_eq(
		OuterRing._colour(means, ["a", "b"], "b"), OuterRing.FALLBACK.srgb_to_linear(), "no mean"
	)
	check_eq(OuterRing._colour(means, ["a"], "z"), OuterRing.FALLBACK.srgb_to_linear(), "unknown")


func test_setup_on_the_worlds() -> void:
	for dir: String in [WorldData.default_dir(), ContentDB.SAMPLE_ROOT + "/world"]:
		var world := WorldData.new()
		if not check(world.load_dir(dir), "load %s" % dir):
			world.free()
			continue
		var ring := OuterRing.new()
		var none: Array[Color] = []
		check(ring.setup(world, [], none), "%s: %s" % [dir, ring.errors])
		if world.has_layer(OuterRing.FILE):
			check(
				ring.visible and ring.triangles > 40000,
				"%s: ring drawn (%d)" % [dir, ring.triangles]
			)
		else:
			check(not ring.visible and ring.mesh == null, "%s: no file, no ring" % dir)
		ring.free()
		world.free()
