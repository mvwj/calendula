# Public source review

Prepared 30 October 2026. The public project starts from a clean source snapshot
of Calendula 0.2.7+12. Earlier development history and build archives are retained
privately. They are not part of the public Git graph, releases or issue attachments.

## Review scope

- A redacted Gitleaks 8.30.1 scan of the original reachable Git history found no
  recognized credentials. A separate manual/inventory review found private author
  email addresses and host paths, so that history was not made public.
- The public snapshot uses GitHub noreply author/committer metadata. Public
  documentation is curated in English without personal schedules, account details,
  device identifiers, private screenshots or local build paths.
- Permanent fixtures are synthetic or common public data. The sample PDF is
  synthetic; compressed public-data assets parse as JSON. Third-party notices and
  required upstream attribution remain intact.
- The cover is an original code-drawn SVG with fictional appointments, no embedded
  personal screenshot, script, external font or linked image. It was rendered and
  visually reviewed before publication.
- Local guard checks pass, all 22 core logic checks and eight Python checks pass,
  and both portable PowerShell helpers parse. Native product code was not changed
  by publication. Historical Flutter/device evidence remains separate in
  [VERIFICATION](VERIFICATION.md).

## Continuing safeguards

The publication workflow runs the forbidden-file guard, synthetic guard tests,
core logic tests and checksum-pinned Gitleaks over reachable Git history with
redacted output. Checkout is pinned and workflow permissions are read-only.
The repository uses private vulnerability reporting and GitHub secret/push
protection where available. Keep signing keys, OAuth downloads and diagnostics
outside Git. No old binaries are distributed with this source publication.

These checks reduce accidental disclosure; they cannot prove that arbitrary
content contains no personal information. Review future text, fixtures, images,
release archives and commit metadata before pushing. The [security policy](../SECURITY.md)
explains private reporting and credential response.
