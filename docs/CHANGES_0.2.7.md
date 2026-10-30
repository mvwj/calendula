# 0.2.7 — widget preview and background-check visibility

The Android widget preview uses a larger display-bounded frame for three agenda
entries, both journey rows and Close. Widget setup explains vertical resizing.
No encryption or vault format changes; existing calendars need no reimport.

The release-only device harness adds `checkMode=local-plans`, using the production
bounded active service. It requires the screen to remain off and checks two
completed plan timestamps against changed encrypted cache bytes. It reports only
technical results and never decodes personal cache content. The production
planner reads the local calendar to calculate plans. The saved run ends with a
process crash, without PASS; locked-screen reliability remains an open task.

This check is separate from long-term periodic work, live downloads, actual
launcher placement and account/cloud workflows. Advanced mail interpretation
remains deferred. See [VERIFICATION](VERIFICATION.md).
