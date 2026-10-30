"""Build the common offline Prague address index; never submit user addresses.

Build-only dependency: pyproj==3.7.1. Input is the public CUZK municipality CSV.
Use --zip for an already downloaded public archive. Output is deterministic.
"""
import argparse
import csv
import gzip
import hashlib
import io
import json
from pathlib import Path
import urllib.request
import zipfile

SOURCE = 'https://vdp.cuzk.gov.cz/vymenny_format/csv/20260930_OB_554782_ADR.csv.zip'
SHA256 = '2cd99f86686dd1bf34ed59f2b2d81a3a1beac450c6e865ba11fe785c04ea5cc2'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zip', type=Path)
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'apps/calendula/assets/prague-addresses.json.gz')
    args = parser.parse_args()
    from pyproj import Transformer
    transform = Transformer.from_crs(5514, 4326, always_xy=True)
    data = args.zip.read_bytes() if args.zip else urllib.request.urlopen(SOURCE, timeout=45).read(15 * 1024 * 1024)
    if len(data) >= 15 * 1024 * 1024:
        raise ValueError('Public address archive exceeds bound')
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError('Public address archive checksum changed; review before updating')
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        members = archive.namelist()
        if len(members) != 1 or not members[0].endswith('.csv'):
            raise ValueError('Expected one public CSV')
        info = archive.getinfo(members[0])
        if info.file_size > 40 * 1024 * 1024:
            raise ValueError('Public CSV exceeds bound')
        rows = csv.reader(io.StringIO(archive.read(info).decode('cp1250')), delimiter=';')
        header = next(rows)
        if len(header) != 19:
            raise ValueError('Unexpected public CSV schema')
        result = []
        for row in rows:
            if row[1] != '554782' or not row[16] or not row[17]:
                continue
            lon, lat = transform.transform(-float(row[16]), -float(row[17]))
            if not 49.8 < lat < 50.3 or not 14.1 < lon < 14.8:
                raise ValueError('Coordinate outside Prague')
            result.append([row[10] or row[8], row[12], row[13] + row[14], round(lat, 6), round(lon, 6), row[4]])
        if not 50000 < len(result) < 150000:
            raise ValueError('Unexpected address count')
        result.sort()
    document = {'version': 1, 'source': SOURCE, 'date': '2026-09-30', 'sha256': hashlib.sha256(data).hexdigest(), 'addresses': result}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(gzip.compress(json.dumps(document, ensure_ascii=False, separators=(',', ':')).encode(), mtime=0))
    print(f'Public addresses: {len(result)}; compressed bytes: {args.output.stat().st_size}; archive SHA256: {document["sha256"]}')


if __name__ == '__main__':
    main()
