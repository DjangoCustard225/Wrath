"""Render the PNG fallback, or compile the adaptive icon using Xcode's actool.

Compiled output can be moved from a Mac to Linux and supplied to Build.py.
The source fingerprint prevents silently packaging an older icon.
"""
from pathlib import Path
import argparse
import ctypes
import ctypes.util
import hashlib
import os
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'AppIcon.icon'


def source_hash():
    digest = hashlib.sha256()
    for path in sorted(SOURCE.rglob('*')):
        if path.is_file():
            digest.update(path.relative_to(SOURCE).as_posix().encode())
            digest.update(path.read_bytes())
    return digest.hexdigest()


def render_svg(source, output, size=1024):
    """Use librsvg's SVG renderer; no Python imaging dependencies required."""
    if shutil.which('rsvg-convert'):
        subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size),
                        '-o', str(output), str(source)], check=True)
        return
    rsvg = ctypes.CDLL(ctypes.util.find_library('rsvg-2') or 'librsvg-2.so.2')
    cairo = ctypes.CDLL(ctypes.util.find_library('cairo') or 'libcairo.so.2')
    gobject = ctypes.CDLL(ctypes.util.find_library('gobject-2.0') or 'libgobject-2.0.so.0')
    pointer = ctypes.c_void_p
    rsvg.rsvg_handle_new_from_file.argtypes = [ctypes.c_char_p, pointer]
    rsvg.rsvg_handle_new_from_file.restype = pointer
    rsvg.rsvg_handle_render_document.argtypes = [pointer, pointer, pointer, pointer]
    rsvg.rsvg_handle_render_document.restype = ctypes.c_int
    cairo.cairo_image_surface_create.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    cairo.cairo_image_surface_create.restype = pointer
    cairo.cairo_create.argtypes = [pointer]
    cairo.cairo_create.restype = pointer
    cairo.cairo_surface_write_to_png.argtypes = [pointer, ctypes.c_char_p]
    cairo.cairo_surface_write_to_png.restype = ctypes.c_int
    cairo.cairo_destroy.argtypes = [pointer]
    cairo.cairo_surface_destroy.argtypes = [pointer]
    gobject.g_object_unref.argtypes = [pointer]

    class Rectangle(ctypes.Structure):
        _fields_ = [(name, ctypes.c_double) for name in ('x', 'y', 'width', 'height')]

    handle = rsvg.rsvg_handle_new_from_file(str(source).encode(), None)
    if not handle:
        raise RuntimeError(f'Cannot read SVG: {source}')
    surface = cairo.cairo_image_surface_create(0, size, size)
    context = cairo.cairo_create(surface)
    try:
        viewport = Rectangle(0, 0, size, size)
        if not rsvg.rsvg_handle_render_document(handle, context, ctypes.byref(viewport), None):
            raise RuntimeError('SVG rendering failed')
        if cairo.cairo_surface_write_to_png(surface, str(output).encode()) != 0:
            raise RuntimeError('PNG export failed')
    finally:
        cairo.cairo_destroy(context)
        cairo.cairo_surface_destroy(surface)
        gobject.g_object_unref(handle)


def compile_icon(output):
    output = Path(output)
    if output.exists() and any(output.iterdir()):
        raise RuntimeError(f'Choose an empty output directory: {output}')
    bundle = output / 'Bundle'
    bundle.mkdir(parents=True, exist_ok=True)
    subprocess.run(['xcrun', 'actool', str(SOURCE), '--compile', str(bundle),
                    '--app-icon', 'AppIcon', '--platform', 'iphoneos',
                    '--target-device', 'iphone', '--target-device', 'ipad',
                    '--minimum-deployment-target', '27.0',
                    '--bundle-identifier', 'app.wrath.downloader',
                    '--output-partial-info-plist', str(output / 'IconInfo.plist'),
                    '--output-format', 'human-readable-text', '--warnings', '--errors'], check=True)
    if not (bundle / 'Assets.car').is_file():
        raise RuntimeError('actool did not produce Assets.car')
    (output / 'Source.sha256').write_text(source_hash() + '\n')
    print(f'Compiled adaptive icon: {output}')


def install_icon(app, assets):
    assets = Path(assets)
    if (assets / 'Source.sha256').read_text().strip() != source_hash():
        raise RuntimeError('Compiled icon is stale; recompile AppIcon.icon with actool.')
    catalog = assets / 'Bundle/Assets.car'
    if not catalog.read_bytes().startswith(b'BOMStore'):
        raise RuntimeError('Invalid compiled icon catalog')
    additions = plistlib.loads((assets / 'IconInfo.plist').read_bytes())
    primary = additions.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {})
    if primary.get('CFBundleIconName') != 'AppIcon':
        raise RuntimeError('Compiled icon does not declare AppIcon as the primary icon.')
    for path in (assets / 'Bundle').rglob('*'):
        if path.is_file():
            destination = app / path.relative_to(assets / 'Bundle')
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
    info_path = app / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    for key, value in additions.items():
        if key.startswith('CFBundleIcon'):
            info[key] = value
    info['WrathAdaptiveIconSource'] = source_hash()
    info_path.write_bytes(plistlib.dumps(info))
    print('Packaged native adaptive icon (clear and tinted appearances).', flush=True)


def render_previews(output):
    developer = subprocess.check_output(['xcode-select', '-p'], text=True).strip()
    # Respect DEVELOPER_DIR selected by the build workflow.
    developer = os.environ.get('DEVELOPER_DIR', developer)
    tool = Path(developer).parent / 'Applications/Icon Composer.app/Contents/Executables/ictool'
    output.mkdir(parents=True, exist_ok=True)
    for appearance in ('Default', 'Dark', 'ClearLight', 'ClearDark', 'TintedLight', 'TintedDark'):
        subprocess.run([
            str(tool), str(SOURCE), '--export-image', '--output-file', str(output / f'{appearance}.png'),
            '--platform', 'iOS', '--rendition', appearance, '--width', '1024', '--height', '1024', '--scale', '1',
        ], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compile', action='store_true', help='Requires Xcode 27 actool on macOS')
    parser.add_argument('--output', type=Path, default=ROOT / 'xtool/native-icon')
    parser.add_argument('--previews', type=Path, help='Export all six native appearances using Icon Composer')
    args = parser.parse_args()
    if args.compile:
        compile_icon(args.output)
    elif not args.previews:
        render_svg(ROOT / 'AppIcon.svg', ROOT / 'AppIcon.png')
        print('Rendered AppIcon.png from AppIcon.svg')
    if args.previews:
        render_previews(args.previews)
