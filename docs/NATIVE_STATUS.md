# Native builds

The product is Flutter **3.47.6 / Dart 3.13.5**, Android API 26+ and Windows x64.
Use JDK 17 for Android. Keep `pubspec.lock` and dependency checksums/notices.

## Android

From `apps/calendula`:

```sh
flutter pub get
python ../../scripts/prepare-tor.py
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --release --target-platform android-arm64
```

The current Gradle development build uses the local debug signing identity. A
fresh clone produces a different identity. Preserve an existing installation's
signature for updates; never uninstall or clear its protected data to work around
a signing failure. Public release signing is an open task. Signing keys and
local properties must never be committed.

## Windows

Run `python ../../scripts/prepare-windows-tor.py`, then `flutter build windows
--release`. Install Visual Studio C++ tools, Windows SDK and CMake. Publish the
complete Release directory, including DLLs, data, Tor and license notices.
Unsigned development executables are not production installers.

PowerShell helpers accept explicit paths instead of machine-specific defaults:

```powershell
./scripts/build-native.ps1 -FlutterSdk C:/dev/flutter -JavaDirectory C:/dev/jdk-17 -Project C:/dev/calendula/apps/calendula
./scripts/build-windows.ps1 -FlutterSdk C:/dev/flutter -Project C:/dev/calendula/apps/calendula -CMake C:/dev/cmake/bin/cmake.exe -Check
```

An ASCII junction can work around tooling issues with some non-ASCII paths.
The Android helper creates a local JVM socket directory beside the Flutter SDK.
The Windows helper supports direct CMake/MSBuild when Flutter cannot locate an
otherwise installed toolchain. These workarounds do not affect installed data.
