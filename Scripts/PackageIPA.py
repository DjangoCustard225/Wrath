"""Shared unsigned IPA packaging for native Xcode and Linux xtool builds."""

import plistlib
import shutil
import tempfile
import zipfile
from pathlib import Path

from AppIcon import install_icon
from Prepare import ROOT
from VerifyIPA import verify

PYTHON_VERSION = '3.13'
PYTHON_RELEASE = '3.13.14'


def install_python(app):
    runtime = ROOT / 'Dependencies/Python.xcframework'
    stdlib = app / f'python/lib/python{PYTHON_VERSION}'
    shutil.copytree(
        runtime / f'lib/python{PYTHON_VERSION}', stdlib, dirs_exist_ok=True,
        ignore=shutil.ignore_patterns(
            '__pycache__', '*.pyc', 'test', 'tests', 'idlelib', 'tkinter', 'turtledemo', 'ensurepip'
        ),
    )
    platform_lib = runtime / f'ios-arm64/lib-arm64/python{PYTHON_VERSION}'
    dynamic = stdlib / 'lib-dynload'
    shutil.copytree(platform_lib / 'lib-dynload', dynamic, dirs_exist_ok=True)
    config = platform_lib / '_sysconfigdata__ios_arm64-iphoneos.py'
    shutil.copyfile(config, stdlib / config.name)
    for source in dynamic.glob('*.so'):
        module = source.name.split('.')[0]
        if module.startswith(('_test', 'xx', '_xx')) or module.endswith('_test'):
            source.unlink()
            continue
        framework = app / f'Frameworks/{module}.framework'
        framework.mkdir(parents=True, exist_ok=True)
        binary = framework / module
        shutil.move(source, binary)
        binary.chmod(0o755)
        placeholder = source.with_suffix('.fwork')
        placeholder.write_text(binary.relative_to(app).as_posix() + '\n')
        (framework / (module + '.origin')).write_text(placeholder.relative_to(app).as_posix() + '\n')
        info = dict(
            CFBundleExecutable=module,
            CFBundleIdentifier='app.wrath.python.' + module.replace('_', '-'),
            CFBundleName=module,
            CFBundlePackageType='FMWK',
            CFBundleShortVersionString=PYTHON_RELEASE,
            CFBundleVersion='1',
            CFBundleSupportedPlatforms=['iPhoneOS'],
            MinimumOSVersion='13.0',
        )
        (framework / 'Info.plist').write_bytes(plistlib.dumps(info))


def package_staging(staging, output, icon_assets=None, require_adaptive_icon=False):
    app = staging / 'Payload/Wrath.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'Wrath' or not (app / 'Wrath').is_file():
        raise RuntimeError('Expected the Wrath executable used by the embedded Python runtime.')
    if icon_assets:
        install_icon(app, icon_assets)
    elif require_adaptive_icon:
        raise RuntimeError('Native clear/tinted icons require compiled AppIcon.icon assets.')
    else:
        print('Icon: PNG fallback (native appearances were not compiled).', flush=True)
    shutil.copyfile(ROOT / 'AppIcon.png', app / 'AppIcon.png')
    install_python(app)
    for folder in app.rglob('__pycache__'):
        shutil.rmtree(folder)
    # Vendor signatures cannot survive runtime packaging; the final IPA is signed when installed.
    for folder in app.rglob('_CodeSignature'):
        shutil.rmtree(folder)
    for profile in app.rglob('embedded.mobileprovision'):
        profile.unlink()
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix('.ipa.tmp')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in sorted(staging.rglob('*')):
                if file.is_file():
                    archive.write(file, file.relative_to(staging))
        verify(temporary, require_adaptive_icon=require_adaptive_icon)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    versioned = output.with_name(f'Wrath-{info["CFBundleShortVersionString"]}.ipa')
    if versioned != output:
        shutil.copyfile(output, versioned)
    output.with_suffix('.sha256').unlink(missing_ok=True)
    print(f'Packaged {output} ({output.stat().st_size / 1024**2:.1f} MiB)', flush=True)
    return output


def package_app(source, output, icon_assets, require_adaptive_icon=True):
    with tempfile.TemporaryDirectory(prefix='wrath-package-') as directory:
        staging = Path(directory)
        shutil.copytree(source, staging / 'Payload/Wrath.app')
        return package_staging(staging, output, icon_assets, require_adaptive_icon)


def package_ipa(source, output, icon_assets=None, require_adaptive_icon=False):
    with tempfile.TemporaryDirectory(prefix='wrath-package-') as directory:
        staging = Path(directory)
        with zipfile.ZipFile(source) as archive:
            archive.extractall(staging)
        result = package_staging(staging, output, icon_assets, require_adaptive_icon)
    if Path(source).resolve() != result.resolve():
        shutil.copyfile(result, source)
    return result
