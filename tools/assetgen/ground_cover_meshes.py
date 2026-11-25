"""Ground-cover card meshes from a preset and the atlas manifest, run inside
Blender (22 §3 "Ground cover"):

  tools/blender.sh -b --python tools/assetgen/ground_cover_meshes.py -- \\
      --preset <ground_cover_meshes.json> --atlas <ground_cover.json> --out <dir>

Every preset mesh names an atlas cell and is written at two levels of
detail (`lods`: "hi" for desktop, "lo" for phones), each with its own card
and segment counts:

- "cross": `cards` upright cards turned evenly around the vertical axis,
  `height_m` tall, as wide as the cell's opaque bounds are in proportion,
  each split into `segments` rows and bowed back by `bend` x height at the
  tip; triangles = cards x segments x 2;
- "flat": `cards` horizontal cards `width_m` across, lifted `lift_m`, each
  split into segments x segments and curled up by `curl_m` at the edges;
  triangles = cards x segments² x 2;
- "clump": `cards` upright cards like "cross" but each standing at a
  random point within `radius_m` with a random turn and 80-100% of the
  height (a reed bed, a bush, a mushroom patch).

Upright kinds take an optional `show` (0-1, default 1): only the bottom
share of the cell is used and the card is that share of `height_m` tall,
for cut stems (the empty state of a picked plant). Meshes with the same
`layout` name and seed place their cards alike (a plant's full and empty
states).

UVs cover the cell's opaque bounds (the root at the bottom of the cell).
Vertex colour R is the tip weight for the grass shader: the height share
on cross cards, 0 on flat ones. Normals point up so the cards light like
the ground beneath them. The root stands `sink_m` below y = 0 after the
exporter's Y-up conversion. One surface, material "ground_cover". Writes
<out>/<category>_<name>_<lod>.glb; deterministic for a preset.
"""
import json
import math
import os
import random
import sys

import bpy


def args():
    a = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    return a[a.index("--preset") + 1], a[a.index("--atlas") + 1], a[a.index("--out") + 1]


def cell_uv(atlas, cell):
    """(u0, v0, u1, v1) in atlas UV (v down from the top) of a cell's bounds."""
    g = atlas["grid"]
    i, b = cell["index"], cell["bounds"]
    cu, cv = (i % g) / g, (i // g) / g
    return cu + b[0] / g, cv + b[1] / g, cu + b[2] / g, cv + b[3] / g


def _card(verts, faces, uvs, tips, uv, at, a, h, w, rows, bend, show):
    """One upright card at `at` (x, y) turned by `a`, `h` tall before `show`."""
    u0, v0, u1, v1 = uv
    d = (math.cos(a), math.sin(a))
    nrm = (-d[1], d[0])
    base = len(verts)
    for j in range(rows + 1):
        t = j / rows
        back = bend * h * (t * show) ** 2
        for side in (-0.5, 0.5):
            x = at[0] + d[0] * w * side + nrm[0] * back
            y = at[1] + d[1] * w * side + nrm[1] * back
            verts.append((x, y, h * show * t))
            uvs.append((u0 + (side + 0.5) * (u1 - u0), v1 - t * show * (v1 - v0)))
            tips.append(t * show)
    for j in range(rows):
        r0, r1 = base + 2 * j, base + 2 * (j + 1)
        faces.append((r0, r0 + 1, r1 + 1, r1))


def cross(spec, lod, uv, rnd):
    """(verts, faces, uvs, tips) for upright cards around one point (Blender Z up)."""
    u0, v0, u1, v1 = uv
    h = spec["height_m"]
    w = h * (u1 - u0) / max(v1 - v0, 1e-6)
    verts, faces, uvs, tips = [], [], [], []
    n = lod["cards"]
    for k in range(n):
        a = math.pi * k / n + rnd.uniform(-0.15, 0.15)
        _card(verts, faces, uvs, tips, uv, (0.0, 0.0), a, h, w, lod["segments"], spec["bend"], spec.get("show", 1.0))
    return _sink(spec, verts), faces, uvs, tips


def clump(spec, lod, uv, rnd):
    """(verts, faces, uvs, tips) for upright cards spread over a disc."""
    u0, v0, u1, v1 = uv
    verts, faces, uvs, tips = [], [], [], []
    for k in range(lod["cards"]):
        r = spec["radius_m"] * math.sqrt(rnd.random())
        p = rnd.uniform(0.0, 2.0 * math.pi)
        h = spec["height_m"] * rnd.uniform(0.8, 1.0)
        w = h * (u1 - u0) / max(v1 - v0, 1e-6)
        at = (math.cos(p) * r, math.sin(p) * r)
        a = rnd.uniform(0.0, math.pi)
        _card(verts, faces, uvs, tips, uv, at, a, h, w, lod["segments"], spec["bend"], spec.get("show", 1.0))
    return _sink(spec, verts), faces, uvs, tips


def _sink(spec, verts):
    s = spec.get("sink_m", 0.0)
    return [(x, y, z - s) for x, y, z in verts]


def flat(spec, lod, uv, rnd):
    """(verts, faces, uvs, tips) for horizontal cards (Blender Z up)."""
    u0, v0, u1, v1 = uv
    w = spec["width_m"]
    depth = w * (v1 - v0) / max(u1 - u0, 1e-6)
    verts, faces, uvs, tips = [], [], [], []
    n, s = lod["cards"], lod["segments"]
    for k in range(n):
        a = math.pi * 0.5 * k / n + rnd.uniform(-0.3, 0.3)
        c, si = math.cos(a), math.sin(a)
        base = len(verts)
        for j in range(s + 1):
            for i in range(s + 1):
                x, y = (i / s - 0.5) * w, (j / s - 0.5) * depth
                edge = max(abs(i / s - 0.5), abs(j / s - 0.5)) * 2.0
                z = spec["lift_m"] + spec["curl_m"] * edge * edge + 0.002 * k
                verts.append((x * c - y * si, x * si + y * c, z))
                uvs.append((u0 + i / s * (u1 - u0), v1 - j / s * (v1 - v0)))
                tips.append(0.0)
        for j in range(s):
            for i in range(s):
                q = base + j * (s + 1) + i
                faces.append((q, q + 1, q + s + 2, q + s + 1))
    return verts, faces, uvs, tips


def build(name, verts, faces, uvs, tips):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    mesh.materials.append(bpy.data.materials.get("ground_cover") or bpy.data.materials.new("ground_cover"))
    layer = mesh.uv_layers.new(name="UVMap")
    for poly in mesh.polygons:
        for li in poly.loop_indices:
            u, v = uvs[mesh.loops[li].vertex_index]
            layer.data[li].uv = (u, 1.0 - v)  # Blender UV v grows upward
    col = mesh.color_attributes.new(name="Color", type="FLOAT_COLOR", domain="POINT")
    for i, t in enumerate(tips):
        col.data[i].color = (t, 0.0, 0.0, 1.0)
    mesh.color_attributes.active_color = col
    mesh.normals_split_custom_set_from_vertices([(0.0, 0.0, 1.0)] * len(verts))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def export(obj, path):
    for o in bpy.context.scene.objects:
        o.select_set(o == obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=True, export_yup=True,
        export_materials="EXPORT", export_vertex_color="ACTIVE", export_normals=True, export_apply=True,
    )
    mesh = obj.data
    bpy.data.objects.remove(obj)
    bpy.data.meshes.remove(mesh)


def main():
    preset_path, atlas_path, out = args()
    with open(preset_path, encoding="utf-8") as f:
        preset = json.load(f)
    with open(atlas_path, encoding="utf-8") as f:
        atlas = json.load(f)
    cells = {c["name"]: c for c in atlas["cells"]}
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    os.makedirs(out, exist_ok=True)
    for spec in preset["meshes"]:
        uv = cell_uv(atlas, cells[spec["cell"]])
        for lod_name, lod in spec["lods"].items():
            rnd = random.Random(f"{spec.get('layout', spec['name'])}:{spec['seed']}:{lod_name}")
            make = {"cross": cross, "flat": flat, "clump": clump}[spec["kind"]]
            name = f"{preset['category']}_{spec['name']}_{lod_name}"
            export(build(name, *make(spec, lod, uv, rnd)), os.path.join(out, name + ".glb"))
            print(f"ground cover: wrote {name}.glb")


main()
