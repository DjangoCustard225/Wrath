"""Verify all bundled yt-dlp package files match the pinned upstream wheel."""
from pathlib import Path
import hashlib
import json
import os
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def verify(package=None):
    manifest = json.loads((ROOT / 'Dependencies/python-packages.json').read_text())['yt-dlp']
    cache = Path(os.environ.get('WRATH_DEPENDENCY_CACHE', '/tmp/wrath-dependencies'))
    wheel = cache / f'yt-dlp-{manifest["version"]}.whl'
    assert hashlib.sha256(wheel.read_bytes()).hexdigest() == manifest['sha256'], 'Wrong upstream wheel'
    package = package or ROOT / 'Wrath/Resources/packages'
    with zipfile.ZipFile(wheel) as archive:
        expected = {name for name in archive.namelist() if name.startswith('yt_dlp/') and not name.endswith('/')}
        actual = {p.relative_to(package).as_posix() for p in (package / 'yt_dlp').rglob('*')
                  if p.is_file() and '__pycache__' not in p.parts}
        assert actual == expected, 'Bundled yt-dlp file set differs from upstream'
        for name in expected:
            assert (package / name).read_bytes() == archive.read(name), f'Modified upstream file: {name}'
    print(f'yt-dlp {manifest["version"]}: {len(expected)} upstream files verified unchanged.')


def verify_ipa(path):
    manifest = json.loads((ROOT / 'Dependencies/python-packages.json').read_text())['yt-dlp']
    cache = Path(os.environ.get('WRATH_DEPENDENCY_CACHE', '/tmp/wrath-dependencies'))
    wheel = cache / f'yt-dlp-{manifest["version"]}.whl'
    assert hashlib.sha256(wheel.read_bytes()).hexdigest() == manifest['sha256']
    base = 'Payload/Wrath.app/packages/'
    with zipfile.ZipFile(wheel) as upstream, zipfile.ZipFile(path) as ipa:
        expected = {n for n in upstream.namelist() if n.startswith('yt_dlp/') and not n.endswith('/')}
        actual = {n.removeprefix(base) for n in ipa.namelist()
                  if n.startswith(base + 'yt_dlp/') and not n.endswith('/')}
        assert actual == expected, 'IPA yt-dlp package differs from upstream'
        for name in expected:
            assert ipa.read(base + name) == upstream.read(name), f'IPA modified yt-dlp: {name}'
    print(f'IPA yt-dlp {manifest["version"]}: all {len(expected)} upstream files unchanged.')


if __name__ == '__main__':
    verify()
