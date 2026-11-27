"""Widespread two-handle bathroom faucet (8 in / 203 mm handle centres).

Units: mm, +Z up, deck surface at z=0. The spout reaches towards -Y (the user),
the hot handle sits at -X and the cold handle at +X.
"""
import math

import build123d as bd
from bd_materials import metals
from cad import model

MIN_Z = (bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)

# Main dimensions
SPREAD = 203.2 / 2       # handle offset from the spout axis
TUBE_R, BORE_R = 11.0, 8.0
NECK_Z = 46.0            # where the spout tube leaves its base
RISE_Z = 118.0           # where the gooseneck arc starts
ARC_R = 56.0             # gooseneck radius
ARC_DEG = 158.0          # how far the arc turns before the outlet
TIP_L = 24.0             # straight run to the outlet
HUB_Z = 27.5             # top of a handle base + indicator ring
LEVER_L = 70.0


def chrome(part, label):
    part.label = label
    look = metals.stainless()
    look.pbr = look.pbr.override(roughness=0.04)
    part.material = look
    part.color = "#eceef1"
    return part


def revolved(points_then_spline):
    """Revolve a closed (r, z) profile about Z. The profile is drawn in the XZ plane."""
    face = bd.Plane.XZ * bd.make_face(points_then_spline)
    return bd.revolve(face, bd.Axis.Z)


def bell(foot_r, neck_r, height):
    """A flared escutcheon: flat foot on the deck, concave sweep up to a neck."""
    edges = [
        bd.Line((0, 0), (foot_r, 0)),
        bd.Line((foot_r, 0), (foot_r, 2.5)),
        bd.Spline(
            [(foot_r, 2.5), (foot_r * 0.66, 7.0), (neck_r * 1.12, height * 0.55), (neck_r, height)],
            tangents=[(-1, 0.25), (0, 1)],
        ),
        bd.Line((neck_r, height), (0, height)),
        bd.Line((0, height), (0, 0)),
    ]
    return revolved(edges)


def spout_path():
    """Centre line of the spout tube, in the YZ plane, and its outlet point + direction."""
    t_end = math.radians(ARC_DEG)

    def on_arc(t):
        return (0, -ARC_R + ARC_R * math.cos(t), RISE_Z + ARC_R * math.sin(t))

    end = on_arc(t_end)
    tangent = (0, -math.sin(t_end), math.cos(t_end))
    tip = tuple(e + TIP_L * d for e, d in zip(end, tangent))
    path = bd.Wire(
        [
            bd.Line((0, 0, NECK_Z), (0, 0, RISE_Z)),
            bd.ThreePointArc(on_arc(0), on_arc(t_end / 2), end),
            bd.Line(end, tip),
        ]
    )
    return path, tip, tangent


def spout_base():
    return chrome(bell(27, TUBE_R + 1.0, NECK_Z), "spout_base")


def spout():
    path, _, _ = spout_path()
    ring = bd.Pos(0, 0, NECK_Z) * (bd.Circle(TUBE_R) - bd.Circle(BORE_R))
    return chrome(bd.sweep(ring, path=path), "spout")


def aerator():
    """Dark insert recessed inside the outlet."""
    _, tip, tangent = spout_path()
    back = tuple(p - 9.0 * d for p, d in zip(tip, tangent))
    disc = bd.Plane(origin=back, z_dir=tangent) * bd.Cylinder(BORE_R, 7.0, align=MIN_Z)
    disc.label, disc.color = "aerator", "#1c1d20"
    return disc


def handle_base():
    return chrome(bell(24, 12.5, HUB_Z - 1.5), "base")


def indicator(color):
    ring = bd.Pos(0, 0, HUB_Z - 1.5) * bd.Cylinder(12.5, 1.5, align=MIN_Z)
    ring.label, ring.color = "indicator", color
    return ring


def lever(direction):
    """Hub and tapered lever; `direction` is +1 (points to +X) or -1."""
    hub = bd.Pos(0, 0, HUB_Z) * bd.Cylinder(12.5, 17, align=MIN_Z)
    hub = bd.fillet(hub.edges().group_by(bd.Axis.Z)[-1], 5)
    zc = HUB_Z + 9.0
    lift = 0.16  # the lever climbs slightly towards its tip
    sections = []
    for x, wide, thick in ((3, 7.5, 5.0), (LEVER_L * 0.72, 6.2, 3.6), (LEVER_L, 4.6, 2.8)):
        plane = bd.Plane(
            origin=(direction * x, 0, zc + x * lift), x_dir=(0, 1, 0), z_dir=(direction, 0, lift)
        )
        sections.append(plane * bd.Ellipse(wide, thick))
    arm = bd.loft(sections)
    return chrome(hub + arm, "lever")


def handle(direction, color, label):
    parts = [handle_base(), indicator(color), lever(direction)]
    group = bd.Compound(label=label, children=parts)
    return bd.Pos(direction * SPREAD, 0, 0) * group


@model
def faucet():
    centre = bd.Compound(label="spout_assembly", children=[spout_base(), spout(), aerator()])
    return bd.Compound(
        label="faucet",
        children=[centre, handle(-1, "#c8322b", "handle_hot"), handle(1, "#2b62c8", "handle_cold")],
    )


if __name__ == "__main__":
    faucet()
