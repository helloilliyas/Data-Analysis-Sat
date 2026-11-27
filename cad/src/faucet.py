"""Single-lever gooseneck kitchen faucet. Units: mm, +Z up, spout reaches along +X."""
import build123d as bd
from cad import model

CHROME = "#c9ced6"
DARK = "#3a3d42"

# Main dimensions
BASE_R, BASE_H = 30, 8          # deck flange
BODY_R, BODY_H = 20, 70         # valve body
SPOUT_R, SPOUT_BORE = 11, 8     # spout tube outer / inner radius
RISE = 190                      # height where the gooseneck arc starts
REACH = 150                     # horizontal distance body axis -> outlet
DROP = 35                       # straight run down to the outlet
LEVER_L = 75


def base():
    flange = bd.Cylinder(BASE_R, BASE_H, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    flange = bd.fillet(flange.edges().group_by(bd.Axis.Z)[-1], 3)
    flange.label, flange.color = "base", CHROME
    return flange


def body():
    b = bd.Pos(0, 0, BASE_H) * bd.Cylinder(
        BODY_R, BODY_H, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)
    )
    b = bd.fillet(b.edges().group_by(bd.Axis.Z)[-1], 6)
    b.label, b.color = "body", CHROME
    return b


def spout():
    z0 = BASE_H + BODY_H
    r = REACH / 2
    up = bd.Line((0, 0, z0), (0, 0, RISE))
    arc = bd.ThreePointArc((0, 0, RISE), (r, 0, RISE + r), (REACH, 0, RISE))
    down = bd.Line((REACH, 0, RISE), (REACH, 0, RISE - DROP))
    path = bd.Wire([up, arc, down])
    ring = bd.Pos(0, 0, z0) * (bd.Circle(SPOUT_R) - bd.Circle(SPOUT_BORE))
    tube = bd.sweep(ring, path=path)
    tube.label, tube.color = "spout", CHROME
    return tube


def aerator():
    z = RISE - DROP
    a = bd.Pos(REACH, 0, z - 14) * (
        bd.Cylinder(SPOUT_R + 2, 14, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
        - bd.Cylinder(SPOUT_BORE, 14, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    )
    a.label, a.color = "aerator", DARK
    return a


def handle():
    zc = BASE_H + BODY_H * 0.55
    # hub sticking out of the body side (+Y)
    hub = bd.Pos(0, BODY_R - 2, zc) * bd.Rot(-90, 0, 0) * bd.Cylinder(
        13, 22, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)
    )
    # lever: tapered bar rising from the hub, tilted outwards
    bar = bd.Box(10, 7, LEVER_L, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN))
    bar = bd.fillet(bar.edges().filter_by(bd.Axis.Z), 3)
    lever = bd.Pos(0, BODY_R + 13, zc) * bd.Rot(-25, 0, 0) * bar
    core = bd.Pos(0, 0, BASE_H) * bd.Cylinder(
        BODY_R, BODY_H, align=(bd.Align.CENTER, bd.Align.CENTER, bd.Align.MIN)
    )
    h = hub + lever - core  # hub seats against the body wall
    h.label, h.color = "handle", CHROME
    return h


@model
def faucet():
    return bd.Compound(label="faucet", children=[base(), body(), spout(), aerator(), handle()])


if __name__ == "__main__":
    faucet()
