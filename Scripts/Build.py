"""Build and audit an unsigned iOS 27 IPA using Xcode on macOS or xtool on Linux."""

import argparse
import platform
import shutil
import subprocess
from pathlib import Path

from AppIcon import compile_icon
from PackageIPA import package_app, package_ipa
from Prepare import ROOT, prepare


def build_xcode(build_directory):
    subprocess.run(['swift', 'Scripts/GenerateXcodeProject.swift'], cwd=ROOT, check=True)
    archive = build_directory / 'Wrath.xcarchive'
    subprocess.run([
        'xcodebuild', 'archive', '-project', 'Wrath.xcodeproj', '-scheme', 'Wrath',
        '-configuration', 'Release', '-destination', 'generic/platform=iOS',
        '-derivedDataPath', str(build_directory / 'DerivedData'), '-archivePath', str(archive),
        'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'ARCHS=arm64',
    ], cwd=ROOT, check=True)
    return archive / 'Products/Applications/Wrath.app'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package-only', action='store_true', help='Repackage an existing xtool/Wrath.ipa')
    parser.add_argument('--icon-assets', type=Path, help='Directory produced by AppIcon.py --compile')
    parser.add_argument('--require-adaptive-icon', action='store_true', help='Reject the PNG fallback')
    parser.add_argument('--build-directory', type=Path, default=ROOT / '.build/xcode')
    args = parser.parse_args()
    native = platform.system() == 'Darwin' and not args.package_only
    require_icon = args.require_adaptive_icon or native
    icon_assets = args.icon_assets
    if not icon_assets and shutil.which('xcrun'):
        if subprocess.run(['xcrun', '--find', 'actool'], capture_output=True).returncode == 0:
            icon_assets = ROOT / 'xtool/native-icon'
            shutil.rmtree(icon_assets, ignore_errors=True)
            compile_icon(icon_assets)
    if require_icon and not icon_assets:
        parser.error('Native icons require Xcode actool or --icon-assets from a Mac build.')
    output = ROOT / 'Wrath.ipa'
    if not args.package_only:
        prepare()
    if native:
        app = build_xcode(args.build_directory.resolve())
        package_app(app, output, icon_assets, require_icon)
        tool_output = ROOT / 'xtool/Wrath.ipa'
        tool_output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(output, tool_output)
    else:
        if not args.package_only:
            subprocess.run([
                'xtool', 'dev', 'build', '-c', 'release', '--triple', 'arm64-apple-ios27.0', '--ipa'
            ], cwd=ROOT, check=True)
        package_ipa(ROOT / 'xtool/Wrath.ipa', output, icon_assets, require_icon)


if __name__ == '__main__':
    main()
