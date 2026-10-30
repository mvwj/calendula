# Privacy and network boundaries

Calendula has no mandatory calendar account, hosted backend, analytics or cloud
AI. Calendar content is encrypted locally, with keys held by the device's
protected storage. Native route search runs locally from common PID data.

## What leaves the device

| Operation | Data exposed to the other party |
|---|---|
| Existing transit clients | Common schedule/delay downloads through embedded Tor; no per-event routing query |
| Mail reading | Authenticated mailbox API/IMAP request through Tor; the provider knows the account |
| OAuth consent | Provider sign-in and consent via Google Play services or the system browser |
| Optional HTTPS cloud sync | Encrypted content plus provider-visible account, source IP, file names, sizes and timing |
| Explicit connection export | Encrypted calendar and selected connection credentials/settings; keep the file private |
| Optional external route comparison | Minimal origin, destination and time through Tor; the provider sees those fields and the API-key identity |

Tor hides the direct source IP from the destination of a supported client. It
does not hide authenticated accounts or guarantee unlinkability. TLS protects
transport but the server receives ordinary API request fields. Cloud sync has
different metadata exposure from Tor-protected mail/transit. No direct fallback
or IP/account rotation is used to bypass provider limits.

## Location and mail

Foreground Android GPS is optional and consented. One encrypted device-only fix
can support background plans while recent and sufficiently accurate; no location
history or background GPS collection is added. Ordinary sync/setup packets do
not transfer GPS fixes. Saved home/other origins are calendar setup preferences
and can be explicitly transferred in an encrypted connection file.

Mail is read on opening/resume/manual request, with cooldown and provider backoff.
There is no background mailbox worker. IMAP uses EXAMINE/BODY.PEEK; remote HTML
images are not fetched. Message reading is separate from reviewed calendar
creation. No mail is sent to external AI. OAuth scopes are read-only; an IMAP
app password can authorize more than the app itself uses.

## Limits

Encryption does not protect an already-unlocked compromised device or a shared
pairing key. Sync peers share authority; revocation/retention need more work.
The browser design prototype uses unencrypted browser storage and is for sample
data. Local diagnostics and screenshots can contain personal information and
must remain under ignored output. See [SECURITY](../SECURITY.md).
