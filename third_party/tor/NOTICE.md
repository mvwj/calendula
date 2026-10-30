# Embedded Tor notices

Windows 0.2.0 bundles the official Tor Expert Bundle 15.0.24, Tor 0.4.9.13.
Archive/member preparation and SHA-256 pin are in `scripts/prepare-windows-tor.py`.
The checksum matches the official release's published checksum list; no signature
verification or independent rebuild/audit is claimed. Tor, libevent, OpenSSL and
zlib notices from that bundle are retained in `windows/tor-bundle` and installed
beside the Windows executable. Corresponding upstream source/build material:
https://gitlab.torproject.org/tpo/core/tor and
https://gitlab.torproject.org/tpo/applications/tor-browser-build.

The Android component provenance follows.

Calendula embeds Guardian Project tor-android 0.4.9.13 native libraries, downloaded
from the official Guardian Maven repository. See scripts/prepare-tor.py for the
archive/member SHA-256 pins and sources.json for source/license pins. Java source
from the same release is compiled with the app's JDK 17; the only source adaptation
is replacing the generated BuildConfig.VERSION_NAME with the release literal.
The precompiled upstream classes require a newer JDK and are not included.

Upstream: https://github.com/guardianproject/tor-android/tree/0.4.9.13
Binary source: https://github.com/guardianproject/gpmaven
Build instructions/source: https://github.com/guardianproject/tor-android/blob/0.4.9.13/BUILD.md

The upstream release identifies Tor 0.4.9.13, libevent 2.1.13, OpenSSL 3.5.7,
zlib 1.3.2 and zstd 1.5.7. Their notices are reproduced in the accompanying files
and in the application's bundled license screen. This is dependency provenance,
not an independent security audit or a reproducible rebuild of those binaries.

tor-android and jtorctl are Guardian Project components; their BSD notices and
the Tor core's additional component notices are included. Zstd's BSD license is
used; the upstream alternative GPL notice is also preserved for completeness.
