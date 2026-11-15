import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

REPO = 'NayGnehz/DDNovelReader-Android'
VERSION = 'v1.2.26'
SOURCE = '922116b0fa91594587e96af993b0859699d69819'
RUN_ID = 43622578197
EXPECTED_SHA = 'be64fb084a3af05184f023b219abc6a75d6f652605a7f736d10e9f3c057d5aec'
CERT = '088b9569c7e74b31dd9840b335e4755f1af5a51667d0c51ade9c5b83e0f57db1'
NAME = 'DDNovelReader-v1.2.26-arm64-v8a.apk'
assert os.environ['GITHUB_REPOSITORY'] == REPO
assert os.environ['GITHUB_REF'] == 'refs/heads/master'
target = os.environ['GITHUB_SHA']


def gh(*args):
    result = subprocess.run(['gh', *args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def api(path, optional=False):
    result = subprocess.run(['gh', 'api', f'repos/{REPO}/{path}'], capture_output=True, text=True)
    if optional and result.returncode and 'HTTP 404' in result.stderr:
        return None
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


run = api(f'actions/runs/{RUN_ID}')
assert run['head_sha'] == SOURCE and run['conclusion'] == 'success'
comparison = api(f'compare/{SOURCE}...{target}')
assert comparison['status'] in ('ahead', 'identical')
allowed = {'README.md', 'docs/releases/v1.2.26.md',
           '.github/workflows/publish-release.yml', 'scripts/publish_verified_release.py'}
assert all(item['filename'] in allowed for item in comparison['files'])
files = Path('verified-apk')
apk, = files.rglob('app-release.apk')
status, = files.rglob('SIGNING_STATUS.txt')
assert status.read_text().strip() == 'SIGNED: fixed certificate verified'
cert, = files.rglob('signing-certificate.sha256')
assert cert.read_text().strip() == CERT
assert apk.stat().st_size == 19350477 and digest(apk) == EXPECTED_SHA
sums, = files.rglob('SHA256SUMS.txt')
assert any(line.split() == [EXPECTED_SHA, 'app-release.apk'] for line in sums.read_text().splitlines())
with zipfile.ZipFile(apk) as z:
    abis = {name.split('/')[1] for name in z.namelist()
            if name.startswith('lib/') and name.endswith('.so')}
    assert abis == {'arm64-v8a'}

release = api(f'releases/tags/{VERSION}', optional=True)
if release is None:
    gh('release', 'create', VERSION, '--repo', REPO, '--draft', '--target', target,
       '--title', 'v1.2.26 · 阅读与朗读增强版', '--notes-file', 'docs/releases/v1.2.26.md')
    release = api(f'releases/tags/{VERSION}')
assert release['target_commitish'] == target
with tempfile.TemporaryDirectory() as temp:
    staging = Path(temp)
    output = staging / NAME
    shutil.copyfile(apk, output)
    checksum = staging / (NAME + '.sha256')
    checksum.write_text(f'{EXPECTED_SHA}  {NAME}' + chr(10), encoding='ascii')
    existing = {asset['name'] for asset in release['assets']}
    for path in (output, checksum):
        if path.name not in existing:
            gh('release', 'upload', VERSION, str(path), '--repo', REPO)
    downloaded = staging / 'downloaded'
    downloaded.mkdir()
    for path in (output, checksum):
        gh('release', 'download', VERSION, '--repo', REPO,
           '--pattern', path.name, '--dir', str(downloaded))
        assert digest(downloaded / path.name) == digest(path)
if release['draft']:
    gh('release', 'edit', VERSION, '--repo', REPO, '--draft=false', '--latest')
published = api(f'releases/tags/{VERSION}')
assert not published['draft'] and not published['prerelease']
assert {NAME, NAME + '.sha256'} <= {asset['name'] for asset in published['assets']}
print(published['html_url'])
