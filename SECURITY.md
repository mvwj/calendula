# Security policy

Calendula is a development preview. The current public source is maintained;
historical development snapshots are not security-supported releases. No
independent security audit or production-hardening claim is made.

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/mvwj/calendula/security/advisories/new).
Include the affected revision, a minimal synthetic reproduction, impact and any
suggested fix. Do not include live credentials, real emails, calendar contents,
pairing keys or exact home/work coordinates. Do not post a working exploit or
sensitive report in public issues.

If you expose a credential, revoke or rotate it with its provider first. Deleting
a file or making a later commit does not remove earlier copies or Git history.
Encrypted connection files can contain credentials; do not publish them either.

Calendar keys, device credentials and sync content need particular care. Keep
authenticated accounts distinct from anonymous transport, and distinguish
encryption from endpoint/device security. Existing transit/mail clients use
app-only Tor with certificate validation and no silent direct fallback.
Cloud sync exposes account/IP/file metadata to its provider. OAuth consent uses
the provider's sign-in flow. Read the [privacy model](docs/PRIVACY.md).

Repository checks look for known secret patterns and forbidden data files; they
cannot prove that arbitrary text or images contain no personal information.
Review contributions manually and use synthetic fixtures.
