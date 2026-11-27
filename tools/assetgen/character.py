"""Player body models from a character preset, run inside Blender with MPFB:

  tools/blender.sh -b --python tools/assetgen/character.py -- \
      --preset <character preset.json> --out <dir>

Needs the MPFB extension installed in the Blender user resources in use
(BLENDER_USER_RESOURCES). The preset:

  {"eye_height_m": float,
   "twist_at": [t1, t2],            # forearm twist bones, share of the forearm
   "builds": {"slim": {<macro>: value}, "broad": {<macro>: value}},
   "segments": {"<segment>": [<bone>, ...], ...},
   "conform_bones": [<bone>, ...],  # small joints taken from the mean body
   "garments": {"<garment>": {"segments": [...], "offset_m": float,
                              "smooth": iterations}, ...},
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
Helper geometry (everything outside MPFB's "body" group) is removed. The
body is then split into one mesh object per segment (skin_<segment>): a
face goes to the segment of the bone holding most weight over its vertices.
Every bone with weight must belong to exactly one segment.

Vertices weighted to the preset's conform bones (hands and fingers: joints
too small for one rig to fit two different bodies) are blended toward the
mean body by that weight, in the basis and every build key alike, so they
match the shared rig.

Each garment of the base outfit is the body pushed out along its smooth
normals by offset_m and smoothed (to drop details such as toes), with the
build shape keys moved alike, then split the same way: its segments become
meshes <garment>_<segment> with a material named after the garment.

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
## Mesh objects of the bare body: skin_<segment> (not the bone names).
SKIN_PREFIX = "skin_"


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


def add_build_keys(body, macros, builds, correction=None):
    """Shape keys build_<name> from the body's positions with each build's
    macros over `macros`; the body is left baked at `macros`. `correction`
    (one vector per vertex) is added to the basis and every key."""
    shapes = {}
    for name in sorted(builds):
        set_macros(body, dict(macros, **builds[name]))
        shapes[name] = [body.matrix_world.inverted() @ p for p in positions(body)]
    set_macros(body, macros)
    TargetService.bake_targets(body)
    if correction:
        for v, d in zip(body.data.vertices, correction):
            v.co = v.co + d
        for pts in shapes.values():
            for i, d in enumerate(correction):
                pts[i] = pts[i] + d
    body.shape_key_add(name="Basis", from_mix=False)
    for name, pts in shapes.items():
        key = body.shape_key_add(name="build_" + name, from_mix=False)
        for v, p in zip(key.data, pts):
            v.co = p


def conform_correction(body, mean_positions, bones):
    """Per vertex: (mean position - body position) x the vertex's total
    weight on `bones` (0..1)."""
    idx = {body.vertex_groups[b].index for b in bones if b in body.vertex_groups}
    pts = positions(body)
    out = []
    for v, p, m in zip(body.data.vertices, pts, mean_positions):
        w = min(1.0, sum(g.weight for g in v.groups if g.group in idx))
        out.append((m - p) * w)
    return out


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


def split_segments(body, rig, segments, prefix=None):
    """Separates `body` into one object per segment named <prefix><segment>
    (SKIN_PREFIX by default); returns them."""
    prefix = SKIN_PREFIX if prefix is None else prefix
    owner = {}
    for name, bones in segments.items():
        for bone in bones:
            if bone in owner:
                raise SystemExit("bone %s in two segments" % bone)
            owner[bone] = name
    orphans = sorted(b.name for b in rig.data.bones if b.use_deform and b.name not in owner)
    if orphans:
        raise SystemExit("bones in no segment: %s" % ", ".join(orphans))
    names = {g.index: g.name for g in body.vertex_groups}
    order = sorted(segments)
    mesh = bmesh.new()
    mesh.from_mesh(body.data)
    layer = mesh.verts.layers.deform.verify()
    tag = {}
    for face in mesh.faces:
        totals = {}
        for v in face.verts:
            for g, w in v[layer].items():
                bone = names.get(g)
                if bone in owner:
                    totals[owner[bone]] = totals.get(owner[bone], 0.0) + w
        if not totals:
            raise SystemExit("face %d has no segment" % face.index)
        tag[face.index] = order.index(max(totals, key=totals.get))
    mesh.free()
    # Keep the whole body's smooth normals on every part: no shading seams.
    body.data.normals_split_custom_set_from_vertices([v.normal.copy() for v in body.data.vertices])
    body.data.materials.clear()
    tags = [bpy.data.materials.new(name="segment:" + name) for name in order]
    for mat in tags:
        body.data.materials.append(mat)
    for poly in body.data.polygons:
        poly.material_index = tag[poly.index]
    bpy.ops.object.select_all(action="DESELECT")
    body.select_set(True)
    bpy.context.view_layer.objects.active = body
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="MATERIAL")
    bpy.ops.object.mode_set(mode="OBJECT")
    parts = [o for o in bpy.context.selected_objects if o.type == "MESH"]
    out = []
    for part in parts:
        mats = [m for m in part.data.materials if m is not None]
        if len(mats) != 1:
            raise SystemExit("segment split failed")
        part.name = prefix + mats[0].name.removeprefix("segment:")
        part.data.name = part.name
        part.data.materials.clear()
        out.append(part)
    for mat in tags:
        bpy.data.materials.remove(mat)
    return out


def garment_parts(body, rig, preset):
    """Mesh objects <garment>_<segment> of every garment of the base outfit."""
    out = []
    for name in sorted(preset.get("garments", {})):
        spec = preset["garments"][name]
        shell = body.copy()
        shell.data = body.data.copy()
        bpy.context.scene.collection.objects.link(shell)
        inflate(shell, float(spec["offset_m"]), int(spec.get("smooth", 0)))
        material = bpy.data.materials.get(name) or bpy.data.materials.new(name=name)
        keep = set(spec["segments"])
        for part in split_segments(shell, rig, preset["segments"], name + "_"):
            if part.name.removeprefix(name + "_") in keep:
                part.data.materials.append(material)
                out.append(part)
            else:
                bpy.data.objects.remove(part, do_unlink=True)
    return out


def inflate(obj, offset_m, smooth):
    """Moves every vertex out along its smooth normal by offset_m, then
    smooths the result `smooth` times (Laplacian, volume kept); every shape key gets the same move,
    so its offset from the basis stays."""
    mesh = obj.data
    base = [v.co.copy() for v in mesh.vertices]
    target = [v.co + v.normal * offset_m for v in mesh.vertices]
    if smooth > 0:
        work = bmesh.new()
        work.from_mesh(mesh)
        work.verts.ensure_lookup_table()
        for v, p in zip(work.verts, target):
            v.co = p
        inner = [v for v in work.verts if not v.is_boundary]
        for _ in range(smooth):
            bmesh.ops.smooth_laplacian_vert(
                work, verts=inner, lambda_factor=1.0, lambda_border=0.0,
                use_x=True, use_y=True, use_z=True, preserve_volume=True,
            )
        target = [v.co.copy() for v in work.verts]
        work.free()
    move = [t - b for t, b in zip(target, base)]
    if mesh.shape_keys:
        for key in mesh.shape_keys.key_blocks:
            for d, m in zip(key.data, move):
                d.co = d.co + m
    for v, m in zip(mesh.vertices, move):
        v.co = v.co + m


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
    mean_positions = positions(neutral)
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
        correction = conform_correction(body, mean_positions, preset.get("conform_bones", []))
        add_build_keys(body, solved[body_id], preset.get("builds", {}), correction)
        remove_helpers(body)
        parts = garment_parts(body, rig, preset) + split_segments(body, rig, preset["segments"])
        marker = add_eye_marker(rig, eye)
        export(os.path.join(a.out, body_id + ".glb"), [rig, marker] + parts)
        bpy.data.objects.remove(marker, do_unlink=True)
        report["bodies"][body_id] = {
            "macros": solved[body_id],
            "eye_m": [eye.x, eye.y, eye.z],
            "segments": {p.name: len(p.data.polygons) for p in parts},
        }
        for part in parts:
            bpy.data.objects.remove(part, do_unlink=True)

    with open(os.path.join(a.out, "bodies.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1, sort_keys=True)
        f.write("\n")
    print("RESULT bodies %s, bones %d, eyes %s" % (
        ", ".join(ids), len(rig.data.bones),
        ", ".join("%.4f" % report["bodies"][i]["eye_m"][2] for i in ids)))


main()
