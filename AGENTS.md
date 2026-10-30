# Calendula: instructions for coding agents

These instructions apply to the entire repository, including Antigravity. The human user's current instructions take precedence.

Read `docs/HANDOFF.md`, `docs/ROADMAP.md` and `docs/IMPLEMENTATION_0.2.0.md` before changes. `docs/VERIFICATION.md` records evidence; older document sections are historical. Update status and evidence when completing a task.

## Product constraints

- The product is a native Flutter Android/Windows app in `apps/calendula`. `prototype/` is a separate design reference with unencrypted browser storage. Do not replace the app with a website.
- English UI, Russian communication with the owner. Preserve the cream/forest/orange visual direction and journey-first agenda/widgets.
- Local encrypted calendar, no compulsory calendar account/backend, analytics or cloud AI.
- Prague first, public transport only, private routing locally using common PID files. Embedded app-only Tor protects existing transit/mail clients; validate TLS and never silently fall back to direct requests.
- The current public PID live endpoint needs no personal Golemio key. Do not ask the owner to register there again. Honor provider pauses/Retry-After; no IP/account rotation to evade quotas.
- Read-only Gmail/Outlook; refresh on opening/resume/manual action. Do not add background mailbox polling or send mail to external AI.
- Sync encrypts content end to end; direct HTTPS cloud transport exposes account/IP/file metadata. Keep device credentials/settings out of packets. Do not claim account anonymity or guaranteed optimal routes/delays.

## Data and device safety

Never commit personal CSV/mail/GPS/screenshots/calendar files, tokens, OAuth secrets, pairing codes, signing keys or generated binaries. Use ignored `output/` for local artifacts/reports; fixtures must be synthetic or common public transport data.

Android package: `app.calendula.calendula`. Use `adb install -r` for updates. Never uninstall, clear app storage, reset keys or replace a failed encrypted vault to make tests pass. A clone's debug key differs from the owner's existing signature; coordinate signing outside Git instead of deleting the app.

Operate only Calendula's own UI in authorized device checks. Finish builds before asking to unlock; avoid repeated unlock prompts.

## Development and validation

- Flutter 3.47.6 / Dart 3.13.5, JDK 17, Android API 26+. Keep `pubspec.lock`; review dependency/Tor/crypto upgrades.
- Preserve the vendored Windows secure-storage plugin, MIT license and notice. Its Win32 conversion helpers remove optional ATL without changing encryption/storage formats.
- Run `python scripts/prepare-tor.py` before Android builds and `python scripts/prepare-windows-tor.py` before Windows builds. Scripts restore checksum-pinned ignored binaries and include license notices.
- Build helpers accept explicit SDK/project parameters. The original host uses an ASCII junction for Flutter tooling; resolve scripts from the repository, not from that junction.
- Preserve UI/headless transaction locks, reload-on-write and widget freshness checks. Test relevant concurrent edits when changing persistence.
- Use `codex/` for new working branches and focused commits with actual validation.
- Run appropriate checks: app `flutter analyze --no-pub`, `flutter test --no-pub`; root `npm test`; Python proof tests when changing the proof. Optional local fixtures are documented in the handoff.
- Device/UI, real OAuth, cloud exchange and locked-screen behavior have separate gates. Do not call fixture/build success real-account verification. Test deletion on labelled synthetic events or isolated vaults, never by removing the owner's events.
