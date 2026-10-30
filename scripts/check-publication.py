"""Fail closed on private file types and common credentials; never print values.

Run with --history before publishing a clean snapshot. Complements Gitleaks and
manual review; it cannot determine whether arbitrary prose/images are personal.
"""
import argparse
import re
import subprocess
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
DATA_ASSETS = {
    'apps/calendula/assets/metro.json.gz',
    'apps/calendula/assets/network.json.gz',
    'apps/calendula/assets/prague-addresses.json.gz',
    'apps/calendula/windows/runner/resources/import-example.pdf',
    'samples/timetable.csv',
}
PRIVATE_SUFFIXES = {'.vault', '.calsync', '.calsetup', '.sqlite', '.sqlite3', '.db',
                    '.jks', '.keystore', '.p12', '.pfx', '.pem', '.key', '.eml',
                    '.mbox', '.ics', '.apk', '.aab', '.exe', '.dll', '.so', '.zip',
                    '.log', '.dump', '.csv', '.tsv', '.xlsx', '.xls', '.pdf', '.gz'}
SECRET_PATTERNS = {
    'private-key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----'),
    'github-token': re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b'),
    'google-access-token': re.compile(rb'\bya29\.[A-Za-z0-9_-]{30,}'),
    'google-api-key': re.compile(rb'\bAIza[0-9A-Za-z_-]{35}\b'),
    'aws-access-key': re.compile(rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b'),
    'credential-in-url': re.compile(rb'https?://[^\s/<>"\']+:[^\s/<>"\']+@'),
    'personal-host-path': re.compile(rb'[A-Za-z]:[\\/]+Users[\\/]+(?!Public\b|Default\b|<)[A-Za-z0-9_.-]+', re.I),
}

def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)

def path_reason(name):
    path = PurePosixPath(name)
    if any(p.lower() in {'output', 'private', 'screenshots', 'node_modules', '.dart_tool'} for p in path.parts):
        return 'private/generated directory'
    lower = path.name.lower()
    if lower in {'credentials.json', 'google-services.json', 'key.properties', 'local.properties'} or lower.startswith(('client_secret', '.env')):
        if lower != '.env.example':
            return 'local credentials/configuration'
    if path.suffix.lower() in PRIVATE_SUFFIXES and name not in DATA_ASSETS:
        return 'private/generated data type'
    return None

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', action='store_true', help='also require private commit-email hygiene')
    args = parser.parse_args()
    names = set(git('ls-files', '-z', '--cached', '--others', '--exclude-standard').decode().split('\0')) - {''}
    failures = []
    for name in sorted(names):
        path = ROOT / name
        if not path.exists():
            continue
        reason = path_reason(name)
        if reason:
            failures.append((name, reason))
            continue
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT.resolve()):
            failures.append((name, 'symlink/outside checkout'))
            continue
        data = path.read_bytes()
        if b'\0' in data[:8192]:
            continue
        for rule, pattern in SECRET_PATTERNS.items():
            if pattern.search(data):
                failures.append((name, rule))
    if args.history:
        for line in git('log', '--all', '--format=%h%x09%ae%x09%ce').decode().splitlines():
            commit, author, committer = line.split('\t')
            if not all(email.endswith('@users.noreply.github.com') for email in (author, committer)):
                failures.append(('commit ' + commit, 'use GitHub noreply author/committer email'))
    for name, reason in failures:
        print(f'BLOCKED: {name}: {reason}')
    if failures:
        return 1
    print(f'Publication file guard passed ({len(names)} files). Review text/images and run Gitleaks separately.')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
