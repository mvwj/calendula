# Transit data and providers

The default planner searches common PID data locally for Prague public transport.
Common schedule and live-feed downloads use the existing app-only Tor clients,
TLS certificate validation, persisted minimum intervals and provider pauses.
The current common public live endpoint does not require a personal Golemio key.

Source endpoints and parsing/preparation are in `lib/transit.dart`,
`lib/timetable_store.dart`, Android `PrivateTransit.kt` and `scripts/inspect-pid.py`.
Review provider terms, availability, schema and retention when updating them.
The bundled graph/address datasets are development snapshots, not promises of
future service. Preserve common-data attribution and notices.

Foreground/active attempts are roughly every two minutes near upcoming journeys;
Android periodic work is at least fifteen minutes and can be deferred. Static
checks are daily/unmetered. These are application policies, not a published
contractual provider quota or protection against blocking. Honor Retry-After and
exponential backoff. Do not rotate IPs/accounts to evade quotas.

Some walking links are estimates. Delay data can be missing, stale, cancelled or
changed. Matched reference-route tests and street entrances remain open tasks.
Optional external route comparison submits minimal route fields and is linked
to its configured API key. See [PRIVACY](PRIVACY.md).
