class_name OuterRing
extends MeshInstance3D
## The outer ring (05 §4 stage 12a): one mesh from world/outer.bin around the
## map that closes the view from high ground. No collision, no trees. The
## cells inside the map are left out; a skirt hangs from the inner edge.
## Colours come from the terrain's layers (their mean albedo): by height band
## (tuning terrain.outer_layers), then by slope (terrain.slope_layers).

const FILE := "outer.bin"
const SHADER := "res://shaders/outer_ring.gdshader"
## Grid of 04 §2: 160 cells of 128 m; the first grid line at map -6144.
const CELLS := 160
const CELL_M := 128.0
const LO_M := -6144.0
## Colour of a layer without a texture (sample content).
const FALLBACK := Color(0.45, 0.45, 0.42)

var errors: PackedStringArray = []
var triangles := 0


## Builds the ring for `world`; `means` holds the linear mean colour of each
## of `layers` (missing ones use FALLBACK). Returns false when the file is
## listed but broken; a world without the file has no ring (true, hidden).
func setup(world: WorldData, layers: Array, means: Array[Color]) -> bool:
	errors.clear()
	visible = false
	if not world.has_layer(FILE):
		return true
	var n := CELLS + 1
	var raw := world.read_layer(FILE, n * n * 2)
	if raw.is_empty():
		errors.append_array(world.errors)
		return false
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	for i in n * n:
		heights[i] = world.height_of_code(raw.decode_u16(i * 2))
	var cfg := ContentDB.tuning("terrain")
	var bands: Array = []
	for b: Dictionary in cfg.get("outer_layers", []):
		bands.append([float(b.below_m), _colour(means, layers, b.layer)])
	var slopes: Array = []
	for s: Dictionary in cfg.get("slope_layers", []):
		slopes.append([float(s.deg), _colour(means, layers, s.layer)])
	var shape := {
		"n": n,
		"cell_m": CELL_M,
		"lo_m": LO_M,
		"map_m": world.size_m,
		"origin": world.origin_offset_m,
		"skirt_m": float(cfg.get("outer_skirt_m", 0.0)),
	}
	mesh = build_mesh(heights, shape, bands, slopes)
	triangles = mesh.surface_get_array_index_len(0) / 3
	var mat := ShaderMaterial.new()
	mat.shader = load(SHADER)
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The ring spans 20 km; keep it from being culled by a too-tight box.
	extra_cull_margin = 0.0
	visible = true
	return true


## Linear mean colour of an image with mipmaps: its 1 x 1 mip.
static func mean_colour(img: Image) -> Color:
	var im := img
	if im.is_compressed():
		im = img.duplicate()
		im.decompress()
	if im.get_format() != Image.FORMAT_RGBA8:
		im = im.duplicate()
		im.convert(Image.FORMAT_RGBA8)
	if not im.has_mipmaps():
		im = im.duplicate()
		im.generate_mipmaps()
	var off := im.get_mipmap_offset(im.get_mipmap_count())
	var d := im.get_data()
	return Color8(d[off], d[off + 1], d[off + 2]).srgb_to_linear()


static func _colour(means: Array[Color], layers: Array, layer: String) -> Color:
	var i := layers.find(layer)
	return means[i] if i >= 0 and i < means.size() else FALLBACK.srgb_to_linear()


## Colour of a vertex: the first height band whose top is above it, then the
## steepest slope layer it exceeds.
static func colour_at(y: float, slope_deg: float, bands: Array, slopes: Array) -> Color:
	var c := FALLBACK.srgb_to_linear()
	for b: Array in bands:
		if y < b[0]:
			c = b[1]
			break
	for s: Array in slopes:
		if slope_deg > s[0]:
			c = s[1]
	return c


## The ring mesh: every grid cell outside the map, plus a double-sided skirt
## of skirt_m down from the inner edge. Vertices in engine coordinates.
static func build_mesh(
	h: PackedFloat32Array, shape: Dictionary, bands: Array, slopes: Array
) -> ArrayMesh:
	var n: int = shape.n
	var cell: float = shape.cell_m
	var lo: float = shape.lo_m
	var origin: float = shape.origin
	var inner0 := int(round((0.0 - lo) / cell))
	var inner1 := int(round((float(shape.map_m) - lo) / cell))
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colours := PackedColorArray()
	for j in n:
		for i in n:
			var y := h[j * n + i]
			var dx := h[j * n + mini(i + 1, n - 1)] - h[j * n + maxi(i - 1, 0)]
			var dz := h[mini(j + 1, n - 1) * n + i] - h[maxi(j - 1, 0) * n + i]
			var sx := float(mini(i + 1, n - 1) - maxi(i - 1, 0)) * cell
			var sz := float(mini(j + 1, n - 1) - maxi(j - 1, 0)) * cell
			var nrm := Vector3(-dx / sx, 1.0, -dz / sz).normalized()
			verts.append(Vector3(lo + i * cell - origin, y, lo + j * cell - origin))
			normals.append(nrm)
			colours.append(colour_at(y, rad_to_deg(acos(nrm.y)), bands, slopes))
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			if i >= inner0 and i < inner1 and j >= inner0 and j < inner1:
				continue
			var a := j * n + i
			idx.append_array([a, a + 1, a + n, a + 1, a + n + 1, a + n])
	var skirt: float = shape.skirt_m
	if skirt > 0.0:
		var loop: Array[Vector2i] = []
		for k in range(inner0, inner1):
			loop.append(Vector2i(k, inner0))
		for k in range(inner0, inner1):
			loop.append(Vector2i(inner1, k))
		for k in range(inner1, inner0, -1):
			loop.append(Vector2i(k, inner1))
		for k in range(inner1, inner0, -1):
			loop.append(Vector2i(inner0, k))
		for e in loop.size():
			var p: Vector2i = loop[e]
			var q: Vector2i = loop[(e + 1) % loop.size()]
			var top_a := p.y * n + p.x
			var top_b := q.y * n + q.x
			var base := verts.size()
			for t: int in [top_a, top_b]:
				verts.append(verts[t] - Vector3(0.0, skirt, 0.0))
				normals.append(normals[t])
				colours.append(colours[t])
			idx.append_array([top_a, top_b, base, top_b, base + 1, base])
			idx.append_array([top_a, base, top_b, top_b, base, base + 1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colours
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return m
