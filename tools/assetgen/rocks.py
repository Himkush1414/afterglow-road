"""Rock meshes from a preset, run inside Blender (22 §2, §3 "Rocks"):

  tools/blender.sh -b --python tools/assetgen/rocks.py -- --preset <rocks.json> --out <dir>

Kinds: "face" (a cliff face: a sheet `size_m` wide and high in the X-Y
plane, base at y = 0, outward normal +Z, relief pushed out along +Z and
edges receding behind the plane so they sink into the slope), "boulder"
(a displaced, flattened icosphere resting on y = 0), "rubble" (a few small
stones). UVs are metric (1 unit per `uv_m` metres) so the rock texture keeps
its scale on every mesh. Writes <out>/<category>_<name>_<n>.glb (geometry
and UVs; the game supplies the material). Deterministic for a preset.
"""
import json
import math
import os
import random
import sys

import bmesh
import bpy
from mathutils import Vector, noise


def args():
    a = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    return a[a.index("--preset") + 1], a[a.index("--out") + 1]


def fbm(p, octaves=4):
    v, amp, f = 0.0, 1.0, 1.0
    for _ in range(octaves):
        v += amp * noise.noise(p * f)
        amp *= 0.5
        f *= 2.0
    return v


def face_mesh(bm, spec, rnd):
    w, h = spec["size_m"]
    nx, ny = spec["grid"]
    relief = spec["relief_m"]
    off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))
    verts = []
    for j in range(ny + 1):
        row = []
        for i in range(nx + 1):
            x = -w / 2 + w * i / nx
            y = h * j / ny
            ex = min(i, nx - i) / (nx / 2)
            ey = min(j, ny - j) / (ny / 2)
            edge = min(ex, ey)
            bump = fbm(Vector((x * 0.35, y * 0.35, 0.0)) + off) * relief
            z = bump * min(1.0, edge * 3.0) - (1.0 - min(1.0, edge * 4.0)) * relief * spec.get("edge_sink", 1.0)  # edges recede
            row.append(bm.verts.new((x, y, z)))
        verts.append(row)
    for j in range(ny):
        for i in range(nx):
            bm.faces.new((verts[j][i], verts[j][i + 1], verts[j + 1][i + 1], verts[j + 1][i]))


def boulder_mesh(bm, spec, rnd):
    lo, hi = spec["size_m"]
    size = rnd.uniform(lo, hi)
    bmesh.ops.create_icosphere(bm, subdivisions=spec["subdivisions"], radius=size / 2)
    off = Vector((rnd.uniform(0, 100), rnd.uniform(0, 100), rnd.uniform(0, 100)))
    for v in bm.verts:
        n = v.co.normalized()
        v.co = v.co * (1.0 + spec["relief"] * fbm(n * 1.7 + off, 3))
        v.co.y *= spec["flatten"]
    base = min(v.co.y for v in bm.verts)
    for v in bm.verts:
        v.co.y -= base + spec["sink_m"]


def rubble_mesh(bm, spec, rnd):
    lo, hi = spec["size_m"]
    for k in range(spec["pieces"]):
        piece = bmesh.new()
        boulder_mesh(piece, {"size_m": [lo, hi], "subdivisions": spec["subdivisions"], "relief": spec["relief"], "flatten": spec["flatten"], "sink_m": 0.0}, rnd)
        a = 2 * math.pi * k / spec["pieces"] + rnd.uniform(-0.4, 0.4)
        r = rnd.uniform(0.1, spec["spread_m"])
        for v in piece.verts:
            v.co.x += math.cos(a) * r
            v.co.z += math.sin(a) * r
        tmp = bpy.data.meshes.new("tmp")
        piece.to_mesh(tmp)
        bm.from_mesh(tmp)
        bpy.data.meshes.remove(tmp)
        piece.free()


def metric_uvs(bm, uv_m):
    """Box-projected UVs in metres / uv_m, by each face's main axis."""
    layer = bm.loops.layers.uv.verify()
    for f in bm.faces:
        n = f.normal
        ax = max(range(3), key=lambda i: abs(n[i]))
        for loop in f.loops:
            c = loop.vert.co
            u, v = (c.y, c.z) if ax == 0 else ((c.x, c.z) if ax == 1 else (c.x, c.y))
            loop[layer].uv = (u / uv_m, v / uv_m)


def build(spec, rnd):
    bm = bmesh.new()
    {"face": face_mesh, "boulder": boulder_mesh, "rubble": rubble_mesh}[spec["kind"]](bm, spec, rnd)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.normal_update()
    metric_uvs(bm, spec["uv_m"])
    return bm


def export(bm, name, path):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    for o in bpy.context.scene.objects:
        o.select_set(o == obj)
    bpy.context.view_layer.objects.active = obj
    # Blender is Z-up; the meshes are built Y-up, so turn them before the exporter's Y-up conversion.
    obj.rotation_euler = (math.radians(90), 0, 0)
    bpy.ops.object.transform_apply(rotation=True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_materials="NONE", export_apply=True)
    bpy.data.objects.remove(obj)
    bpy.data.meshes.remove(mesh)


def main():
    preset_path, out = args()
    with open(preset_path, encoding="utf-8") as f:
        preset = json.load(f)
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    os.makedirs(out, exist_ok=True)
    for spec in preset["meshes"]:
        for n in range(1, spec["variants"] + 1):
            rnd = random.Random(f"{spec['name']}:{spec['seed']}:{n}")
            name = f"{preset['category']}_{spec['name']}_{n}"
            export(build(spec, rnd), name, os.path.join(out, name + ".glb"))
            print(f"rocks: wrote {name}.glb")


main()
