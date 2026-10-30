"""Prepare pinned official Tor JNI binaries and Java 17-compatible source.

Only explicitly named AAR members are written; archive paths are never extracted.
The upstream Java source is unchanged except its generated BuildConfig constant.
"""
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'apps/calendula'
THIRD = ROOT / 'third_party/tor'
URL = 'https://raw.githubusercontent.com/guardianproject/gpmaven/master/info/guardianproject/tor-android/0.4.9.13/tor-android-0.4.9.13.aar'
SHA = '6a1fd13e9961e5398fe73e4dc507a859431ed7998f229b121d43dcc56b311b0a'
ARCH = {
    'arm64-v8a': '59398e39a1332608fc87660b233dddd88e0792fc7b58724338d9df36bac82fb2',
    'armeabi-v7a': '8948b5e5d94f5332c0d5ffa223c06a6614001dc4289cf4d4c63488700445f341',
    'x86': '7fa2d687753cf5bef361c0b7fd6175a135ec6a0402beb02d03ac048478ffdb06',
    'x86_64': 'bfc69415504d53fb21b9e0aa8e68a37afd628e608e53f8348a267642216203f3',
}

def verified(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError('Upstream checksum changed. Review the dependency before updating pins.')
    return data

def download(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read(40 * 1024 * 1024)

def main():
    cache = ROOT / 'output/dependencies/tor-android-0.4.9.13.aar'
    if cache.exists():
        aar = verified(cache.read_bytes(), SHA)
    else:
        aar = verified(download(URL), SHA)
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_bytes(aar)
    with zipfile.ZipFile(io.BytesIO(aar)) as archive:
        for abi, digest in ARCH.items():
            data = verified(archive.read(f'jni/{abi}/libtor.so'), digest)
            target = PROJECT / f'android/app/src/main/jniLibs/{abi}/libtor.so'
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
    sources = json.loads((THIRD / 'sources.json').read_text(encoding='utf-8'))
    source = sources['tor-service-java']
    java = verified(download(source['url']), source['sha256']).decode('utf-8')
    if java.count('BuildConfig.VERSION_NAME') != 1:
        raise RuntimeError('Review upstream Java source before adapting it.')
    target = PROJECT / 'android/app/src/main/java/org/torproject/jni/TorService.java'
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(java.replace('BuildConfig.VERSION_NAME', '"0.4.9.13"').encode('utf-8'))
    for name, source in sources.items():
        if name == 'tor-service-java':
            continue
        target = THIRD / (name + '.LICENSE')
        if target.exists():
            verified(target.read_bytes(), source['sha256'])
        else:
            target.write_bytes(verified(download(source['url']), source['sha256']))
    notices = [(THIRD / 'NOTICE.md').read_text(encoding='utf-8')]
    for target in sorted(THIRD.glob('*LICENSE')):
        notices.extend(['\n\n===== ' + target.name + ' =====\n', target.read_text(encoding='utf-8')])
    asset = PROJECT / 'assets/licenses/tor.txt'
    asset.parent.mkdir(parents=True, exist_ok=True)
    asset.write_text(''.join(notices), encoding='utf-8')
    print('Verified Tor 0.4.9.13 JNI/source and bundled notices.')

if __name__ == '__main__':
    main()
