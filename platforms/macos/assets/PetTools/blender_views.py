"""Render a local .blend scene with transparency using its existing camera.
Run: Blender --background --python blender_views.py -- /path/to/job.json
Only use a .blend file you trust. This recipe disables auto-run when loading it.
"""
import json
import math
from pathlib import Path
import sys
import bpy

job_path = Path(sys.argv[sys.argv.index('--') + 1]).resolve()
job = json.loads(job_path.read_text())
source = Path(job.get('source', ''))
if source.suffix.lower() != '.blend' or not source.is_file():
    raise ValueError('Select a .blend source in Pet Studio first.')
bpy.ops.wm.open_mainfile(filepath=str(source), use_scripts=False)
scene = bpy.context.scene
if not scene.camera:
    raise ValueError('The Blender scene needs an active camera framing the character.')
scene.render.film_transparent = True
scene.render.resolution_x = 768
scene.render.resolution_y = 768
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
output = job_path.parent / 'output'
output.mkdir(exist_ok=True)
# Render existing scene poses. Preserve rig / camera / lighting; no model rotation guessing.
start, end = scene.frame_start, scene.frame_end
frames = sorted(set([start, start + (end - start) // 3, start + 2 * (end - start) // 3, end]))
for i, frame in enumerate(frames):
    scene.frame_set(frame)
    scene.render.filepath = str(output / ('idle.png' if i == 0 else f'pose-{i}.png'))
    bpy.ops.render.render(write_still=True)
print('Transparent poses exported. Import images and assign roles in Pet Studio.')
