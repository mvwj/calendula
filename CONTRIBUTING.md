# Contributing to Calendula

Thanks for helping build a calmer, private calendar. The native app lives in
`apps/calendula`; `prototype/` is a separate design reference.

Read [AGENTS.md](AGENTS.md), the [handoff](docs/HANDOFF.md),
[roadmap](docs/ROADMAP.md) and [verification record](docs/VERIFICATION.md).
Use English for code, interface text, issues and pull requests. Keep changes
focused and use a `codex/` branch for coding-agent work.

Preserve the cream, forest and orange design, encrypted stores, device-only
credentials, transaction locks and provider backoff. Do not add analytics,
cloud AI, background mailbox polling, direct-network fallbacks or quota evasion.

## Local checks

```sh
cd apps/calendula
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

Run `npm test` from the repository root for core logic. For changes to the Python
transport proof, run `python -m unittest discover -s tests -p 'test_*.py'`.
The optional local fixtures described in the handoff must stay outside Git.
Before native builds, run the corresponding pinned Tor preparation script.

Explain the problem, resulting behavior and actual validation in your PR. Fixture
success is not evidence of real-account, device, cloud or locked-screen success.
Include remaining limitations. Preserve third-party license notices.

## Keep personal data private

Use synthetic calendar events and sample mail. Never attach real messages,
calendar exports, precise locations, pairing/connection files, tokens, signing
keys or private device screenshots. Keep local diagnostics under ignored
`output/`. Review staged files and run `python scripts/check-publication.py`.
Use a GitHub noreply commit email if you do not want to publish your address.

Enable the local pre-push guard before contributing:

```sh
git config user.email YOUR_ID+YOUR_LOGIN@users.noreply.github.com
git config core.hooksPath .githooks
```

Find your exact noreply address in GitHub's email settings. The hook checks file
types, known credential patterns and commit-email hygiene before upload, and
runs Gitleaks too when installed. CI repeats checks after pushes. Neither check
replaces manual review of arbitrary text/images.

Never uninstall an existing personal app, clear its storage or replace a failed
encrypted vault to make a test pass. Verify signing compatibility before updates.
Test deletions in isolated stores or with clearly labelled synthetic events.

For vulnerabilities or accidental credentials, follow [SECURITY.md](SECURITY.md)
instead of opening a public issue.
