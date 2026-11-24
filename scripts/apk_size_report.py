"""Record real APK entry sizes; debug symbols stay outside the install package."""
import argparse
import json
from collections import defaultdict
from pathlib import Path
from zipfile import ZipFile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    groups = defaultdict(lambda: {'raw_bytes': 0, 'apk_entry_bytes': 0})
    with ZipFile(args.apk) as archive:
        entries = archive.infolist()
        for entry in entries:
            name = entry.filename
            group = ('native' if name.startswith('lib/') else
                     'flutter_assets' if name.startswith('assets/flutter_assets/') else
                     'dex' if name.endswith('.dex') else 'other')
            groups[group]['raw_bytes'] += entry.file_size
            groups[group]['apk_entry_bytes'] += entry.compress_size
        largest = [{'path': entry.filename, 'raw_bytes': entry.file_size,
                    'apk_entry_bytes': entry.compress_size,
                    'compression_method': entry.compress_type}
                   for entry in sorted(entries, key=lambda item: item.file_size,
                                       reverse=True)[:20]]
    report = {'apk_bytes': args.apk.stat().st_size,
              'zip_and_signing_overhead_bytes': args.apk.stat().st_size - sum(entry.compress_size for entry in entries),
              'groups': dict(groups),
              'largest_entries': largest}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
