param([string]$FlutterSdk = $env:FLUTTER_ROOT, [string]$JavaDirectory = $env:JAVA_HOME, [string]$Project = (Join-Path $PSScriptRoot '..\apps\calendula'), [switch]$DebugBuild)
$ErrorActionPreference = 'Stop'
if (-not $FlutterSdk) { $FlutterSdk = Split-Path (Split-Path (Get-Command flutter -ErrorAction Stop).Source -Parent) -Parent }
if (-not $JavaDirectory) { throw 'Specify JDK 17 with -JavaDirectory or JAVA_HOME.' }
$taskFlutter = Join-Path $FlutterSdk 'bin\flutter.bat'
$taskProject = (Resolve-Path -LiteralPath $Project).Path
$taskSocketDirectory = Join-Path (Split-Path $FlutterSdk -Parent) 'java-sockets'
New-Item -ItemType Directory -Force -Path $taskSocketDirectory | Out-Null
$env:JAVA_HOME = $JavaDirectory
$env:JAVA_TOOL_OPTIONS = '-Djdk.net.unixdomain.tmpdir=' + $taskSocketDirectory
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:DART_SUPPRESS_ANALYTICS = 'true'

& python (Join-Path $PSScriptRoot 'prepare-tor.py')
if ($LASTEXITCODE -ne 0) { throw 'Pinned Tor dependency preparation failed' }

function Set-TaskPluginJunctions {
    $taskMetadataPath = Join-Path $taskProject '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $taskMetadataPath)) { return }
    $taskMetadata = Get-Content -LiteralPath $taskMetadataPath -Raw | ConvertFrom-Json
    $taskLinkDirectory = Join-Path $taskProject 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Force -Path $taskLinkDirectory | Out-Null
    foreach ($taskPlugin in $taskMetadata.plugins.windows) {
        if ($taskPlugin.name -notmatch '^[a-zA-Z0-9_]+$') { throw 'Invalid plugin directory name' }
        $taskLink = Join-Path $taskLinkDirectory $taskPlugin.name
        $taskTarget = [System.IO.Path]::GetFullPath($taskPlugin.path)
        if (-not (Test-Path -LiteralPath $taskTarget)) { throw 'Plugin cache is missing' }
        if (-not (Test-Path -LiteralPath $taskLink)) { New-Item -ItemType Junction -Path $taskLink -Target $taskTarget | Out-Null }
    }
}
Push-Location $taskProject
try {
    Set-TaskPluginJunctions
    & $taskFlutter pub get
    if ($LASTEXITCODE -ne 0) {
        # A dependency change can regenerate the plugin metadata before a link failure.
        Set-TaskPluginJunctions
        & $taskFlutter pub get
        if ($LASTEXITCODE -ne 0) { throw 'Dependency preparation failed. Do not build with an incomplete plugin registrant.' }
    }
    $taskRegistrant = Get-Content -LiteralPath 'android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java' -Raw
    if ($taskRegistrant -notmatch 'FlutterSecureStoragePlugin' -or $taskRegistrant -notmatch 'JniPlugin') { throw 'Required Android plugins are not registered' }
    & $taskFlutter analyze --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Static analysis failed' }
    & $taskFlutter test --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'Native tests failed' }
    $taskMode = if ($DebugBuild) { '--debug' } else { '--release' }
    & $taskFlutter build apk $taskMode --no-pub --target-platform android-arm64
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
} finally { Pop-Location }
