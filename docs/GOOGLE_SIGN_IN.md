# Google sign-in for development builds

One application registration is shared across the distributor's users. End users
of a fully configured public application should only select their account and
grant access; they should not create a Google project for every mailbox.
General-public restricted-scope verification/onboarding remains unfinished.

For a development build, the distributor creates a Google Cloud project, enables
Gmail API and configures Google Auth Platform branding, audience and contact
information. Choose External for independent personal accounts. In Testing mode,
add the intended test accounts. Request only `gmail.readonly`.

Create an Android OAuth client for package `app.calendula.calendula` and the
actual APK signing SHA-1. Obtain that public fingerprint locally with
`apksigner verify --print-certs path/to/app.apk`. Another developer's signing key
requires its own client registration; never share the private signing key.

Create a Desktop app client in the same project for Windows. Download its JSON
and import it using the app's protected local configuration flow. Do not commit
that file or attach it to issues. Then use **Sources → Mail invitations → Add
Google account** separately for each mailbox. Each account grants consent.

Gmail OAuth is distinct from IMAP app passwords. IMAP is an optional alternative,
with a separate provider-generated app password per mailbox where supported.
Android Share/Open with can import explicitly shared text/files without mailbox
authentication. OAuth registration does not make accounts anonymous.

Start at [Google Cloud Console](https://console.cloud.google.com/) and use the
provider's current official instructions. Do not add billing just for Gmail
read-only development access. Review restricted-scope verification requirements
before distributing broadly.
