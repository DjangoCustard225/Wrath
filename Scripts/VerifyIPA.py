"""Audit iOS runtime packaging, Mach-O dependencies, and Python framework links."""
from pathlib import Path, PurePosixPath
import argparse
import json
import plistlib
import struct
import zipfile

from BuildVariant import MINIMUM_IOS, VARIANT

ROOT = Path(__file__).resolve().parent.parent


def macho(data):
    magic = struct.unpack_from('<I', data)[0]
    if magic == 0xbebafeca:
        count = struct.unpack_from('>I', data, 4)[0]
        for i in range(count):
            cpu, subtype, offset, size, align = struct.unpack_from('>IIIII', data, 8 + i * 20)
            if cpu == 0x100000c:
                return macho(data[offset:offset + size])
        raise AssertionError('No arm64 slice')
    assert magic == 0xfeedfacf, f'Unexpected Mach-O magic: {magic:x}'
    _, cpu, _, kind, count, _, _, _ = struct.unpack_from('<IIIIIIII', data)
    assert cpu == 0x100000c, f'Unexpected CPU: {cpu:x}'
    offset = 32
    dependencies, rpaths = [], []
    minimum = None
    for _ in range(count):
        command, size = struct.unpack_from('<II', data, offset)
        if command in (0xc, 0x80000018, 0x8000001f):
            start = struct.unpack_from('<I', data, offset + 8)[0]
            dependencies.append(data[offset + start:offset + size].split(b'\0')[0].decode())
        elif command == 0x8000001c:
            start = struct.unpack_from('<I', data, offset + 8)[0]
            rpaths.append(data[offset + start:offset + size].split(b'\0')[0].decode())
        elif command in (0x32, 0x25):
            version = struct.unpack_from('<I', data, offset + (12 if command == 0x32 else 8))[0]
            minimum = (version >> 16, (version >> 8) & 255, version & 255)
        offset += size
    return dependencies, rpaths, minimum


def verify(path, require_adaptive_icon=False):
    from VerifyYtDlp import verify_ipa
    verify_ipa(path)
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        base = 'Payload/Wrath.app/'
        info = plistlib.loads(archive.read(base + 'Info.plist'))
        assert info['CFBundleDisplayName'] == 'Wrath'
        assert info['CFBundleIdentifier'] == 'app.wrath.downloader'
        assert info['MinimumOSVersion'] == MINIMUM_IOS
        assert info['WrathBuildVariant'] == VARIANT
        assert not info.get('CFBundleURLTypes'), 'Unexpected incoming URL automation'
        assert not any(n.startswith(base + folder) for n in names
                       for folder in ['PlugIns/', 'Metadata.appintents/', 'Shortcuts/']), 'Unexpected automation assets'
        assert not any(n.endswith('.shortcut') for n in names), 'Unexpected workflow installer'
        supported = tuple(map(int, MINIMUM_IOS.split('.'))) + (0,)
        assert info['CADisableMinimumFrameDurationOnPhone']
        assert info['UIFileSharingEnabled']
        assert 'processing' in info.get('UIBackgroundModes', []), 'Missing background processing mode'
        assert 'app.wrath.downloader.download.*' in info.get('BGTaskSchedulerPermittedIdentifiers', []), 'Missing continued download identifiers'
        assert info.get('NSFaceIDUsageDescription'), 'Missing Face ID permission description'
        assert info.get('NSPhotoLibraryAddUsageDescription'), 'Missing photo saving permission description'
        icon = archive.read(base + 'AppIcon.png')
        assert icon.startswith(b'\x89PNG\r\n\x1a\n')
        assert struct.unpack_from('>II', icon, 16) == (1024, 1024), 'App icon must be 1024 square'
        assert icon[25] == 2, 'Fallback icon must be opaque RGB'
        adaptive_icon = 'WrathAdaptiveIconSource' in info
        assert not require_adaptive_icon or adaptive_icon, 'Native adaptive icon required'
        if adaptive_icon:
            legacy = [n for n in names if n.startswith(base + 'AppIcon') and n.endswith('.png') and n != base + 'AppIcon.png']
            assert legacy, 'Missing generated legacy app icon renditions'
            from AppIcon import source_hash
            assert info['WrathAdaptiveIconSource'] == source_hash(), 'Stale adaptive icon'
            assert archive.read(base + 'Assets.car').startswith(b'BOMStore')
            assert info['CFBundleIcons']['CFBundlePrimaryIcon']['CFBundleIconName'] == 'AppIcon'
        assert not any(n.endswith(('.so', '.pyc')) for n in names)
        assert not any('/_CodeSignature/' in n or n.endswith('embedded.mobileprovision') for n in names)
        for required in ['wrath_worker.py', 'packages/yt_dlp/__init__.py', 'packages/yt_dlp_ejs/__init__.py',
                         'packages/certifi/cacert.pem', 'packages/gallery_dl/__init__.py', 'packages/requests/__init__.py',
                         'packages/urllib3/__init__.py', 'packages/idna/__init__.py', 'packages/charset_normalizer/__init__.py',
                         'Licenses/gallery_dl-LICENSE.txt', 'python/lib/python3.13/encodings/__init__.py',
                         'python/lib/python3.13/encodings/aliases.py', 'python/lib/python3.13/_apple_support.py',
                         'python/lib/python3.13/_ios_support.py', 'python/lib/python3.13/ctypes/__init__.py',
                         'Frameworks/Python.framework/Python', 'Frameworks/_ssl.framework/_ssl',
                         'Frameworks/AetherLibavformat.framework/AetherLibavformat', 'Licenses/SponsorBlock.txt', 'AppIcon.png']:
            assert base + required in names, required
        binaries = [base + info['CFBundleExecutable']]
        frameworks = []
        for name in names:
            if name.endswith('.framework/Info.plist'):
                framework_info = plistlib.loads(archive.read(name))
                binary = str(PurePosixPath(name).parent / framework_info['CFBundleExecutable'])
                assert binary in names, binary
                binaries.append(binary); frameworks.append(binary)
        for binary in binaries:
            dependencies, rpaths, minimum = macho(archive.read(binary))
            assert minimum is not None and minimum <= supported, f'{binary}: minimum OS {minimum} exceeds {supported}'
            for dependency in dependencies:
                if dependency.startswith('@rpath/'):
                    relative = dependency.removeprefix('@rpath/')
                    assert base + 'Frameworks/' + relative in names, f'{binary}: missing {dependency}'
                else:
                    assert dependency.startswith(('/System/Library/', '/usr/lib/')), f'{binary}: nonportable dependency {dependency}'
        placeholders = [n for n in names if n.endswith('.fwork')]
        assert len(placeholders) > 30
        for placeholder in placeholders:
            binary = base + archive.read(placeholder).decode().strip()
            assert binary in names, binary
            assert archive.read(binary + '.origin').decode().strip() == placeholder.removeprefix(base)
        assert any(n.startswith(base + 'Licenses/') for n in names)
        print(json.dumps(dict(app=info['CFBundleDisplayName'], minimumIOS=info['MinimumOSVersion'],
                              adaptiveIcon=adaptive_icon, variant=VARIANT,
                              frameworks=len(frameworks), pythonExtensions=len(placeholders),
                              compressedMiB=round(Path(path).stat().st_size / 1024**2, 1), status='passed'), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', nargs='?', type=Path, default=ROOT / 'Wrath.ipa')
    parser.add_argument('--require-adaptive-icon', action='store_true')
    args = parser.parse_args()
    verify(args.ipa, require_adaptive_icon=args.require_adaptive_icon)
