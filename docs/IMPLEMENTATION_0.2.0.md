# Native implementation baseline

The 0.2.0 baseline established native Flutter Android/Windows targets, protected
calendar storage, reviewed imports, read-only mail adapters, causal encrypted sync,
public local routing and native widgets. Current source **0.2.7+12** extends that
baseline; read [HANDOFF](HANDOFF.md), [ROADMAP](ROADMAP.md) and
[VERIFICATION](VERIFICATION.md) for current behavior and remaining gates.

Preserve UI/headless transaction locks, reload-on-write and widget freshness
guards. Sync keys and device credentials have different lifecycles. Ordinary
calendar packets exclude credentials; explicit encrypted connection exports may
contain selected setup credentials. Never replace a failed encrypted store.

Background policy: foreground/active local work around two minutes, Android
periodic work at least fifteen minutes, daily unmetered static schedule checks,
provider minimums/Retry-After/backoff and no background mail or GPS collection.
The OS may defer work. Delays and route optimality are not guaranteed.
