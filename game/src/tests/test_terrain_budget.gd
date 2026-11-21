extends TestCase
## T-05-7: along the T-05-3 flight, terrain selection uses at most 400
## instances and at most 1.0 ms per run, re-selecting as the game does.
## The cost at a point is the fastest of REPEATS runs there, so one scheduler
## hiccup does not count as selection cost. The time limit is defined on the
## dev PC; CI (env CI set) reports the time and checks the instance count.

const MAX_INSTANCES := 400
const MAX_MS := 1.0
const FRAME_S := 1.0 / 60.0
const REPEATS := 3


# gdlint:ignore = function-name
func test_T_05_7() -> void:
	var world := WorldData.new()
	var terrain := Terrain.new()
	var cam := Camera3D.new()
	cam.fov = 75.0
	cam.near = 0.05
	cam.far = 12000.0
	tree.root.add_child(terrain)
	tree.root.add_child(cam)
	if (
		check(world.load_dir(WorldData.default_dir()), ", ".join(world.errors))
		and check(terrain.setup(world), ", ".join(terrain.errors))
	):
		var flight := TerrainFlight.new(world)
		var worst_ms := 0.0
		var total_ms := 0.0
		var worst_n := 0
		var frames := int(flight.duration_s / FRAME_S)
		for f in frames:
			cam.global_transform = flight.pose(f * FRAME_S)
			if terrain.update_for(cam):
				var ms := INF
				for r in REPEATS:
					var t0 := Time.get_ticks_usec()
					terrain.lod.select(cam.global_position, Terrain.culling_planes(cam))
					ms = minf(ms, (Time.get_ticks_usec() - t0) / 1000.0)
				worst_ms = maxf(worst_ms, ms)
				total_ms += ms
				worst_n = maxi(worst_n, terrain.instances)
		print(
			(
				"  T-05-7: %d selections over %.0f m, worst %d instances, worst %.3f ms, mean %.3f ms"
				% [
					terrain.selections,
					flight.duration_s * TerrainFlight.SPEED_MPS,
					worst_n,
					worst_ms,
					total_ms / maxi(terrain.selections, 1)
				]
			)
		)
		check(terrain.selections > 0, "the flight re-selected")
		check(worst_n <= MAX_INSTANCES, "worst %d instances (limit 400)" % worst_n)
		if OS.get_environment("CI") == "":
			check(worst_ms <= MAX_MS, "worst selection %.3f ms (limit 1.0)" % worst_ms)
	cam.free()
	terrain.free()
	world.free()
