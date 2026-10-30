<p align="center">
  <img src="docs/assets/calendula-cover.svg" alt="Calendula — a little space for your day. Calendar and journey-first widget illustrated with fictional plans." width="100%">
</p>

<p align="center">
  <a href="https://github.com/mvwj/calendula/actions/workflows/publication-check.yml"><img alt="Publication safety checks" src="https://github.com/mvwj/calendula/actions/workflows/publication-check.yml/badge.svg"></a>
  <a href="#getting-started"><img alt="Status: development preview" src="https://img.shields.io/badge/status-development_preview-EDAA65?style=flat-square&amp;labelColor=284B3D"></a>
  <img alt="Android and Windows" src="https://img.shields.io/badge/platforms-Android_%C2%B7_Windows-284B3D?style=flat-square">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-284B3D?style=flat-square"></a>
</p>

<p align="center"><strong>Your day, with room to breathe.</strong><br>
A native calendar for Android and Windows that connects your plans with the journey there.</p>

<p align="center">
  <a href="docs/SETUP.md">Get started</a> ·
  <a href="docs/PRIVACY.md">Privacy</a> ·
  <a href="docs/ROADMAP.md">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contribute</a>
</p>

## A calendar that knows when to leave

Calendula brings together your agenda, imported timetables and Prague public
transport. It keeps calendar data encrypted on your devices and calculates
journeys locally from common transit files. No calendar account or hosted
Calendula backend is required.

| Plan your day | Get there | Keep it yours |
|---|---|---|
| Day, week and month views; manual and all-day events | Planned departure with an adjustable arrival buffer | Encrypted local calendar and OS-protected keys |
| ICS, CSV, XLSX, text-layer PDF and text import with review | Prague metro, trams, buses and trains with transfers | Optional encrypted sync over WebDAV, LAN or files |
| Separate address, venue, room, floor and class type | Saved home/other origin or foreground Android GPS | Read-only mail; refresh on opening, resume or request |
| Android home-screen widget and Windows desktop agenda | A separate “leave now” row while the app is open | App-only Tor for existing transit and mail clients |

Czech place search accepts accents or plain Latin input, plus common English
stop aliases. Event routes prefill the destination. Known MFF classroom codes can
resolve to a public building address; missing lecture/practice labels remain
explicit choices rather than guesses.

## Privacy, with clear boundaries

- Calendar and route calculations stay on your devices. No analytics or cloud AI.
- Transit clients download common public timetables and delay feeds through
  embedded Tor, with TLS validation and no silent direct fallback.
- Optional cloud sync encrypts calendar content end to end. The cloud provider
  still sees account, IP and file metadata; explicit connection exports also
  contain the selected credentials **inside encryption**.
- Mail authentication identifies your mailbox. OAuth consent uses the provider's
  sign-in flow. Tor does not make an authenticated account anonymous.
- Background planning uses a saved origin or one age-limited encrypted GPS fix;
  it does not collect a background location history or poll mailboxes.

Read the [privacy model](docs/PRIVACY.md) and
[security policy](SECURITY.md) for the exact boundaries.

## Getting started

**Development preview · source version 0.2.7.** The public repository starts from
a reviewed source snapshot. Personal build archives and earlier private project
history are not published. Stable installers and general-public mail OAuth
onboarding are still work in progress.

Requirements: Flutter **3.47.6** / Dart **3.13.5**, Python 3 and the relevant native
toolchain. Android builds use JDK 17 and support Android API 26+. Windows builds
need Visual Studio C++ tools and a Windows SDK.

```sh
git clone https://github.com/mvwj/calendula.git
cd calendula/apps/calendula
flutter pub get
python ../../scripts/prepare-tor.py
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --target-platform android-arm64
```

For Windows, run `python ../../scripts/prepare-windows-tor.py` before
`flutter build windows --release`. Distribute the **complete** Windows output
directory, including `data`, DLLs, Tor and notices.

The [setup guide](docs/SETUP.md) covers origins, imports, widgets, mail and sync.
The [build notes](docs/NATIVE_STATUS.md) cover portable PowerShell helpers and
toolchain workarounds. Keep an existing Android installation's signing key when
updating it; uninstalling can remove its protected calendar keys.

## What is ready, and what comes next

The source has native Android/Windows implementations, 113 fixture-enabled
Flutter checks and 22 core logic checks recorded in the
[verification notes](docs/VERIFICATION.md). Unit checks, native builds, real
accounts and OS background behavior are separate verification gates.

Work remains on reliable locked-screen operation across Android vendors,
street/entrance-aware walking, matched reference-route comparisons, sync history
bounds, distribution and account onboarding. Some walking links are estimates;
perfect delay predictions and globally optimal routes are not guaranteed.
Bundled transit data is a development snapshot: refresh it before relying on
journey times. See the [roadmap](docs/ROADMAP.md).

## Inside the repository

| Path | Purpose |
|---|---|
| [`apps/calendula/`](apps/calendula) | Native Flutter Android and Windows application |
| [`docs/`](docs) | Setup, architecture, privacy, status and development handoff |
| [`scripts/`](scripts) | Build helpers and common public-data preparation |
| [`third_party/`](third_party) | Dependency provenance, licenses and notices |
| [`samples/`](samples) | Synthetic import examples |
| [`prototype/`](prototype) | Browser design reference; unencrypted sample-data storage |
| [`src/`](src), [`tests/`](tests) | Prototype logic and offline transport proof checks |

To run the separate design reference, use Node.js 22+: `npm start`, then open
`http://127.0.0.1:4173`. Its browser storage is unencrypted; use synthetic data.
Run its checks with `npm test`.

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) and
[AGENTS.md](AGENTS.md). Please keep real schedules, emails, coordinates,
credentials and device screenshots out of issues and pull requests.

## License & acknowledgments

Calendula's original source is [MIT licensed](LICENSE). Third-party components
and public datasets retain their own licenses and attribution requirements:
[third-party notices](THIRD_PARTY_NOTICES.md). Thanks to the Flutter ecosystem,
the Tor Project and Guardian Project, PID/Golemio, and ČÚZK/RÚIAN open data.
Calendula is an independent project, without affiliation or endorsement by those
providers.
