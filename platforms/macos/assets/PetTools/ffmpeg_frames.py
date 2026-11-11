#!/usr/bin/env python3
"""Export a short motion strip from the source video selected in Pet Studio.
Run: python3 ffmpeg_frames.py /path/to/job.json --ffmpeg /path/to/ffmpeg
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('job', type=Path)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--fps', type=float, default=6)
    parser.add_argument('--seconds', type=float, default=2)
    args = parser.parse_args()
    job = json.loads(args.job.read_text())
    source = Path(job.get('source', ''))
    if not source.is_file():
        parser.error('Select a video source in Pet Studio first.')
    if not 1 <= args.fps <= 30 or not 0 < args.seconds <= 12:
        parser.error('Use 1–30 fps and up to 12 seconds.')
    executable = shutil.which(args.ffmpeg)
    if not executable:
        parser.error('FFmpeg not found; pass --ffmpeg /absolute/path/to/ffmpeg.')
    output = args.job.parent / 'output'
    output.mkdir(exist_ok=True)
    subprocess.run([executable, '-nostdin', '-v', 'error', '-y', '-i', str(source),
                    '-t', str(args.seconds), '-vf', f'fps={args.fps},scale=768:768:force_original_aspect_ratio=decrease',
                    str(output / 'frame-%03d.png')], check=True, timeout=150)
    print('Frames exported. Choose representative poses and assign roles in Pet Studio; this does not create a video renderer.')


if __name__ == '__main__':
    main()
