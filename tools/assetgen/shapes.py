"""Tree shape presets (shared by trees.py inside Blender and validate.py).

A preset's "species" maps a shape name to shape numbers. A preset model uses
the shape named by its "shape", else its tree's species. A shape's "sizes"
maps a tree size to overrides merged over the shape: objects merge key by
key, lists of objects of equal length merge item by item, anything else
replaces.
"""


def merged(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = merged(out[k], v) if k in out else v
        return out
    if isinstance(base, list) and isinstance(over, list) and len(base) == len(over) and all(isinstance(x, dict) for x in base + over):
        return [merged(a, b) for a, b in zip(base, over)]
    return over


def shape_for(preset, model, tree):
    """The shape numbers for one preset model of a tree definition."""
    sp = preset["species"][model.get("shape", tree["species"])]
    return merged({k: v for k, v in sp.items() if k != "sizes"}, sp.get("sizes", {}).get(tree["size"], {}))
