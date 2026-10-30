"""Synthetic checks for the publication guard's blocking/allowlist boundaries."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('publication_guard', Path(__file__).resolve().parents[1] / 'scripts/check-publication.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)

class PublicationGuardTests(unittest.TestCase):
    def test_blocks_private_and_generated_files(self):
        for path in ('output/report.json', 'private/note.txt', 'data/calendar.calsync',
                     'src/client_secret_dev.json', 'keys/release.keystore', '.env.local',
                     'imports/mail.eml', 'screenshots/phone.png', 'schedule.csv', 'app.apk'):
            with self.subTest(path=path):
                self.assertIsNotNone(guard.path_reason(path))

    def test_only_specific_common_fixtures_are_allowed(self):
        for path in ('samples/timetable.csv', 'apps/calendula/assets/network.json.gz',
                     'README.md', '.env.example', 'apps/calendula/pubspec.lock'):
            self.assertIsNone(guard.path_reason(path))
        self.assertIsNotNone(guard.path_reason('samples/personal.csv'))
        self.assertIsNotNone(guard.path_reason('apps/calendula/assets/personal.gz'))

    def test_secret_detection_uses_synthetic_values(self):
        fixtures = {
            'github-token': ('ghp_' + 'A' * 36).encode(),
            'google-api-key': ('AIza' + 'B' * 35).encode(),
            'private-key': ('-----BEGIN ' + 'PRIVATE KEY-----').encode(),
            'credential-in-url': ('https://' + 'sample' + ':' + 'password' + '@example.invalid').encode(),
            'personal-host-path': ('C:/' + 'Users/' + 'example-person' + '/file').encode(),
        }
        for rule, data in fixtures.items():
            self.assertIsNotNone(guard.SECRET_PATTERNS[rule].search(data))
        self.assertIsNone(guard.SECRET_PATTERNS['credential-in-url'].search(b'https://example.invalid/file'))

if __name__ == '__main__':
    unittest.main()
