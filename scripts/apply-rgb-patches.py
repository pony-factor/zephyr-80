#!/usr/bin/env python3
"""Apply the shared RGB patches atomically to an upstream ZMK checkout."""
import argparse
import difflib
from pathlib import Path
import subprocess
import tempfile


def apply_patches(zmk: Path) -> None:
    names = ['app/Kconfig', 'app/src/rgb_underglow.c']
    originals = {name: (zmk / name).read_bytes() for name in names}
    profile = 'community-rgb' if b'config EXPERIMENTAL_RGB_LAYER' in originals[names[0]] else 'stock'
    patch_root = Path(__file__).resolve().parents[1] / 'patches' / profile
    patches = [patch_root / name for name in ['rgb-off-on-usb-suspend.patch', 'rgb-fade-off.patch']]
    with tempfile.TemporaryDirectory(prefix='glove80-rgb-') as temporary:
        scratch = Path(temporary)
        def reset():
            for name, content in originals.items():
                path = scratch / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
        reset()
        # Reverse in dependency order to recognize an already-patched checkout.
        already_applied = True
        for patch in reversed(patches):
            result = subprocess.run(['git', 'apply', '--reverse', str(patch)], cwd=scratch, capture_output=True)
            if result.returncode:
                already_applied = False
                break
        if already_applied:
            print(f'RGB patches already applied ({profile})')
            return
        reset()
        for patch in patches:
            # Accept a suspend patch applied previously without the fade patch.
            result = subprocess.run(['git', 'apply', '--check', str(patch)], cwd=scratch, capture_output=True)
            if result.returncode:
                reverse = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)], cwd=scratch, capture_output=True)
                if reverse.returncode == 0:
                    continue
                raise RuntimeError(f'{patch.name} does not match this ZMK source; no source files were changed.\n' + result.stderr.decode())
            subprocess.run(['git', 'apply', str(patch)], cwd=scratch, check=True)
        combined = ''.join(''.join(difflib.unified_diff(
            originals[name].decode().splitlines(True), (scratch / name).read_text().splitlines(True),
            fromfile='a/' + name, tofile='b/' + name)) for name in names)
        # Git applies the combined change as one operation, preserving unrelated edits.
        if combined:
            subprocess.run(['git', 'apply', '-'], input=combined.encode(), cwd=zmk, check=True)
    print(f'Applied color-independent suspend and fade patches ({profile})')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('zmk', type=Path, help='Path to the upstream ZMK checkout')
    arguments = parser.parse_args()
    try:
        apply_patches(arguments.zmk.resolve())
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + '\n')
