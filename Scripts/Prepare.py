"""Restore pinned runtime binaries and pure Python packages. No device-side installs."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path(os.environ.get('WRATH_DEPENDENCY_CACHE', '/tmp/wrath-dependencies'))
PYTHON_URL = 'https://github.com/beeware/Python-Apple-support/releases/download/3.13-b14/Python-3.13-iOS-support.b14.tar.gz'
PYTHON_SHA = '8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963'
FFMPEG_URL = 'https://codeload.github.com/superuser404notfound/FFmpegBuild/tar.gz/refs/tags/3.7.1'
FFMPEG_SHA = '425e850da64fd077cbae6cfa6505398198ea8819fba25608e71263ad21eaa098'


def download(url, sha, filename):
    CACHE.mkdir(parents=True, exist_ok=True)
    target = CACHE / filename
    if not target.exists() or hashlib.sha256(target.read_bytes()).hexdigest() != sha:
        temporary = target.with_suffix(target.suffix + '.download')
        try:
            subprocess.run(['curl', '-L', '--fail', '--retry', '2', '--connect-timeout', '20',
                            '--max-time', '300', url, '-o', str(temporary)], check=True)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != sha:
                raise RuntimeError(f'Checksum mismatch: {filename}')
            temporary.replace(target)
        finally:
            temporary.unlink(missing_ok=True)
    if hashlib.sha256(target.read_bytes()).hexdigest() != sha:
        raise RuntimeError(f'Checksum mismatch: {filename}')
    return target


def prepare():
    dependencies = ROOT / 'Dependencies'
    python = dependencies / 'Python.xcframework'
    if not (python / 'ios-arm64/Python.framework/Python').exists():
        archive = download(PYTHON_URL, PYTHON_SHA, 'Python.tar.gz')
        with tarfile.open(archive) as source:
            source.extractall(dependencies, members=(item for item in source if item.name.startswith('Python.xcframework/')), filter='data')
    ffmpeg = dependencies / 'FFmpegBuild'
    if not (ffmpeg / 'Sources/AetherLibavformat.xcframework/ios-arm64').exists():
        archive = download(FFMPEG_URL, FFMPEG_SHA, 'FFmpeg.tar.gz')
        with tempfile.TemporaryDirectory() as staging, tarfile.open(archive) as source:
            top = source.getmembers()[0].name.split('/')[0] + '/'
            for member in source:
                if not member.name.startswith(top):
                    continue
                relative = member.name[len(top):]
                if not relative.startswith(('Sources/', 'LICENSE', 'NOTICE')):
                    continue
                # The local manifest links iOS slices only; retain upstream framework metadata.
                if '.dSYM' in relative or '/dSYMs/' in relative:
                    continue
                member.name = relative
                source.extract(member, staging, filter='data')
            for entry in Path(staging).iterdir():
                destination = ffmpeg / entry.name
                if destination.exists():
                    shutil.rmtree(destination) if destination.is_dir() else destination.unlink()
                shutil.move(entry, destination)
    packages = ROOT / 'Wrath/Resources/packages'
    packages.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((dependencies / 'python-packages.json').read_text())
    for name, artifact in manifest.items():
        archive = download(artifact['url'], artifact['sha256'], f'{name}-{artifact["version"]}.whl')
        with zipfile.ZipFile(archive) as source:
            source.extractall(packages)
    licenses = ROOT / 'Wrath/Resources/Licenses'
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ffmpeg / 'LICENSE', licenses / 'FFmpeg.txt')
    for file in (ffmpeg / 'LICENSES').glob('*'):
        if file.is_file():
            name = file.name if file.suffix == '.txt' else file.name + '.txt'
            shutil.copyfile(file, licenses / ('FFmpeg-' + name))
    shutil.copyfile(python / 'lib/python3.13/LICENSE.txt', licenses / 'Python.txt')
    for folder in packages.glob('*.dist-info'):
        for file in folder.rglob('*'):
            if file.is_file() and file.name.upper().startswith(('LICENSE', 'COPYING')):
                shutil.copyfile(file, licenses / (folder.name.split('-')[0] + '-' + file.name + '.txt'))
    print('Pinned dependencies prepared.', flush=True)


if __name__ == '__main__':
    prepare()
