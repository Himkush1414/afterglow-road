"""Billboard atlas bake for tree models, run inside Blender (22 §3, 06 §A3 T3):

  tools/blender.sh -b --python tools/assetgen/billboards.py -- \
      --preset <trees preset.json> --trees <trees.json> --models <dir> \
      --textures <texture set dir> --size <px> --raw <dir>

Reads <models>/<category>_models.json (written by trees.py: each model's
cell, side and bottom), places every model's T0 mesh in its cell, scaled so
its billboard square fills the cell, and renders the whole atlas twice with
an orthographic camera looking along +Y (the side the T3 quad faces):

- <raw>/colour.png: unlit albedo (bark or leaf texture x baked vertex AO),
  sRGB, alpha = coverage (leaf alpha cut at 0.5);
- <raw>/normal.png: the authored normals in the quad's frame (x right, y up,
  z toward the viewer), encoded n * 0.5 + 0.5, linear, same alpha.

Textures are <textures>/<category>_<set>_bark_ah.png and
<category>_<set>_leaves_ca.png, with the sets named by each model's shape
(bark_set, leaf_set). tools/assetgen/billboard_atlas.py turns the raw
renders into the hi and lo atlas files. Deterministic for its inputs.
"""
import json
import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
from tools.assetgen.shapes import shape_for  # noqa: E402  (Blender runs this file as a script)

SAMPLES = 16
ALPHA_CUT = 0.5


def args():
    a = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    return {k: a[a.index("--" + k) + 1] for k in ("preset", "trees", "models", "textures", "size", "raw")}


def image(path, colour):
    img = bpy.data.images.load(path, check_existing=True)
    img.colorspace_settings.name = "sRGB" if colour else "Non-Color"
    img.alpha_mode = "CHANNEL_PACKED"
    return img


def node_material(name, tex_path, leaves, mode, attr):
    """An emission material: mode "colour" (texture x vertex AO) or "normal"
    (authored normal, back-face flip undone, in the bake camera frame)."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    emit = nt.nodes.new("ShaderNodeEmission")
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = image(tex_path, True)
    if mode == "colour":
        ao = nt.nodes.new("ShaderNodeAttribute")
        ao.attribute_name = attr
        mul = nt.nodes.new("ShaderNodeMix")
        mul.data_type = "RGBA"
        mul.blend_type = "MULTIPLY"
        mul.inputs["Factor"].default_value = 1.0
        nt.links.new(tex.outputs["Color"], mul.inputs[6])
        nt.links.new(ao.outputs["Alpha"], mul.inputs[7])
        nt.links.new(mul.outputs[2], emit.inputs["Color"])
    else:
        geo = nt.nodes.new("ShaderNodeNewGeometry")
        sign = nt.nodes.new("ShaderNodeMath")  # 1 - 2 * backfacing
        sign.operation = "MULTIPLY_ADD"
        sign.inputs[1].default_value = -2.0
        sign.inputs[2].default_value = 1.0
        nt.links.new(geo.outputs["Backfacing"], sign.inputs[0])
        unflip = nt.nodes.new("ShaderNodeVectorMath")
        unflip.operation = "SCALE"
        nt.links.new(geo.outputs["Normal"], unflip.inputs[0])
        nt.links.new(sign.outputs[0], unflip.inputs["Scale"])
        sep = nt.nodes.new("ShaderNodeSeparateXYZ")
        nt.links.new(unflip.outputs[0], sep.inputs[0])
        neg = nt.nodes.new("ShaderNodeMath")
        neg.operation = "MULTIPLY"
        neg.inputs[1].default_value = -1.0
        nt.links.new(sep.outputs["Y"], neg.inputs[0])
        comb = nt.nodes.new("ShaderNodeCombineXYZ")  # (x, z, -y): right, up, toward the camera
        nt.links.new(sep.outputs["X"], comb.inputs["X"])
        nt.links.new(sep.outputs["Z"], comb.inputs["Y"])
        nt.links.new(neg.outputs[0], comb.inputs["Z"])
        enc = nt.nodes.new("ShaderNodeVectorMath")
        enc.operation = "MULTIPLY_ADD"
        enc.inputs[1].default_value = (0.5, 0.5, 0.5)
        enc.inputs[2].default_value = (0.5, 0.5, 0.5)
        nt.links.new(comb.outputs[0], enc.inputs[0])
        nt.links.new(enc.outputs[0], emit.inputs["Color"])
    if leaves:
        cut = nt.nodes.new("ShaderNodeMath")
        cut.operation = "GREATER_THAN"
        cut.inputs[1].default_value = ALPHA_CUT
        nt.links.new(tex.outputs["Alpha"], cut.inputs[0])
        mix = nt.nodes.new("ShaderNodeMixShader")
        clear = nt.nodes.new("ShaderNodeBsdfTransparent")
        nt.links.new(cut.outputs[0], mix.inputs[0])
        nt.links.new(clear.outputs[0], mix.inputs[1])
        nt.links.new(emit.outputs[0], mix.inputs[2])
        nt.links.new(mix.outputs[0], out.inputs["Surface"])
    else:
        nt.links.new(emit.outputs[0], out.inputs["Surface"])
    return m


def place(preset, defs, models_dir, manifest):
    """Imports each model's T0, puts it in its cell; returns
    [(object, shape, [slot is leaves])]."""
    g = manifest["grid"]
    by_stem = {}
    for model in preset["models"]:
        tree = defs[model["id"]]
        for n in range(1, tree["variants"] + 1):
            by_stem[f"{preset['category']}_{model['id']}_{n}"] = shape_for(preset, model, tree)
    placed = []
    for stem, entry in sorted(manifest["models"].items(), key=lambda kv: kv[1]["cell"]):
        bpy.ops.import_scene.gltf(filepath=os.path.join(models_dir, stem + ".glb"))
        objs = list(bpy.context.selected_objects)
        keep = next(o for o in objs if o.name.startswith(stem + "_t0"))
        for o in objs:
            if o is not keep:
                bpy.data.objects.remove(o)
        keep.parent = None
        col, row = entry["cell"] % g, entry["cell"] // g
        k = 1.0 / entry["side_m"]
        keep.rotation_euler = (0.0, 0.0, 0.0)  # the importer's Y-up turn is baked into the mesh data
        keep.scale = (k, k, k)
        keep.location = (col - g / 2 + 0.5, 0.0, (g / 2 - row - 1) - entry["bottom_m"] * k)
        kinds = [slot.material.name.startswith("leaves") for slot in keep.material_slots]  # before any reassignment
        placed.append((keep, by_stem[stem], kinds))
    return placed


def assign(placed, preset, textures, mode):
    cat = preset["category"]
    cache = {}
    for obj, shape, kinds in placed:
        attr = obj.data.color_attributes[0].name
        mats = []
        for leaves in kinds:
            tset = shape["leaf_set"] if leaves else shape["bark_set"]
            key = (tset, leaves, mode, attr)
            if key not in cache:
                tex = os.path.join(textures, f"{cat}_{tset}_{'leaves_ca' if leaves else 'bark_ah'}.png")
                cache[key] = node_material(f"bake_{mode}_{tset}_{'leaves' if leaves else 'bark'}", tex, leaves, mode, attr)
            mats.append(cache[key])
        for slot, m in zip(obj.material_slots, mats):
            slot.material = m


def render(path, size, grid, view):
    s = bpy.context.scene
    s.render.engine = "CYCLES"
    s.cycles.device = "CPU"
    s.cycles.samples = SAMPLES
    s.cycles.use_adaptive_sampling = False
    s.cycles.use_denoising = False
    s.cycles.seed = 0
    s.cycles.max_bounces = 0
    s.cycles.transparent_max_bounces = 64
    s.cycles.filter_width = 1.0
    s.render.film_transparent = True
    s.render.resolution_x = s.render.resolution_y = size
    s.render.resolution_percentage = 100
    s.render.image_settings.file_format = "PNG"
    s.render.image_settings.color_mode = "RGBA"
    s.render.image_settings.color_depth = "8"
    s.view_settings.view_transform = view
    s.view_settings.look = "None"
    s.view_settings.exposure = 0.0
    s.view_settings.gamma = 1.0
    s.world = s.world or bpy.data.worlds.new("bake")
    s.world.use_nodes = False
    s.world.color = (0.0, 0.0, 0.0)
    cam = s.camera
    if cam is None:
        cam = bpy.data.objects.new("bake_camera", bpy.data.cameras.new("bake_camera"))
        s.collection.objects.link(cam)
        s.camera = cam
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = grid
    cam.data.clip_start, cam.data.clip_end = 0.1, 200.0
    cam.location = (0.0, -100.0, 0.0)
    cam.rotation_euler = (math.radians(90.0), 0.0, 0.0)
    s.render.filepath = path
    bpy.ops.render.render(write_still=True)


def main():
    a = args()
    with open(a["preset"], encoding="utf-8") as f:
        preset = json.load(f)
    with open(a["trees"], encoding="utf-8") as f:
        defs = {t["id"]: t for t in json.load(f)["trees"]}
    with open(os.path.join(a["models"], f"{preset['category']}_models.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    os.makedirs(a["raw"], exist_ok=True)
    placed = place(preset, defs, a["models"], manifest)
    size = int(a["size"])
    for mode, view in (("colour", "Standard"), ("normal", "Raw")):
        assign(placed, preset, a["textures"], mode)
        render(os.path.join(a["raw"], f"{mode}.png"), size, manifest["grid"], view)
        print(f"billboards: rendered {mode}.png ({len(placed)} models, {size} px)")


main()
