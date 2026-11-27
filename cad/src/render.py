# Photoreal still of the faucet on a marble vanity.  cad run src/render.py [draft]
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

from cad.blender import load

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "out"
DRAFT = "draft" in sys.argv[1:]

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
model = load(OUT / "faucet_render.glb")
for obj in bpy.data.objects:
    if obj.type == "MESH":
        for poly in obj.data.polygons:
            poly.use_smooth = True

W, H = (800, 600) if DRAFT else (2000, 1500)
scene.render.resolution_x, scene.render.resolution_y = W, H

# --- camera -----------------------------------------------------------------
aim = bpy.data.objects.new("aim", None)
aim.location = model.center + Vector((0, -0.03, -0.015))
camera = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
camera.data.lens = 80
view = math.tan(camera.data.angle / 2) * min(1, H / W)
distance = model.size.length / 2 / view * 0.74
camera.location = aim.location + distance * Vector((0.62, -1, 0.42)).normalized()
camera.constraints.new("TRACK_TO").target = aim
camera.data.dof.use_dof = True
camera.data.dof.focus_object = aim
camera.data.dof.aperture_fstop = 8.0
for item in (aim, camera):
    scene.collection.objects.link(item)
scene.camera = camera


# --- materials ---------------------------------------------------------------
def marble():
    mat = bpy.data.materials.new("marble")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    coords = nt.nodes.new("ShaderNodeTexCoord")
    warp = nt.nodes.new("ShaderNodeTexNoise")
    warp.inputs["Scale"].default_value = 2.2
    warp.inputs["Detail"].default_value = 8
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "VECTOR"
    mix.inputs["Factor"].default_value = 0.35
    veins = nt.nodes.new("ShaderNodeTexNoise")
    veins.inputs["Scale"].default_value = 3.0
    veins.inputs["Detail"].default_value = 12
    veins.inputs["Roughness"].default_value = 0.62
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    stops = ramp.color_ramp.elements
    stops[0].position, stops[0].color = 0.47, (0.93, 0.92, 0.90, 1)
    stops[1].position, stops[1].color = 0.53, (0.93, 0.92, 0.90, 1)
    vein = stops.new(0.50)
    vein.color = (0.42, 0.43, 0.45, 1)
    nt.links.new(coords.outputs["Object"], warp.inputs["Vector"])
    nt.links.new(coords.outputs["Object"], mix.inputs["A"])
    nt.links.new(warp.outputs["Color"], mix.inputs["B"])
    nt.links.new(mix.outputs["Result"], veins.inputs["Vector"])
    nt.links.new(veins.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.08
    bsdf.inputs["Coat Weight"].default_value = 0.4
    return mat


def plain(name, color, roughness):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


# --- set: vanity top and wall -------------------------------------------------
deck_z = model.box[0].z
bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0, deck_z))
bpy.context.object.data.materials.append(marble())
bpy.ops.mesh.primitive_plane_add(size=4, location=(0, 0.16, deck_z + 2), rotation=(math.pi / 2, 0, 0))
bpy.context.object.data.materials.append(plain("wall", (0.16, 0.20, 0.21), 0.45))


# --- lights -------------------------------------------------------------------
def softbox(name, direction, power, size, reach=1.0):
    light = bpy.data.objects.new(name, bpy.data.lights.new(name, "AREA"))
    d = distance * reach
    light.data.energy, light.data.size = power * d**2, size * d
    light.location = model.center + d * Vector(direction).normalized()
    light.constraints.new("TRACK_TO").target = aim
    scene.collection.objects.link(light)


softbox("key", (1.0, -0.7, 1.2), 5.0, 0.9)
softbox("fill", (-1.2, -1.0, 0.5), 1.2, 1.2)
softbox("top", (0.0, -0.1, 1.0), 2.5, 1.4, reach=0.8)
softbox("strip", (-0.4, -1.0, 0.15), 1.2, 0.25)

scene.world = bpy.data.worlds.new("world")
scene.world.use_nodes = True
bg = scene.world.node_tree.nodes["Background"]
bg.inputs["Color"].default_value = (0.20, 0.22, 0.25, 1)
bg.inputs["Strength"].default_value = 0.6

# --- render -------------------------------------------------------------------
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.render.compositor_device = "CPU"
scene.cycles.samples = 16 if DRAFT else 96
scene.cycles.use_denoising, scene.cycles.denoiser = True, "OPENIMAGEDENOISE"
scene.render.filepath = str(OUT / ("faucet_draft.png" if DRAFT else "faucet_render.png"))
print("cycles device:", scene.cycles.device, "samples:", scene.cycles.samples)
bpy.ops.render.render(write_still=True)
