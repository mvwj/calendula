# 0.2.6 — automatic departures and class places

- Explicit class type/address/room/floor, bounded known-MFF-room enrichment and
  once-confirmed exact-series place/type reuse.
- Address-first event route prefill/calculation, adjustable ten-minute default
  arrival buffer, planned departure and foreground-only leave-now rows.
- Local widget replanning, bounded device-only GPS snapshot and adaptive common
  transit refresh with existing provider pauses.
- Weighted overlapping-stop grouping with pair-matrix equivalence checks.
- Moving day-time line on the native calendar/Windows agenda.

Both sync clients need 0.2.6 or newer for the new event metadata. Unknown class
types remain explicit choices. Preserve calendar keys, signing identity and
credentials. No reimport/reset is required. Read current [verification](VERIFICATION.md).
