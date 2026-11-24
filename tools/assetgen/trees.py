"""Tree models from a shape preset and the tree definitions, run inside Blender:

  tools/blender.sh -b --python tools/assetgen/trees.py -- \
      --preset <trees preset.json> --trees <trees.json> --out <dir> [--only <id>]

Each preset model (a tree id and a seed) gives `variants` files
<out>/<category>_<id>_<n>.glb. A file holds one mesh object per tier,
named <category>_<id>_<n>_t0 / _t1 / _t2 / _t3. T3 is the billboard: one
quad ("billboard" surface) on the model's cell of a grid x grid atlas, framed
by billboard_frame(); <out>/<category>_models.json lists every model's cell,
side and bottom for the atlas baker. T0-T2 have two surfaces: "bark"
(tapered tubes for the trunk and limbs, cylinder UVs in metres) and "leaves"
(clumped cards with soft normals pointing away from the crown centre, UVs into
a cell of the species leaf atlas). A species preset without "clumps" makes
leafless models (bark only); "lie_length_m" lays the trunk on the ground;
"stems" > 1 grows several trunks from the base (shrubs). A preset model
may name a "shape" other than its species (two shapes of one species).
A shape's "sizes" maps a tree size to overrides (tools/assetgen/shapes.py).

All tiers share one skeleton and one set of clump positions, so their
silhouettes match; they differ in tube resolution, branch depth and card
count. The cards fill the triangle budget left after the bark.

Vertex colour (COLOR_0, linear RGBA): R branch phase (0-1, 0 on the trunk),
G flutter weight (0 bark, 0.5-1 from a card's inner to its outer edge),
B distance from the trunk along the branch (0-1), A ambient occlusion
(analytic: bark darkens toward the ground and inside the crown, cards toward
the crown centre).

The tree's height and crown radius come from the tree definition
(height_m, canopy_r_m, trunk_r_m); the preset holds shape numbers only.
Output is deterministic for a preset.
"""
import json
import math
import os
import random
import sys

import bpy
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.assetgen.shapes import shape_for  # noqa: E402  (Blender runs this file as a script)

UP = Vector((0.0, 0.0, 1.0))
TIERS = ("t0", "t1", "t2")


def args():
    a = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []

    def opt(name, default=None):
        return a[a.index(name) + 1] if name in a else default

    return opt("--preset"), opt("--trees"), opt("--out"), opt("--only")


# ---------------------------------------------------------------- skeleton


class Branch:
    """A polyline with a radius per point. `reach` is the distance from the
    trunk along the branch chain at each point (0 on the trunk)."""

    def __init__(self, level, phase):
        self.level = level
        self.phase = phase
        self.points = []
        self.radii = []
        self.reach = []
        self.children = 0


def unit_random(rnd):
    while True:
        v = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1)))
        if 0.01 < v.length_squared <= 1.0:
            return v.normalized()


def perpendicular(d):
    p = d.cross(UP if abs(d.z) < 0.95 else Vector((1.0, 0.0, 0.0)))
    return p.normalized()


def grow(rnd, branch, start, direction, length, r0, r1, spec, reach0):
    """Walks a branch from `start` in segments of spec["seg_m"], bending by
    droop (down), rise (up) and random crook."""
    seg = spec["seg_m"]
    n = max(2, math.ceil(length / seg))
    step = length / n
    p, d = start.copy(), direction.normalized()
    crook = math.radians(spec.get("crook_deg", 0.0))
    for i in range(n + 1):
        t = i / n
        branch.points.append(p.copy())
        branch.radii.append(r0 + (r1 - r0) * t)
        branch.reach.append(reach0 + length * t)
        if i == n:
            break
        bend = unit_random(rnd) * math.tan(crook) * rnd.random()
        bend += UP * (spec.get("rise", 0.0) - spec.get("droop", 0.0)) * (1.0 / n)
        d = (d + bend).normalized()
        p = p + d * step


def point_at(branch, t):
    """Position, direction, radius and reach at fraction t of the branch."""
    k = min(len(branch.points) - 2, int(t * (len(branch.points) - 1)))
    f = t * (len(branch.points) - 1) - k
    a, b = branch.points[k], branch.points[k + 1]
    r = branch.radii[k] + (branch.radii[k + 1] - branch.radii[k]) * f
    reach = branch.reach[k] + (branch.reach[k + 1] - branch.reach[k]) * f
    return a.lerp(b, f), (b - a).normalized(), r, reach


def skeleton(rnd, tree, sp):
    height, trunk_r = tree["height_m"], tree["trunk_r_m"]
    trunk_spec = sp["trunk"]
    lying = "lie_length_m" in trunk_spec
    stems = []
    for k in range(trunk_spec.get("stems", 1)):
        trunk = Branch(0, 0.0)
        if lying:  # on the ground along a random heading, resting on its side
            az = rnd.uniform(0.0, 2.0 * math.pi)
            direction = Vector((math.cos(az), math.sin(az), 0.0))
            start, length = Vector((0.0, 0.0, trunk_r)) - direction * trunk_spec["lie_length_m"] * 0.5, trunk_spec["lie_length_m"]
        else:
            spread = trunk_spec.get("stem_spread_deg", 0.0) if k else 0.0
            lean = math.radians(spread + rnd.uniform(0.0, trunk_spec.get("lean_deg", 0.0)))
            az = rnd.uniform(0.0, 2.0 * math.pi)
            direction = Vector((math.sin(lean) * math.cos(az), math.sin(lean) * math.sin(az), math.cos(lean)))
            start, length = Vector(), height * trunk_spec["top"] * (rnd.uniform(0.75, 1.0) if k else 1.0)
        grow(rnd, trunk, start, direction, length, trunk_r, trunk_r * trunk_spec["taper"], trunk_spec, 0.0)
        flare = 0.0 if lying else trunk_spec.get("flare", 0.0)
        for i, z in enumerate(p.z for p in trunk.points):
            if z < 0.1 * height:
                trunk.radii[i] *= 1.0 + flare * (1.0 - z / (0.1 * height))
        stems.append(trunk)
    branches = list(stems)
    parents = list(stems)
    for level, spec in enumerate(sp["levels"], start=1):
        kids = []
        for parent in parents:
            count = spec["count"] if level == 1 else rnd.randint(*spec["count"])
            for i in range(count):
                u = (i + rnd.uniform(0.2, 0.8)) / count
                t = spec["from"] + (spec["to"] - spec["from"]) * u
                p, pd, pr, preach = point_at(parent, t)
                angle = math.radians(rnd.uniform(*spec["angle_deg"]))
                if level == 1 and not lying:
                    azi = i * 2.39996 + rnd.uniform(-0.3, 0.3)  # golden angle spiral
                    axis = UP
                else:
                    azi = rnd.uniform(0.0, 2.0 * math.pi)
                    axis = pd
                side = perpendicular(axis)
                side = side * math.cos(azi) + axis.cross(side) * math.sin(azi)
                d = (axis * math.cos(angle) + side * math.sin(angle)).normalized()
                lo, hi = spec["length"]
                base = tree["canopy_r_m"] if level == 1 else (parent.reach[-1] - parent.reach[0])
                length = base * (lo + (hi - lo) * u) * rnd.uniform(0.85, 1.15)
                r0 = max(spec["min_r_m"], pr * spec["radius_ratio"])
                b = Branch(level, rnd.random())
                grow(rnd, b, p - d * pr * 0.5, d, length, r0, spec["min_r_m"], spec, preach)
                parent.children += 1
                kids.append(b)
        branches += kids
        parents = kids
    return branches


def clumps(rnd, branches, sp):
    """Clump centres on the outer part of every branch without children."""
    cs = sp.get("clumps")
    out = []
    for b in branches if cs else []:
        if b.level == 0 or b.children:
            continue
        length = b.reach[-1] - b.reach[0]
        n = max(1, int(length * (1.0 - cs["from"]) / cs["spacing_m"]))
        for i in range(n):
            t = 1.0 - i / n * (1.0 - cs["from"])
            p, _, _, reach = point_at(b, t)
            out.append({"c": p + unit_random(rnd) * cs["radius_m"] * 0.3, "branch": b, "reach": reach})
    return out


def fit(branches, cl, tree, sp):
    """Scales the tree so its top is at height_m and the crown radius (95th
    percentile of clump distance from the trunk axis) is canopy_r_m. A
    leafless tree is scaled to its height only; a lying trunk is kept."""
    if "lie_length_m" in sp["trunk"]:
        return
    if not cl:
        top = max(p.z for b in branches for p in b.points)
        for p in (p for b in branches for p in b.points):
            p.z *= tree["height_m"] / top
        return
    cr = sp["clumps"]["radius_m"]
    top = max(max(p.z for b in branches for p in b.points), max(c["c"].z + cr for c in cl))
    dist = sorted(math.hypot(c["c"].x, c["c"].y) + cr for c in cl)
    crown = dist[int(0.95 * (len(dist) - 1))]
    sz, sxy = tree["height_m"] / top, tree["canopy_r_m"] / crown
    pts = [p for b in branches for p in b.points] + [c["c"] for c in cl]
    for p in pts:
        p.x *= sxy
        p.y *= sxy
        p.z *= sz


# ------------------------------------------------------------------- meshes


class Surface:
    def __init__(self):
        self.verts, self.normals, self.colors, self.faces, self.uvs = [], [], [], [], []

    def tris(self):
        return sum(len(f) - 2 for f in self.faces)


def crown_frame(points, cr):
    lo = Vector([min(p[i] for p in points) - cr for i in range(3)])
    hi = Vector([max(p[i] for p in points) + cr for i in range(3)])
    return (lo + hi) * 0.5, (hi - lo) * 0.5


def ao_in_crown(p, centre, half):
    q = Vector([(p[i] - centre[i]) / max(half[i], 0.01) for i in range(3)])
    return min(1.0, q.length), q


def tube(s, b, radial, ring_m, uv_m, max_reach, height, centre, half):
    """A tapered tube along a branch; the tip closes in a point."""
    length = b.reach[-1] - b.reach[0]
    rings = max(2, math.ceil(length / ring_m) + 1)
    base = len(s.verts)
    for j in range(rings):
        t = j / (rings - 1)
        p, d, r, reach = point_at(b, t)
        side = perpendicular(d)
        other = d.cross(side)
        depth, _ = ao_in_crown(p, centre, half)
        ao = (0.55 + 0.45 * min(1.0, p.z / (0.25 * height))) * (0.75 + 0.25 * depth)
        for i in range(radial + 1):  # the seam vertex repeats with u = full turn
            a = 2.0 * math.pi * i / radial
            n = side * math.cos(a) + other * math.sin(a)
            s.verts.append(p + n * r)
            s.normals.append(n)
            s.uvs.append((i / radial * 2.0 * math.pi * max(r, 0.05) / uv_m, (reach - b.reach[0]) / uv_m))
            s.colors.append((b.phase, 0.0, min(1.0, reach / max_reach), min(1.0, ao)))
    for j in range(rings - 1):
        r0, r1 = base + j * (radial + 1), base + (j + 1) * (radial + 1)
        for i in range(radial):
            s.faces.append((r0 + i, r0 + i + 1, r1 + i + 1, r1 + i))
    if b.level > 0:  # cap the tip
        tip, d, _, reach = point_at(b, 1.0)
        k = len(s.verts)
        s.verts.append(tip + d * b.radii[-1])
        s.normals.append(d)
        s.uvs.append((0.0, (reach - b.reach[0]) / uv_m))
        s.colors.append(s.colors[-1])
        last = base + (rings - 1) * (radial + 1)
        for i in range(radial):
            s.faces.append((last + i, last + i + 1, k))


def cards(s, rnd, cl, count, sp, max_reach, centre, half):
    """`count` cards spread over the clumps (all clumps when count allows,
    else an even subset), sized so the crown keeps the same covered area."""
    cs = sp["clumps"]
    order = list(range(len(cl)))
    rnd.shuffle(order)
    used = order if count >= len(cl) else sorted(order[:count])
    per = [count // len(used) + (1 if k < count % len(used) else 0) for k in range(len(used))]
    size = min(cs["card_max_m"], cs["card_m"] * math.sqrt(cs["cards_ref"] * len(cl) / max(count, 1)))
    grid = sp["leaf_grid"]
    for ci, n in zip(used, per):
        c = cl[ci]
        for _ in range(n):
            p = c["c"] + unit_random(rnd) * cs["radius_m"] * rnd.uniform(0.0, 0.6)
            out = (p - centre).normalized() if (p - centre).length > 1e-4 else UP
            normal = (unit_random(rnd) + out * cs.get("outward", 0.5) + UP * cs.get("upward", 0.3)).normalized()
            a = perpendicular(normal)
            a = (a * math.cos(rnd.uniform(0, math.pi)) + normal.cross(a) * math.sin(rnd.uniform(0, math.pi))).normalized()
            bvec = normal.cross(a)
            if bvec.dot(out) < 0.0:  # the card's +v edge points out of the crown
                bvec = -bvec
                a = -a
            h = size * 0.5
            cell = rnd.choice(sp["leaf_cells"])
            u0, v0 = (cell % grid) / grid, (cell // grid) / grid
            inset = 0.5 / 256.0
            flip = rnd.random() < 0.5
            base = len(s.verts)
            for du, dv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                v = p + a * (du * h) + bvec * (dv * h)
                depth, q = ao_in_crown(v, centre, half)
                soft = q.normalized() if q.length > 1e-4 else UP
                s.verts.append(v)
                s.normals.append((soft * 0.8 + normal * 0.2).normalized())
                uu = (du if not flip else -du) * 0.5 + 0.5
                s.uvs.append((u0 + inset + uu * (1.0 / grid - 2 * inset), v0 + inset + (dv * 0.5 + 0.5) * (1.0 / grid - 2 * inset)))
                ao = 0.45 + 0.55 * depth + 0.1 * max(0.0, q.z)
                s.colors.append((c["branch"].phase, 0.5 if dv < 0 else 1.0, min(1.0, c["reach"] / max_reach), min(1.0, ao)))
            s.faces.append((base, base + 1, base + 2, base + 3))


def build_tier(rnd, branches, cl, tier, budget, tree, sp):
    if cl:
        centre, half = crown_frame([c["c"] for c in cl], sp["clumps"]["radius_m"])
    else:  # leafless: the frame of the branches stands in for the crown
        centre, half = crown_frame([p for b in branches for p in b.points], 0.0)
    max_reach = max(b.reach[-1] for b in branches)
    bark = Surface()
    for b in branches:
        if b.level <= tier["levels"]:
            radial = tier["radial"] if b.level == 0 else max(3, tier["radial"] // (2 * b.level))
            tube(bark, b, radial, tier["ring_m"] * (1 + b.level), sp["uv_m"], max_reach, tree["height_m"], centre, half)
    if bark.tris() > budget:
        raise ValueError(f"{tree['id']} {tier}: bark uses {bark.tris()} of {budget} triangles")
    if not cl:
        return [bark]
    leaves = Surface()
    room = int(budget * sp["fill"]) - bark.tris()
    if room < 2:
        raise ValueError(f"{tree['id']} {tier}: bark uses {bark.tris()} of {budget} triangles")
    cards(leaves, rnd, cl, room // 2, sp, max_reach, centre, half)
    return [bark, leaves]


# ------------------------------------------------------------------- export


def billboard_frame(surfaces, fill):
    """(side, bottom) in metres of the square a tree is drawn into for its
    billboard: wide enough for the crown seen from any side (twice the
    largest distance from the trunk axis), tall enough for the tree, grown by
    1 / fill to leave a margin."""
    pts = [v for s in surfaces for v in s.verts]
    r = max(math.hypot(v.x, v.y) for v in pts)
    bottom = min(0.0, min(v.z for v in pts))
    top = max(v.z for v in pts)
    return max(top - bottom, 2.0 * r) / fill, bottom


def billboard_quad(side, bottom, cell, grid):
    """The T3 quad: `side` square, base at `bottom`, facing -Y (the bake
    camera), UVs on atlas cell `cell` (row-major from the top-left)."""
    s = Surface()
    col, row = cell % grid, cell // grid
    u0, u1 = col / grid, (col + 1) / grid
    v0, v1 = 1.0 - (row + 1) / grid, 1.0 - row / grid  # Blender UVs: v up
    h = side * 0.5
    for x, z, u, v in ((-h, bottom, u0, v0), (h, bottom, u1, v0), (h, bottom + side, u1, v1), (-h, bottom + side, u0, v1)):
        s.verts.append(Vector((x, 0.0, z)))
        s.normals.append(Vector((0.0, -1.0, 0.0)))
        s.uvs.append((u, v))
        s.colors.append((0.0, 0.0, 0.0, 1.0))
    s.faces.append((0, 1, 2, 3))
    return s


def cells(preset, defs):
    """Atlas cell of every model file, in preset order (stable under --only)."""
    out, i = {}, 0
    for model in preset["models"]:
        for n in range(1, defs[model["id"]]["variants"] + 1):
            out[f"{preset['category']}_{model['id']}_{n}"] = i
            i += 1
    return out


def material(name):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    return m


def to_object(name, surfaces, materials=("bark", "leaves")):
    """One mesh object; surface k gets material slot k, named materials[k]."""
    verts, normals, colors, faces, uvs, mats = [], [], [], [], [], []
    for k, s in enumerate(surfaces):
        off = len(verts)
        verts += s.verts
        normals += s.normals
        colors += s.colors
        uvs += s.uvs
        faces += [tuple(i + off for i in f) for f in s.faces]
        mats += [k] * len(s.faces)
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([tuple(v) for v in verts], [], faces)
    mesh.update()
    for name_k in materials[: len(surfaces)]:
        mesh.materials.append(material(name_k))
    mesh.polygons.foreach_set("material_index", mats)
    mesh.polygons.foreach_set("use_smooth", [True] * len(faces))
    uv = mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        for li in poly.loop_indices:
            uv.data[li].uv = uvs[mesh.loops[li].vertex_index]
    col = mesh.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="POINT")
    for i, c in enumerate(colors):
        col.data[i].color = c
    mesh.color_attributes.active_color = col
    mesh.normals_split_custom_set_from_vertices([tuple(n) for n in normals])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def export(objs, path):
    for o in bpy.context.scene.objects:
        o.select_set(o in objs)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=True, export_yup=True,
        export_materials="EXPORT", export_vertex_color="ACTIVE", export_normals=True, export_apply=True,
    )
    for o in objs:
        mesh = o.data
        bpy.data.objects.remove(o)
        bpy.data.meshes.remove(mesh)


def main():
    preset_path, trees_path, out, only = args()
    with open(preset_path, encoding="utf-8") as f:
        preset = json.load(f)
    with open(trees_path, encoding="utf-8") as f:
        defs = {t["id"]: t for t in json.load(f)["trees"]}
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    os.makedirs(out, exist_ok=True)
    bb = preset["billboard"]
    cell_of = cells(preset, defs)
    if len(cell_of) > bb["grid"] ** 2:
        raise ValueError(f"{len(cell_of)} models do not fit a {bb['grid']} x {bb['grid']} billboard atlas")
    manifest_path = os.path.join(out, f"{preset['category']}_models.json")
    manifest = {"models": {}}
    if only and os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    manifest.update({"grid": bb["grid"], "fill": bb["fill"]})
    for model in preset["models"]:
        if only and model["id"] != only:
            continue
        tree = defs[model["id"]]
        sp = shape_for(preset, model, tree)
        budgets = preset["budgets"][tree["size"]]
        for n in range(1, tree["variants"] + 1):
            rnd = random.Random(f"{model['id']}:{model['seed']}:{n}")
            branches = skeleton(rnd, tree, sp)
            cl = clumps(rnd, branches, sp)
            fit(branches, cl, tree, sp)
            name = f"{preset['category']}_{model['id']}_{n}"
            objs, counts = [], []
            for k, tier_name in enumerate(TIERS):
                surfaces = build_tier(rnd, branches, cl, sp["tiers"][k], budgets[k], tree, sp)
                if k == 0:
                    side, bottom = billboard_frame(surfaces, bb["fill"])
                objs.append(to_object(f"{name}_{tier_name}", surfaces))
                counts.append(f"{tier_name} " + "+".join(str(x.tris()) for x in surfaces))
            objs.append(to_object(f"{name}_t3", [billboard_quad(side, bottom, cell_of[name], bb["grid"])], ("billboard",)))
            manifest["models"][name] = {"cell": cell_of[name], "side_m": round(side, 4), "bottom_m": round(bottom, 4)}
            export(objs, os.path.join(out, name + ".glb"))
            print(f"trees: wrote {name}.glb ({', '.join(counts)} triangles per surface; billboard cell {cell_of[name]})")
    with open(manifest_path, "w", encoding="ascii") as f:
        f.write(json.dumps(manifest, indent=1, sort_keys=True) + "\n")


main()
