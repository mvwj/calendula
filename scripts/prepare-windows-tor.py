"""Prepare pinned official Tor for the portable Windows app."""
from pathlib import Path
import hashlib
import json
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
NAME = 'tor-expert-bundle-windows-x86_64-15.0.24.tar.gz'
URL = 'https://dist.torproject.org/torbrowser/15.0.24/' + NAME
SHA = 'e9dc6ccc93cd6afa507193f4de284d6424233ff5102155cd2c94b259e8a22b65'
archive = ROOT / 'output/dependencies' / NAME
archive.parent.mkdir(parents=True, exist_ok=True)
if not archive.exists():
    urllib.request.urlretrieve(URL, archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA:
    raise SystemExit('Tor archive checksum mismatch.')
target = ROOT / 'third_party/tor/windows-x64'
allowed = {'tor/tor.exe', 'data/geoip', 'data/geoip6', 'docs/tor.txt', 'docs/libevent.txt', 'docs/openssl.txt', 'docs/zlib.txt'}
with tarfile.open(archive, 'r:gz') as tar:
    members = tar.getmembers()
    if len(members) > 100 or sum(m.size for m in members) > 200_000_000:
        raise SystemExit('Archive exceeds extraction bounds.')
    for m in members:
        if m.name not in allowed:
            continue
        if not m.isfile() or m.size > 32_000_000:
            raise SystemExit('Unexpected archive entry.')
        file = target / m.name
        file.parent.mkdir(parents=True, exist_ok=True)
        with tar.extractfile(m) as source:
            file.write_bytes(source.read())
(target / 'release.json').write_text(json.dumps({'version':'0.4.9.13','url':URL,'sha256':SHA}, indent=2))
print('Prepared official Windows Tor 0.4.9.13; SHA256 matches published release.')
bundle = ROOT / 'apps/calendula/windows/tor-bundle'
bundle.mkdir(parents=True, exist_ok=True)
for source, name in [('tor/tor.exe','tor.exe'), ('data/geoip','geoip'), ('data/geoip6','geoip6')]:
    (bundle / name).write_bytes((target / source).read_bytes())
for source in (target / 'docs').glob('*.txt'):
    (bundle / source.name).write_bytes(source.read_bytes())
