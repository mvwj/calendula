# Maintainer handoff

Updated 30 October 2026. Public source: **0.2.7+12**, native Flutter Android and
Windows. This public repository begins with a sanitized source snapshot; private
development history, personal diagnostics and build archives are not included.

Read [ROADMAP](ROADMAP.md), [VERIFICATION](VERIFICATION.md),
[IMPLEMENTATION_0.2.0](IMPLEMENTATION_0.2.0.md), [SETUP](SETUP.md) and root
[AGENTS](../AGENTS.md) before changing code. Historical test evidence must not be
presented as a new real-account or locked-screen check.

## Current state

Local encrypted calendar, day/week/month, reviewed imports, read-only mail,
encrypted device sync, local Prague transit, planned/leave-now rows, widgets,
class places/types and the moving day-time line are implemented. 0.2.7 enlarges
the Android widget preview and adds a bounded local-plan device check. That saved
locked-screen run ends with a process crash and is **not** a pass.

The native product remains a development preview. Advanced mail meeting/proposal
semantics is deferred. Prioritize concurrent editor safety, Android headless work,
sync bounds, route/reference validation, account onboarding and distribution.
Do not ask for a personal Golemio key for the current public common feed.

## Source map

| Area | Files under apps/calendula |
|---|---|
| Calendar/UI | lib/main.dart, editor.dart, calendar.dart, day_timeline.dart |
| Import/classes | lib/schedule_import.dart, schedule_csv.dart, event_place.dart, csv_import_page.dart |
| Journeys/search | lib/network_router.dart, journey_endpoint.dart, event_journey.dart, planner_runtime.dart, address_index.dart |
| Widgets/background | lib/widget_snapshot.dart, widget_background.dart; Android LiveUpdatesService.kt, WidgetRefresh.kt, DayWidget.kt |
| Persistence/sync | lib/secure_json_store.dart, sync.dart, setup_transfer.dart; Android SyncGuard.kt |
| Mail | lib/mail.dart, imap_mail.dart, gmail_desktop_auth.dart, mail_page.dart; Android MailAuthorization.kt |
| Privacy/backoff | lib/private_network.dart, desktop_tor.dart, refresh_policy.dart; Android PrivateTransit.kt |
| Fixed public probes | lib/journey_check.dart, mail_read_check.dart, desktop_check.dart |

## Local fixtures and data safety

Normal Flutter checks skip optional private/common-data fixtures that are absent.
Optional environment paths: `CALENDULA_TEST_CSV`, `TRANSIT_FEED_FILE`,
`PID_GTFS_FILE` and `PUBLIC_NETWORK_CACHE`. Keep personal inputs and diagnostics
outside Git, preferably under ignored output. Permanent fixtures must be
synthetic or common public data. Never clear an existing app/vault to pass tests.

Use `codex/` branches, focused commits, a GitHub noreply identity and the
publication guard. Preserve lockfile, encryption formats, transaction locks,
reload-on-write, signing compatibility and all dependency notices. The vendored
Windows secure-storage Win32 conversion helpers preserve storage semantics.
