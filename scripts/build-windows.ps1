param(
    [string]$FlutterSdk = $env:FLUTTER_ROOT,
    [string]$Project = (Join-Path $PSScriptRoot '..\apps\calendula'),
    [string]$CMake = $env:CMAKE_EXE,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
if (-not $FlutterSdk) { $FlutterSdk = Split-Path (Split-Path (Get-Command flutter -ErrorAction Stop).Source -Parent) -Parent }
if (-not $CMake) { $CMake = (Get-Command cmake -ErrorAction Stop).Source }
$taskProject = (Resolve-Path -LiteralPath $Project).Path
$taskFlutter = Join-Path $FlutterSdk 'bin\flutter.bat'
if (-not (Test-Path -LiteralPath $CMake)) { throw 'Specify the installed CMake executable with -CMake.' }
& python (Join-Path $PSScriptRoot 'prepare-windows-tor.py')
if ($LASTEXITCODE -ne 0) { throw 'Windows Tor preparation failed.' }
function Set-TaskWindowsLinks {
    $taskMetadataPath = Join-Path $taskProject '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $taskMetadataPath)) { return }
    $taskMetadata = Get-Content -LiteralPath $taskMetadataPath -Raw | ConvertFrom-Json
    $taskLinkDirectory = Join-Path $taskProject 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $taskLinkDirectory | Out-Null
    foreach ($taskPlugin in $taskMetadata.plugins.windows) {
        if ($taskPlugin.name -notmatch '^[a-zA-Z0-9_]+$') { throw 'Invalid plugin name.' }
        $taskTarget = [System.IO.Path]::GetFullPath($taskPlugin.path)
        if (-not (Test-Path -LiteralPath $taskTarget)) { throw 'Plugin dependency is missing.' }
        $taskLink = Join-Path $taskLinkDirectory $taskPlugin.name
        if (-not (Test-Path -LiteralPath $taskLink)) { New-Item -ItemType Junction -Path $taskLink -Target $taskTarget | Out-Null }
    }
}
Push-Location $taskProject
try {
    Set-TaskWindowsLinks
    & $taskFlutter pub get
    if ($LASTEXITCODE -ne 0) {
        Set-TaskWindowsLinks
        & $taskFlutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Flutter dependencies are incomplete.' }
    }
    if ($Check) {
        & $taskFlutter analyze --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed.' }
        & $taskFlutter test --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Tests failed.' }
    }
    # Generates fresh version/engine configuration before Flutter checks for VS CMake.
    # This host has MSVC + Windows SDK but uses its Android SDK CMake installation.
    & $taskFlutter build windows --release --no-pub --config-only
    $taskConfig = Get-Content -LiteralPath 'windows\flutter\ephemeral\generated_config.cmake' -Raw
    $taskVersion = (Select-String -LiteralPath 'pubspec.yaml' -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value
    if (-not $taskConfig.Contains('set(FLUTTER_VERSION "' + $taskVersion + '"')) {
        throw 'Generated Flutter version is stale. Fix configuration before compiling.'
    }
    Set-TaskWindowsLinks
    & $CMake -S windows -B build/windows/x64 -G 'Visual Studio 17 2022' -A x64 -DFLUTTER_TARGET_PLATFORM=windows-x64
    if ($LASTEXITCODE -ne 0) { throw 'Windows configuration failed.' }
    & $CMake --build build/windows/x64 --config Release --target INSTALL
    if ($LASTEXITCODE -ne 0) { throw 'Windows compilation failed.' }
    Write-Output (Join-Path $taskProject 'build\windows\x64\runner\Release\calendula.exe')
} finally { Pop-Location }
