"""Player body models from a character preset, run inside Blender with MPFB:

  tools/blender.sh -b --python tools/assetgen/character.py -- \
      --preset <character preset.json> --out <dir>

Needs the MPFB extension installed in the Blender user resources in use
(BLENDER_USER_RESOURCES). The preset:

  {"eye_height_m": float,
   "twist_at": [t1, t2],            # forearm twist bones, share of the forearm
   "builds": {"slim": {<macro>: value}, "broad": {<macro>: value}},
   "bodies": {"<id>": {"macros": {<MPFB macro>: value, ...}}, ...}}

For every body the MPFB "height" macro is solved so that the eyes (the mean
of the left and right eye joints) stand at eye_height_m with the feet at 0.
One game-engine rig is fitted to the mean of the bodies' macros and shared
by all of them, so every body has the same skeleton (22 §4). Each forearm
gets two twist bones (lowerarm_twist_01/02_<side>, children of the lower
arm) at the preset's shares, and the lower arm's weights are split between
it and them along the forearm. An empty "eye_marker" child of the head bone
marks the eye midpoint of each body. Each build of the preset becomes a
shape key build_<name>: the body with the build's macros over its own.
Helper geometry (everything outside MPFB's "body" group) is removed.

Writes <out>/<id>.glb per body (the rig and that body's mesh) and <out>/bodies.json with the
solved macros and the measured eye heights. Deterministic for a preset.
"""
import argparse
import json
import os
import sys

import bmesh
import bpy
from mathutils import Matrix

bpy.ops.preferences.addon_enable(module="bl_ext.blender_org.mpfb")

from bl_ext.blender_org.mpfb.entities.objectproperties import HumanObjectProperties  # noqa: E402
from bl_ext.blender_org.mpfb.services.humanservice import HumanService  # noqa: E402
from bl_ext.blender_org.mpfb.services.targetservice import TargetService  # noqa: E402

RIG = "game_engine"
EYE_GROUPS = ("joint-l-eye", "joint-r-eye")
RACES = ("asian", "caucasian", "african")
EYE_TOLERANCE_M = 0.001
SOLVE_STEPS = 30
SIDES = ("l", "r")


def args():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", required=True)
    ap.add_argument("--out", required=True)
    return ap.parse_args(sys.argv[sys.argv.index("--") + 1 :])


def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)


def set_macros(basemesh, macros):
    """Writes MPFB macro values (race as a dict of shares) and reapplies them."""
    for key, value in macros.items():
        if key == "race":
            for race in RACES:
                HumanObjectProperties.set_value(race, float(value.get(race, 0.0)), entity_reference=basemesh)
        else:
            HumanObjectProperties.set_value(key, float(value), entity_reference=basemesh)
    TargetService.reapply_macro_details(basemesh)


def positions(basemesh):
    """World positions of every vertex with shape keys applied and modifiers off."""
    shown = [m.show_viewport for m in basemesh.modifiers]
    for m in basemesh.modifiers:
        m.show_viewport = False
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = basemesh.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    out = [basemesh.matrix_world @ v.co for v in mesh.vertices]
    evaluated.to_mesh_clear()
    for m, s in zip(basemesh.modifiers, shown):
        m.show_viewport = s
    return out


def group_members(basemesh, names):
    idx = {basemesh.vertex_groups[n].index for n in names}
    return [v.index for v in basemesh.data.vertices if any(g.group in idx for g in v.groups)]


def eye_point(basemesh):
    pts = positions(basemesh)
    members = group_members(basemesh, EYE_GROUPS)
    s = sum((pts[i] for i in members[1:]), pts[members[0]].copy())
    return s / len(members)


def solve_height(basemesh, macros, eye_m):
    """The height macro (0..1) that puts the eyes at eye_m; bisection."""
    lo, hi = 0.0, 1.0
    mid = 0.5
    for _ in range(SOLVE_STEPS):
        mid = (lo + hi) * 0.5
        set_macros(basemesh, dict(macros, height=mid))
        z = eye_point(basemesh).z
        if abs(z - eye_m) <= EYE_TOLERANCE_M * 0.5:
            break
        if z < eye_m:
            lo = mid
        else:
            hi = mid
    return mid


def mean_macros(bodies):
    keys = sorted({k for m in bodies for k in m if k != "race"})
    out = {k: sum(float(m.get(k, 0.5)) for m in bodies) / len(bodies) for k in keys}
    out["race"] = {r: sum(float(m.get("race", {}).get(r, 1.0 / 3.0)) for m in bodies) / len(bodies) for r in RACES}
    return out


def add_twist_bones(rig, shares):
    """Two twist bones per lower arm, children of it, at the given shares of
    its length, pointing along it."""
    bpy.context.view_layer.objects.active = rig
    bpy.ops.object.mode_set(mode="EDIT")
    bones = rig.data.edit_bones
    for side in SIDES:
        arm = bones["lowerarm_%s" % side]
        axis = arm.tail - arm.head
        for n, t in enumerate(shares, start=1):
            b = bones.new("lowerarm_twist_%02d_%s" % (n, side))
            b.head = arm.head + axis * t
            b.tail = b.head + axis * 0.1
            b.roll = arm.roll
            b.parent = arm
            b.use_deform = True
    bpy.ops.object.mode_set(mode="OBJECT")


def split_forearm_weights(basemesh, rig, shares):
    """Moves part of each lower-arm weight to the twist bones: hat functions
    over the nodes 0 (lower arm), t1, t2 (the last one flat to the wrist)."""
    pts = positions(basemesh)
    nodes = [0.0] + list(shares)
    for side in SIDES:
        bone = rig.data.bones["lowerarm_%s" % side]
        head = rig.matrix_world @ bone.head_local
        axis = (rig.matrix_world @ bone.tail_local) - head
        length2 = axis.length_squared
        arm_group = basemesh.vertex_groups["lowerarm_%s" % side]
        groups = [arm_group] + [
            basemesh.vertex_groups.get(name) or basemesh.vertex_groups.new(name=name)
            for name in ("lowerarm_twist_%02d_%s" % (n, side) for n in range(1, len(shares) + 1))
        ]
        for v in basemesh.data.vertices:
            w = next((g.weight for g in v.groups if g.group == arm_group.index), 0.0)
            if w <= 0.0:
                continue
            t = max(0.0, min(1.0, (pts[v.index] - head).dot(axis) / length2))
            parts = hat_shares(nodes, t)
            for group, share in zip(groups, parts):
                if share > 0.0:
                    group.add([v.index], w * share, "REPLACE")
                else:
                    group.remove([v.index])


def hat_shares(nodes, t):
    """Shares (summing to 1) of t between neighbouring nodes; past the last
    node everything goes to it."""
    if t >= nodes[-1]:
        return [0.0] * (len(nodes) - 1) + [1.0]
    out = [0.0] * len(nodes)
    for i in range(len(nodes) - 1):
        a, b = nodes[i], nodes[i + 1]
        if a <= t <= b:
            u = (t - a) / (b - a)
            out[i] = 1.0 - u
            out[i + 1] = u
            break
    return out


def add_eye_marker(rig, point):
    """An empty child of the head bone at `point` (world)."""
    marker = bpy.data.objects.new("eye_marker", None)
    bpy.context.scene.collection.objects.link(marker)
    marker.parent = rig
    marker.parent_type = "BONE"
    marker.parent_bone = "head"
    bpy.context.view_layer.update()
    marker.matrix_world = Matrix.Translation(point)
    bpy.context.view_layer.update()
    return marker


def add_build_keys(body, macros, builds):
    """Shape keys build_<name> from the body's positions with each build's
    macros over `macros`; the body is left baked at `macros`."""
    shapes = {}
    for name in sorted(builds):
        set_macros(body, dict(macros, **builds[name]))
        shapes[name] = [body.matrix_world.inverted() @ p for p in positions(body)]
    set_macros(body, macros)
    TargetService.bake_targets(body)
    body.shape_key_add(name="Basis", from_mix=False)
    for name, pts in shapes.items():
        key = body.shape_key_add(name="build_" + name, from_mix=False)
        for v, p in zip(key.data, pts):
            v.co = p


def remove_helpers(body):
    """Deletes every vertex outside the "body" group and MPFB's mask."""
    for m in [m for m in body.modifiers if m.type == "MASK"]:
        body.modifiers.remove(m)
    keep = body.vertex_groups["body"].index
    mesh = bmesh.new()
    mesh.from_mesh(body.data)
    layer = mesh.verts.layers.deform.verify()
    doomed = [v for v in mesh.verts if keep not in v[layer]]
    bmesh.ops.delete(mesh, geom=doomed, context="VERTS")
    mesh.to_mesh(body.data)
    mesh.free()


def export(path, objects):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_skins=True,
        export_animations=False,
        export_yup=True,
    )


def main():
    a = args()
    with open(a.preset, encoding="utf-8") as f:
        preset = json.load(f)
    eye_m = float(preset["eye_height_m"])
    shares = [float(t) for t in preset["twist_at"]]
    ids = sorted(preset["bodies"])
    os.makedirs(a.out, exist_ok=True)

    clear_scene()
    probe = HumanService.create_human()
    solved = {}
    for body_id in ids:
        macros = dict(preset["bodies"][body_id]["macros"])
        macros["height"] = solve_height(probe, macros, eye_m)
        solved[body_id] = macros
    clear_scene()

    neutral = HumanService.create_human()
    set_macros(neutral, mean_macros([solved[i] for i in ids]))
    rig = HumanService.add_builtin_rig(neutral, RIG)
    if rig is None:
        raise SystemExit("rig not created")
    add_twist_bones(rig, shares)

    report = {"eye_height_m": eye_m, "bodies": {}}
    for body_id in ids:
        body = neutral.copy()
        body.data = neutral.data.copy()
        body.name = body_id
        bpy.context.scene.collection.objects.link(body)
        set_macros(body, solved[body_id])
        eye = eye_point(body)
        split_forearm_weights(body, rig, shares)
        add_build_keys(body, solved[body_id], preset.get("builds", {}))
        remove_helpers(body)
        marker = add_eye_marker(rig, eye)
        export(os.path.join(a.out, body_id + ".glb"), [rig, body, marker])
        bpy.data.objects.remove(marker, do_unlink=True)
        report["bodies"][body_id] = {"macros": solved[body_id], "eye_m": [eye.x, eye.y, eye.z]}
        bpy.data.objects.remove(body, do_unlink=True)

    with open(os.path.join(a.out, "bodies.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
        f.write("\n")
    print("RESULT bodies %s, bones %d, eyes %s" % (
        ", ".join(ids), len(rig.data.bones),
        ", ".join("%.4f" % report["bodies"][i]["eye_m"][2] for i in ids)))


main()
