"""Hair styles and facial hair for character.py (run inside Blender).

Preset block (positions in metres relative to the body's eye point E; the
bodies face -Y in Blender, so "front" is -Y):

  "hair": {
    "material": "hair", "bone": "head",
    "max_tris": 4000, "facial_max_tris": 1200,
    "scalp": {"front_line_m": z above E where the front hairline runs,
              "back_offset_m": y behind E from where the back of the head
              starts, "nape_line_m": z (relative to E) of the nape line},
    "styles": {"<id>": {"thickness_m": t, "noise_m": n, "noise_freq": f,
                        "drop_m": z relative to E the hair falls to (optional),
                        "flare_m": outward flare of the fallen part,
                        "tail": {"radius_m", "length_m"} (optional),
                        "bun": {"radius_m"} (optional)}},
    "facial": {"<id>": {"regions": [<region>, ...], "thickness_m": t,
                        "noise_m": n, "noise_freq": f}},
    "regions": {"<region>": {"x_max_m": |x| limit, "z_m": [lo, hi] relative
                             to E, "y_max_m": y relative to E (front side)}}
  }

Every style is a shell: the region's faces of the body skin, moved out
along their smooth normals by thickness plus noise (mathutils Perlin noise:
deterministic). Fallen hair extrudes the shell's back and side boundary
down to drop_m and flares it outward. Meshes are named hair_<id> and
facial_hair_<id>, weighted fully to `bone`, with the material `material`,
and decimated to the budget.
"""
import bmesh
import bpy
from mathutils import Vector, noise

SEGMENTS_TAIL = 8
RINGS_TAIL = 6


def _shell(body, keep, thickness, noise_m, freq, name):
    """A copy of `body` reduced to the faces whose vertices all pass `keep`
    (a function of the world position), pushed out along the normals."""
    obj = body.copy()
    obj.data = body.data.copy()
    obj.name = name
    obj.data.name = name
    bpy.context.scene.collection.objects.link(obj)
    if obj.data.shape_keys:
        obj.shape_key_clear()
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    mw = obj.matrix_world
    doomed = [f for f in mesh.faces if not all(keep(mw @ v.co) for v in f.verts)]
    bmesh.ops.delete(mesh, geom=doomed, context="FACES")
    loose = [v for v in mesh.verts if not v.link_faces]
    bmesh.ops.delete(mesh, geom=loose, context="VERTS")
    mesh.normal_update()
    for v in mesh.verts:
        n = noise.noise(v.co * freq) * noise_m
        v.co = v.co + v.normal * (thickness + n)
    mesh.to_mesh(obj.data)
    mesh.free()
    return obj


def _fall(obj, eye, drop_z, flare, back_offset):
    """Extrudes the shell's boundary behind the temples down to drop_z."""
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    mesh.verts.ensure_lookup_table()
    edges = [
        e for e in mesh.edges
        if e.is_boundary and all(v.co.y - eye.y > back_offset for v in e.verts)
    ]
    out = bmesh.ops.extrude_edge_only(mesh, edges=edges)
    for v in [g for g in out["geom"] if isinstance(g, bmesh.types.BMVert)]:
        radial = Vector((v.co.x, v.co.y - eye.y, 0.0))
        if radial.length > 1e-6:
            radial.normalize()
        v.co = Vector((v.co.x, v.co.y, eye.z + drop_z)) + radial * flare
    mesh.to_mesh(obj.data)
    mesh.free()


def _anchor(obj, score):
    """The world position of the shell vertex with the highest score."""
    mw = obj.matrix_world
    return max((mw @ v.co for v in obj.data.vertices), key=score)


def _add_tail(obj, eye, spec):
    """A tube hanging from the back of the head."""
    top = _anchor(obj, lambda p: (p.y - eye.y) - abs(p.z - eye.z - 0.02) * 2.0)
    r = float(spec["radius_m"])
    length = float(spec["length_m"])
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    rings = []
    for k in range(RINGS_TAIL + 1):
        t = k / RINGS_TAIL
        # starts inside the shell at the back of the head, then hangs back a little
        centre = top + Vector((0.0, -radius_start(r) + 0.05 * t, -length * t))
        radius = r * (1.0 - 0.5 * t)
        ring = []
        for s in range(SEGMENTS_TAIL):
            a = 6.283185307 * s / SEGMENTS_TAIL
            ring.append(mesh.verts.new(centre + Vector((radius * _cos(a), radius * _sin(a), 0.0))))
        rings.append(ring)
    for k in range(RINGS_TAIL):
        for s in range(SEGMENTS_TAIL):
            n = (s + 1) % SEGMENTS_TAIL
            mesh.faces.new((rings[k][s], rings[k][n], rings[k + 1][n], rings[k + 1][s]))
    mesh.to_mesh(obj.data)
    mesh.free()


def radius_start(r):
    """How far the tail's first ring sits inside the hair shell."""
    return r * 0.6


def _add_bun(obj, eye, spec):
    """A sphere at the top back of the head."""
    top = _anchor(obj, lambda p: (p.z - eye.z) + (p.y - eye.y))
    r = float(spec["radius_m"])
    mesh = bmesh.new()
    mesh.from_mesh(obj.data)
    bmesh.ops.create_uvsphere(
        mesh, u_segments=10, v_segments=6, radius=r,
        matrix=_translation(top + Vector((0.0, r * 0.5, r * 0.5))),
    )
    mesh.to_mesh(obj.data)
    mesh.free()


def _finish(obj, bone, material, max_tris):
    """Weights everything to `bone`, sets the material, decimates to the budget."""
    obj.vertex_groups.clear()
    group = obj.vertex_groups.new(name=bone)
    group.add([v.index for v in obj.data.vertices], 1.0, "REPLACE")
    obj.data.materials.clear()
    obj.data.materials.append(bpy.data.materials.get(material) or bpy.data.materials.new(name=material))
    tris = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    if tris > max_tris:
        mod = obj.modifiers.new("budget", "DECIMATE")
        mod.ratio = max_tris / tris * 0.98
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_move_to_index(modifier="budget", index=0)
        bpy.ops.object.modifier_apply(modifier="budget")
    return obj


def parts(body, eye, preset):
    """Hair and facial hair mesh objects for `body` with eye point `eye`."""
    spec = preset.get("hair")
    if not spec:
        return []
    scalp = spec["scalp"]
    front = float(scalp["front_line_m"])
    back = float(scalp["back_offset_m"])
    nape = float(scalp["nape_line_m"])

    def on_scalp(p):
        z = p.z - eye.z
        return z > front or (p.y - eye.y > back and z > nape)

    out = []
    for sid in sorted(spec.get("styles", {})):
        st = spec["styles"][sid]
        obj = _shell(body, on_scalp, float(st["thickness_m"]), float(st.get("noise_m", 0.0)),
                     float(st.get("noise_freq", 30.0)), "hair_" + sid)
        if "drop_m" in st:
            _fall(obj, eye, float(st["drop_m"]), float(st.get("flare_m", 0.0)), back * 0.25)
        if "tail" in st:
            _add_tail(obj, eye, st["tail"])
        if "bun" in st:
            _add_bun(obj, eye, st["bun"])
        out.append(_finish(obj, spec.get("bone", "head"), spec["material"], int(spec["max_tris"])))
    regions = spec.get("regions", {})
    for fid in sorted(spec.get("facial", {})):
        st = spec["facial"][fid]
        boxes = [regions[r] for r in st["regions"]]

        def in_beard(p, boxes=boxes):
            for b in boxes:
                z = p.z - eye.z
                lo, hi = b["z_m"]
                if abs(p.x) <= b["x_max_m"] and lo <= z <= hi and p.y - eye.y <= b["y_max_m"]:
                    return True
            return False

        obj = _shell(body, in_beard, float(st["thickness_m"]), float(st.get("noise_m", 0.0)),
                     float(st.get("noise_freq", 60.0)), "facial_hair_" + fid)
        out.append(_finish(obj, spec.get("bone", "head"), spec["material"], int(spec["facial_max_tris"])))
    return out


def _cos(a):
    import math
    return math.cos(a)


def _sin(a):
    import math
    return math.sin(a)


def _translation(v):
    from mathutils import Matrix
    return Matrix.Translation(v)
