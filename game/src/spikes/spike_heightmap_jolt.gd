extends SceneTree
## Spike P1-02 (assumption A-02): a HeightMapShape3D of 33 x 33 samples on a
## StaticBody3D scaled (2, 1, 2) collides where the data says, under Jolt.
## 200 spheres dropped on a sloped, bumpy 64 m patch must rest within 2 cm of
## the surface. Prints RESULT PASS or RESULT FAIL.

const N := 33
const SPACING := 2.0
const RADIUS := 0.1
const TOLERANCE := 0.02


func _initialize() -> void:
	_run.call_deferred()


static func height(x: float, z: float) -> float:
	# 15° tilt along x plus gentle bumps; x, z in metres from the patch centre.
	return tan(deg_to_rad(15.0)) * x + 1.5 * sin(x * 0.15) * cos(z * 0.12)


func _run() -> void:
	print("physics engine: ", ProjectSettings.get_setting("physics/3d/physics_engine"))
	var shape := HeightMapShape3D.new()
	shape.map_width = N
	shape.map_depth = N
	var data := PackedFloat32Array()
	data.resize(N * N)
	var half := (N - 1) / 2
	for j in N:
		for i in N:
			data[j * N + i] = height((i - half) * SPACING, (j - half) * SPACING)
	shape.map_data = data
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = shape
	body.add_child(col)
	body.scale = Vector3(SPACING, 1.0, SPACING)
	root.add_child(body)

	var rng := RandomNumberGenerator.new()
	rng.seed = 2
	var balls: Array[RigidBody3D] = []
	var sphere := SphereShape3D.new()
	sphere.radius = RADIUS
	for k in 200:
		var b := RigidBody3D.new()
		var c := CollisionShape3D.new()
		c.shape = sphere
		b.add_child(c)
		var x := rng.randf_range(-28.0, 28.0)
		var z := rng.randf_range(-28.0, 28.0)
		# Half fall from 1-3 m, half from 20-40 m (up to 28 m/s at impact).
		var drop := 1.0 + rng.randf() * 2.0 if k % 2 == 0 else 20.0 + rng.randf() * 20.0
		b.position = Vector3(x, height(x, z) + drop, z)
		b.linear_damp = 3.0
		b.angular_damp = 3.0
		b.lock_rotation = true  # no rolling: the test is about where the surface is
		var mat := PhysicsMaterial.new()
		mat.friction = 1.0
		mat.rough = true
		b.physics_material_override = mat
		root.add_child(b)
		balls.append(b)
	for f in 900:
		await physics_frame

	var space := body.get_world_3d().direct_space_state
	# 1. Rays: the collision surface must equal the triangulated data.
	var ray_worst := 0.0
	var diag := [0, 0]
	for k in 1000:
		var x := rng.randf_range(-31.0, 31.0)
		var z := rng.randf_range(-31.0, 31.0)
		var hit := _ray(space, x, z, body)
		if hit.is_empty():
			ray_worst = INF
			continue
		var h2 := _tri_heights(data, half, x, z)
		var hy: float = hit.position.y
		var e0 := absf(hy - h2.x)
		var e1 := absf(hy - h2.y)
		diag[0 if e0 <= e1 else 1] += 1
		ray_worst = maxf(ray_worst, minf(e0, e1))
	print("rays: worst |hit - data| %.4f m; diagonal votes %s" % [ray_worst, diag])
	# 2. Spheres: resting distance to the surface right below them.
	var worst := 0.0
	var off := 0
	var fell := 0
	var on_others := 0
	for b in balls:
		var p := b.global_position
		if absf(p.x) > 31.0 or absf(p.z) > 31.0:
			continue
		var hit := _ray(space, p.x, p.z, body)
		if hit.is_empty() or p.y < float(hit.position.y):
			fell += 1
			continue
		var n: Vector3 = hit.normal
		var hit_y: float = hit.position.y
		var gap := (p.y - hit_y) * n.y - RADIUS
		if absf(gap) > TOLERANCE:
			var nearest := INF
			for o in balls:
				if o != b:
					nearest = minf(nearest, o.global_position.distance_to(p))
			if nearest < 2.5 * RADIUS:
				on_others += 1
				continue  # resting on another sphere, not on the ground
			off += 1
			print(
				(
					"  off: %s gap %.3f nearest %.2f v %.3f"
					% [p, gap, nearest, b.linear_velocity.length()]
				)
			)
		else:
			worst = maxf(worst, absf(gap))
	off += 1 if ray_worst > TOLERANCE else 0
	print(
		(
			"ground contacts: worst gap %.4f m; outside tolerance %d; on other spheres %d; fell %d"
			% [worst, off, on_others, fell]
		)
	)
	var ok := off == 0 and fell == 0
	print("RESULT %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _ray(space: PhysicsDirectSpaceState3D, x: float, z: float, only: StaticBody3D) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 100, z), Vector3(x, -100, z))
	q.collide_with_bodies = true
	var hits := space.intersect_ray(q)
	return hits if not hits.is_empty() and hits.collider == only else _ray_static(space, x, z, only)


func _ray_static(
	space: PhysicsDirectSpaceState3D, x: float, z: float, only: StaticBody3D
) -> Dictionary:
	# Retry ignoring every rigid body so a sphere above the point does not hide the ground.
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 100, z), Vector3(x, -100, z))
	var exclude: Array[RID] = []
	for i in 300:
		var hit := space.intersect_ray(q)
		if hit.is_empty() or hit.collider == only:
			return hit
		exclude.append(hit.rid)
		q.exclude = exclude
	return {}


## Height of the data at (x, z) for both ways of splitting the cell.
func _tri_heights(data: PackedFloat32Array, half: int, x: float, z: float) -> Vector2:
	var gx := x / SPACING + half
	var gz := z / SPACING + half
	var i := clampi(int(floor(gx)), 0, N - 2)
	var j := clampi(int(floor(gz)), 0, N - 2)
	var u := gx - i
	var v := gz - j
	var h00 := data[j * N + i]
	var h10 := data[j * N + i + 1]
	var h01 := data[(j + 1) * N + i]
	var h11 := data[(j + 1) * N + i + 1]
	var a := (
		h00 + u * (h10 - h00) + v * (h11 - h10)
		if u >= v
		else h00 + v * (h01 - h00) + u * (h11 - h01)
	)
	var b := (
		h00 + u * (h10 - h00) + v * (h01 - h00)
		if u + v <= 1.0
		else h11 + (1.0 - u) * (h01 - h11) + (1.0 - v) * (h10 - h11)
	)
	return Vector2(a, b)
