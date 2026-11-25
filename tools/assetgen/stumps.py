"""Stump and felled-cap meshes from a preset, run inside Blender (22 §3
"Stumps, felled trunk caps"):

  tools/blender.sh -b --python tools/assetgen/stumps.py -- --preset <stumps.json> --out <dir>

Both kinds have unit radius (the game scales x and z by the tree's trunk
radius) and stand on y = 0 after the exporter's Y-up conversion. "stump": a
ring wall `height_m` high, flared at the base and sunk `sink_m` below
ground, with a cut top tilted by `tilt_deg` and a ragged hinge lip `lip_m`
high on one side. "cap": a disc `thickness_m` thick facing +Y (the cut end
of a felled trunk) with a splintered rim. Two surfaces: "bark" (the wall,
u around the circumference, v in metres / uv_m) and "cut" (the top, planar
UV 0..1 across the disc). Writes <out>/<category>_<name>_<n>.glb;
deterministic for a preset.
"""
import json
import math
import os
import random
import sys

import bmesh
import bpy

BARK, CUT = 0, 1


def args():
    a = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    return a[a.index("--preset") + 1], a[a.index("--out") + 1]


def ring(bm, spec, rnd, z_of, r_of):
    """One vertex per side at height z_of(angle) and radius r_of(angle)."""
    out = []
    for k in range(spec["sides"]):
        a = 2 * math.pi * k / spec["sides"]
        r = r_of(a)
        out.append(bm.verts.new((math.cos(a) * r, math.sin(a) * r, z_of(a))))
    return out


def wall(bm, rings):
    """Bark quads between consecutive rings (bottom to top)."""
    faces = []
    for lo, hi in zip(rings, rings[1:]):
        n = len(lo)
        for k in range(n):
            faces.append(bm.faces.new((lo[k], lo[(k + 1) % n], hi[(k + 1) % n], hi[k])))
    for f in faces:
        f.material_index = BARK
    return faces


def top(bm, edge, z):
    """A fan of cut faces from a centre vertex to the edge ring."""
    centre = bm.verts.new((0.0, 0.0, z))
    n = len(edge)
    for k in range(n):
        bm.faces.new((centre, edge[k], edge[(k + 1) % n])).material_index = CUT


def stump_mesh(bm, spec, rnd):
    h, j = spec["height_m"], spec["jitter"]
    tilt = math.tan(math.radians(spec["tilt_deg"]))
    hinge = rnd.uniform(0, 2 * math.pi)
    radii = [1.0 + rnd.uniform(-j, j) for _ in range(spec["sides"])]

    def r_at(a, scale=1.0):
        return radii[round(a / (2 * math.pi) * spec["sides"]) % spec["sides"]] * scale

    def cut_z(a):
        d = math.cos(a - hinge)
        lip = spec["lip_m"] * max(0.0, d) ** 4 * rnd.uniform(0.6, 1.0)
        return h + tilt * d + lip

    rings = [
        ring(bm, spec, rnd, lambda a: -spec["sink_m"], lambda a: r_at(a, 1.0 + spec["flare"])),
        ring(bm, spec, rnd, lambda a: h * 0.25, lambda a: r_at(a, 1.0 + spec["flare"] * 0.25)),
        ring(bm, spec, rnd, cut_z, r_at),
    ]
    wall(bm, rings)
    top(bm, rings[-1], h)


def cap_mesh(bm, spec, rnd):
    t, s = spec["thickness_m"], spec["splinter"]
    radii = [1.0 + rnd.uniform(-s, s * 0.3) for _ in range(spec["sides"])]

    def r_at(a):
        return radii[round(a / (2 * math.pi) * spec["sides"]) % spec["sides"]]

    rings = [ring(bm, spec, rnd, lambda a: 0.0, r_at), ring(bm, spec, rnd, lambda a: t, r_at)]
    wall(bm, rings)
    top(bm, rings[-1], t)


def uvs(bm, spec):
    layer = bm.loops.layers.uv.verify()
    for f in bm.faces:
        for loop in f.loops:
            x, y, z = loop.vert.co
            if f.material_index == CUT:
                loop[layer].uv = (x * 0.5 + 0.5, y * 0.5 + 0.5)
            else:
                a = math.atan2(y, x) % (2 * math.pi)
                loop[layer].uv = (a / (2 * math.pi) * spec["uv_around"], z / spec["uv_m"])
    # Close the seam: faces crossing angle 0 take u + uv_around on their low side.
    for f in bm.faces:
        if f.material_index != BARK:
            continue
        us = [loop[layer].uv.x for loop in f.loops]
        if max(us) - min(us) > spec["uv_around"] * 0.5:
            for loop in f.loops:
                if loop[layer].uv.x < spec["uv_around"] * 0.5:
                    loop[layer].uv.x += spec["uv_around"]


def build(spec, rnd):
    bm = bmesh.new()
    {"stump": stump_mesh, "cap": cap_mesh}[spec["kind"]](bm, spec, rnd)
    uvs(bm, spec)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    bm.normal_update()
    return bm


def export(bm, name, path):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    for m in ("bark", "cut"):
        mesh.materials.append(bpy.data.materials.get(m) or bpy.data.materials.new(m))
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    for o in bpy.context.scene.objects:
        o.select_set(o == obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_yup=True, export_materials="EXPORT", export_apply=True)
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
            print(f"stumps: wrote {name}.glb")


main()
