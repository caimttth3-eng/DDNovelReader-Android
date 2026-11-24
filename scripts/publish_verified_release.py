import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

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


def api(path, method='GET', data=None):
    args = ['gh', 'api', '--method', method, f'repos/{REPO}/{path}']
    if data is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=None if data is None else json.dumps(data),
                            capture_output=True, text=True)
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

# A draft without a published tag is returned by the collection and its ID,
# but releases/tags/<tag> can return 404 until publication.
release = next((item for item in api('releases?per_page=100')
                if item['tag_name'] == VERSION), None)
notes = Path('docs/releases/v1.2.26.md').read_text(encoding='utf-8')
metadata = {'tag_name': VERSION, 'target_commitish': target,
            'name': 'v1.2.26 · 阅读与朗读增强版', 'body': notes,
            'draft': True, 'prerelease': False}
if release is None:
    release = api('releases', method='POST', data=metadata)
elif release['draft']:
    release = api(f"releases/{release['id']}", method='PATCH', data=metadata)
release_id = release['id']
with tempfile.TemporaryDirectory() as temp:
    staging = Path(temp)
    output = staging / NAME
    shutil.copyfile(apk, output)
    checksum = staging / (NAME + '.sha256')
    checksum.write_text(f'{EXPECTED_SHA}  {NAME}' + chr(10), encoding='ascii')
    existing = {asset['name']: asset for asset in release['assets']}
    upload = release['upload_url'].split('{', 1)[0]
    parsed = urlparse(upload)
    assert parsed.scheme == 'https' and parsed.hostname == 'uploads.github.com'
    assert parsed.path == f'/repos/{REPO}/releases/{release_id}/assets'
    for path in (output, checksum):
        if path.name not in existing:
            assert release['draft'], 'Do not add assets to an unexpected published release'
            request = Request(upload + '?name=' + quote(path.name, safe=''),
                              data=path.read_bytes(), method='POST', headers={
                'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
                'Accept': 'application/vnd.github+json',
                'Content-Type': 'application/octet-stream',
                'X-GitHub-Api-Version': '2022-11-28',
            })
            with urlopen(request, timeout=180) as response:
                asset = json.load(response)
            assert asset['name'] == path.name
            existing[path.name] = asset
    # Read each uploaded asset back by its immutable ID before publishing.
    for path in (output, checksum):
        downloaded = staging / ('verified-' + path.name)
        with downloaded.open('wb') as stream:
            result = subprocess.run(['gh', 'api',
                f"repos/{REPO}/releases/assets/{existing[path.name]['id']}",
                '--header', 'Accept: application/octet-stream'], stdout=stream,
                stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError(result.stderr.decode())
        assert digest(downloaded) == digest(path)
if release['draft']:
    api(f'releases/{release_id}', method='PATCH',
        data={'draft': False, 'make_latest': 'true'})
published = api(f'releases/{release_id}')
assert not published['draft'] and not published['prerelease']
assert {NAME, NAME + '.sha256'} <= {asset['name'] for asset in published['assets']}
print(published['html_url'])
