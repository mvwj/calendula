# Roadmap

Updated 30 October 2026. Checkmarks mean implemented with the bounded evidence
in [VERIFICATION](VERIFICATION.md), not a claim that every real-world workflow
is verified. The public issue tracker contains the current work queue.

## Implemented

- [x] Native Android/Windows app, English UI, cream/forest/orange design.
- [x] Encrypted local calendar; manual/all-day entries; day/week/month.
- [x] Reviewed ICS, SIS/generic CSV, XLSX, text-layer PDF and text imports.
- [x] Event/day/same-title period deletion with confirmation and Undo.
- [x] Public Prague address/stop search, accent handling and English aliases.
- [x] Local multimodal PID routing, transfers, delay/cancellation handling.
- [x] Event destination prefill, adjustable arrival buffer, planned/leave-now rows.
- [x] Explicit class type, address, room/floor and confirmed-series reuse.
- [x] Android widget, Windows desktop agenda, tray/startup and moving day line.
- [x] Read-only mail adapters and explicit Android Share/Open with review.
- [x] Encrypted WebDAV/LAN/file sync and explicit encrypted connection transfer.
- [x] App-only Tor for existing transit/mail, TLS and provider pauses.
- [x] English public project, synthetic illustration and publication safeguards.

## Next verification and implementation work

| Priority | Work | Completion criterion |
|---|---|---|
| P0 | Concurrent editor changes | Untouched remote fields survive; conflicting edits and deletion remain explicit |
| P0 | Android background reliability | Two completed headless updates while locked, then long-term periodic/vendor checks |
| P1 | Mail onboarding | Verified Google distribution/consent and supported Microsoft/IMAP workflows |
| P1 | Cross-device cloud/LAN | Synthetic field updates/deletes/conflicts tested on two current native clients |
| P1 | Sync bounds and lifecycle | Bounded packet memory/history and explicit retention/revocation design |
| P1 | Route validation | Matched complex reference cases; documented walking/entrance limits |
| P1 | Windows workflows | Normal GUI/tray/startup/multi-monitor/DPI checks |
| P2 | Imports | Safe source updates, wider recurrence and on-device scanned-document OCR |
| P2 | Distribution | Fresh-clone builds, managed signing and complete license inventories |

Advanced mail meeting/proposal interpretation is deferred until explicitly
resumed. No background mailbox polling, cloud AI, mandatory backend or quota
evasion is planned. No universal speed, delay or route-optimality guarantee.
