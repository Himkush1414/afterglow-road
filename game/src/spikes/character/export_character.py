"""Spike P1-07 (assumption A-07): build the default MPFB human with the
game-engine rig in headless Blender and export it as a binary glTF.

Usage:
  blender -b --python export_character.py -- OUT.glb

Needs the MPFB extension enabled in the Blender user resources in use.
Prints one RESULT line with the bone count and the mesh height.
"""

import sys

import bpy
from bl_ext.blender_org.mpfb.services.humanservice import HumanService


def main() -> None:
    out = sys.argv[sys.argv.index("--") + 1]
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)

    basemesh = HumanService.create_human()
    rig = HumanService.add_builtin_rig(basemesh, "game_engine")
    if rig is None:
        raise SystemExit("rig not created")

    bpy.ops.export_scene.gltf(
        filepath=out,
        export_format="GLB",
        export_apply=True,
        export_skins=True,
        export_animations=False,
        export_yup=True,
    )
    zs = [(basemesh.matrix_world @ v.co).z for v in basemesh.data.vertices]
    print(
        "RESULT bones %d, mesh height %.3f m, shape keys %d, exported %s"
        % (
            len(rig.data.bones),
            max(zs) - min(zs),
            len(basemesh.data.shape_keys.key_blocks) if basemesh.data.shape_keys else 0,
            out,
        )
    )


main()
