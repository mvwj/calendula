# Getting started

Calendula is a native Android/Windows development preview with an English UI.
Build instructions are in [NATIVE_STATUS](NATIVE_STATUS.md). Stable installers
and general-public OAuth onboarding are not yet provided.

## Starting point and journeys

Open **Settings → Set home & starting point**. Choose **Home address**, **Other
address** or **Current location (GPS)**. Select a recognized Prague address or
stop from the suggestions and save. Search accepts Czech accents, plain Latin
input and common English stop aliases. Android GPS requires foreground location
consent. Windows GPS mode uses the saved home instead.

An event's **Plan transport** action fills its destination and calculates when
both endpoints are known. The planned row targets the event start minus the
**Arrival buffer** (ten minutes by default). The separate leave-now row is
recalculated while the app is visible. Unknown destinations require confirmation;
walking links may be estimates. Refresh the public transit snapshot before use.

## Events and imports

Create manual/all-day events or review ICS, SIS/generic CSV, XLSX, text-layer PDF
and supported dated text. Review candidates before saving. For a class, retain
its title, class type, venue, address, room, floor and exact times separately.
Known MFF rooms can use the bounded public address directory. If the CSV lacks
lecture/practice labels, choose the type per import rule or edit the exact
meeting series once. Missing information is not invented.

Long press an Android event or right click on Windows for deletion choices:
one event, the selected day, or matching titles within a week/month/custom range.
Review the count and dates; Cancel keeps records and Undo restores the action.

## Widgets and background work

Add **Calendula · Your day** from Android's home-screen widget picker. Resize it
vertically for more agenda content. Settings also offers a native preview.
Windows has **Open desktop agenda**, tray operation and optional sign-in startup.

Enable transport background work in **Settings → Private updates**. Android
periodic work is at least fifteen minutes and may be deferred by the OS. Optional
active mode has a visible notification and runs for up to ninety minutes with
roughly two-minute attempts. Provider pauses still apply. The latest locked-screen
test did not pass; see [VERIFICATION](VERIFICATION.md).

Background calculations do not acquire GPS or poll mail. They use a saved origin
or one encrypted last fix of bounded age/accuracy. Open the app or select a
saved origin when the fix is unavailable or stale.

## Mail

**Sources → Mail invitations** supports Google sign-in, supported IMAP app
passwords, Microsoft device-code authentication, and Android Share/Open with.
Connections refresh on opening, resume or manual request; no background polling.
Mail is read-only and remote HTML images are not loaded. Adding extracted
candidates requires review. Advanced meeting/proposal understanding is deferred.

OAuth app registration is a developer/distributor responsibility; each mailbox
then grants access. General-public consent verification remains unfinished.
An IMAP app password is separate for each mailbox and can grant broader provider
access than OAuth's read-only scope. Exchange Online generally needs OAuth.
Read [GOOGLE_SIGN_IN](GOOGLE_SIGN_IN.md) before configuring a development build.

## Device sync

**Settings → Device sync** supports HTTPS WebDAV, paired LAN, a Windows synced
folder and manual encrypted files. Pair devices using the existing pairing code.
A cloud folder stores encrypted change packets; the provider sees account/IP/file
metadata. Never publish pairing codes or packets.

**Export connection file** creates an encrypted `.calsetup` containing calendar,
selected origin/cloud settings and optional Windows Google configuration.
Importing it on another device requires the existing pairing key. Mail sessions
and OS consent remain per device. This explicit export can contain encrypted
credentials; ordinary calendar sync packets do not.

Update both clients to 0.2.6 or newer for class/place metadata. Never reset an
existing calendar to fix a rejected packet. A campus network may isolate LAN
peers; cloud/file sync is independent of LAN discovery.
