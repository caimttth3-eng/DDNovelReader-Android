[CmdletBinding()]
param(
    [ValidateSet('Resolve', 'Prepare', 'Restore', 'Analyze', 'Test', 'BuildApk', 'SignApk', 'DeliverApk', 'Finalize')][string]$Action = 'Resolve',
    [string[]]$TestPaths = @('test\tts_reader_queue_test.dart', 'test\reader_title_speech_test.dart', 'test\reader_layout_test.dart'),
    [string]$TestName,
    [string[]]$DartDefines = @(),
    [switch]$IncludeAndroid,
    [switch]$Online,
    [switch]$ConfigureOnly
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$environmentRoot = Join-Path (Split-Path $project) '_env'
$entry = Join-Path $environmentRoot 'bin\Invoke-Portable.ps1'
Import-Module (Join-Path $environmentRoot 'bin\PortableCache.psm1') -Force
$context = & $entry -Action Resolve -ProjectId ddnovelreader -InstanceId main
if ([IO.Path]::GetFullPath($context.projectRoot) -ne $project) { throw 'Shared project registration does not match this source root.' }
$instance = $context.instanceRoot
$flutter = Join-Path $instance 'flutter'
$shared = & $entry -Action Environment -ProjectId ddnovelreader -InstanceId main
$gradleExecutable = & $entry -Action Tool -ProjectId ddnovelreader -Tool gradle-9.3.1
$gradle = Split-Path (Split-Path $gradleExecutable)
$androidJar = & $entry -Action Tool -ProjectId ddnovelreader -Tool android-36-jar
$androidSdk = [IO.Path]::GetFullPath($shared.ANDROID_HOME)
foreach ($path in @($gradleExecutable, $androidSdk, $androidJar)) {
    $null = Assert-PortablePlainPath $path
    if (!$path.StartsWith((Join-Path $environmentRoot 'tools') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Fixed Gradle and Android tools must resolve inside the shared tools root.'
    }
}
if ($androidSdk -ine $shared.ANDROID_SDK_ROOT -or $androidJar -ine (Join-Path $androidSdk 'platforms\android-36\android.jar')) {
    throw 'Shared Android tool and environment routes do not match.'
}
$layout = [ordered]@{
    instanceRoot = $instance; flutter = $flutter; gradle = $gradle
    pubCache = Join-Path $instance 'pub-cache'
    gradleHome = Join-Path $instance 'gradle-home'
    androidSdk = $androidSdk
    build = Join-Path $instance 'build'
    temp = Join-Path $instance 'temp'
}
if ($Action -eq 'Resolve') { return [pscustomobject]$layout }
if ($Online -and $Action -notin @('Prepare', 'Restore')) { throw 'Network access is only allowed for explicit dependency preparation.' }
if ($ConfigureOnly -and $Action -ne 'BuildApk') { throw 'ConfigureOnly is only valid for BuildApk.' }

function Restore-Runtime([string]$ManifestName, [string]$Destination, [string]$Executable) {
    $manifest = Get-Content -LiteralPath (Join-Path $environmentRoot "manifests\$ManifestName.json") -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.id -cne $ManifestName -or $manifest.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw "Invalid shared manifest: $ManifestName"
    }
    Restore-ArchiveInput $manifest $Destination $Executable
}

function Restore-ArchiveInput($manifest, [string]$Destination, [string]$Executable,
    [string]$ArchiveRoot = 'archives', [switch]$DirectoryArtifact) {
    $ManifestName = $manifest.id
    $artifactType = if ($DirectoryArtifact) { 'Container' } else { 'Leaf' }
    $null = Assert-PortablePlainPath $Destination
    $marker = Join-Path $Destination '.portable-input.json'
    if (Test-Path -LiteralPath $Destination) {
        $null = Assert-PortablePlainPath $marker
        if (!(Test-Path -LiteralPath $marker -PathType Leaf)) { throw "Unidentified runtime; do not overwrite: $Destination" }
        $identity = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($identity.id -cne $manifest.id -or $identity.sha256 -cne $manifest.sha256) {
            throw "Runtime identity changed; coordinate replacement under the Prepare lease: $Destination"
        }
        if (!(Test-Path -LiteralPath (Join-Path $Destination $Executable) -PathType $artifactType)) { throw "Incomplete runtime: $Destination" }
        return
    }
    $archive = [IO.Path]::GetFullPath((Join-Path $environmentRoot $manifest.archive.Replace('/', '\')))
    if (!$archive.StartsWith((Join-Path $environmentRoot $ArchiveRoot) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Shared runtime archive is outside the archive root.'
    }
    $null = Assert-PortablePlainPath $archive
    if (!(Test-Path -LiteralPath $archive -PathType Leaf)) { throw "Shared archive is not ready: $ManifestName" }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.sha256) {
        throw "Shared archive checksum mismatch or download incomplete: $ManifestName"
    }
    $staging = Join-Path $layout.temp ('runtime-' + [guid]::NewGuid().ToString('N'))
    $null = Assert-PortablePlainPath $staging
    [void][IO.Directory]::CreateDirectory($staging)
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $staging
        $expanded = Join-Path $staging $manifest.prefix
        $null = Assert-PortablePlainPath $expanded
        if (!(Test-Path -LiteralPath (Join-Path $expanded $Executable) -PathType $artifactType)) { throw "Archive is missing its required artifact: $ManifestName" }
        @{ id = $manifest.id; sha256 = $manifest.sha256 } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $expanded '.portable-input.json') -Encoding UTF8
        [void][IO.Directory]::CreateDirectory((Split-Path $Destination))
        [IO.Directory]::Move($expanded, $Destination)
    } finally {
        if (Test-Path -LiteralPath $staging) {
            $null = Assert-PortablePlainPath $staging
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
}

function Assert-AndroidSdk {
    foreach ($required in @('platforms\android-35\android.jar', 'platforms\android-36\android.jar',
        'ndk\28.2.13676358\ndk-build.cmd', 'cmake\3.22.1\bin\cmake.exe',
        'build-tools\36.0.0\aapt2.exe', 'build-tools\36.0.0\zipalign.exe',
        'build-tools\36.0.0\lib\apksigner.jar', 'platform-tools\adb.exe', 'licenses\android-sdk-license',
        '.knownPackages', 'platforms\android-35\package.xml', 'platforms\android-36\package.xml',
        'ndk\28.2.13676358\source.properties', 'cmake\3.22.1\source.properties',
        'build-tools\36.0.0\package.xml', 'platform-tools\package.xml')) {
        $path = Join-Path $layout.androidSdk $required
        $null = Assert-PortablePlainPath $path
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Shared Android SDK is incomplete; contact shared maintenance: $required" }
    }
    $manifest = Get-Content -LiteralPath (Join-Path $environmentRoot 'manifests\android-api36-ndk28.2-windows-x64.json') -Raw | ConvertFrom-Json
    $metadata = @($manifest.generatedMetadata.acceptedPackageXml)
    if ($manifest.schemaVersion -ne 1 -or $metadata.Count -ne 4 -or
        [IO.Path]::GetFullPath((Join-Path $environmentRoot $manifest.root.Replace('/', '\'))) -ine $layout.androidSdk -or
        $manifest.generatedMetadata.knownPackages.path -cne '.knownPackages' -or $manifest.generatedMetadata.knownPackages.bytes -ne 16) {
        throw 'Shared Android SDK metadata contract is incomplete or does not match its tool route.'
    }
    foreach ($file in $metadata) {
        $path = [IO.Path]::GetFullPath((Join-Path $layout.androidSdk $file.path.Replace('/', '\')))
        $null = Assert-PortablePlainPath $path
        if (!$path.StartsWith($layout.androidSdk + '\', [StringComparison]::OrdinalIgnoreCase) -or
            (Get-Item -LiteralPath $path).Length -ne $file.bytes -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256) {
            throw 'Shared Android package metadata differs from the accepted manifest.'
        }
    }
}

function Get-AndroidSdkInventory {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($layout.androidSdk)
    $rows = [Collections.Generic.List[object]]::new()
    $root = Get-Item -LiteralPath $layout.androidSdk -Force
    $rows.Add([pscustomobject]@{ path = '.'; directory = $true; bytes = 0L; sha256 = ''; modified = $root.LastWriteTimeUtc.Ticks })
    while ($pending.Count) {
        $directory = [IO.DirectoryInfo]::new($pending.Pop())
        foreach ($item in $directory.EnumerateFileSystemInfos()) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Shared SDK contains a reparse point: $($item.FullName)" }
            $relative = [IO.Path]::GetRelativePath($layout.androidSdk, $item.FullName)
            $isDirectory = [bool]($item.Attributes -band [IO.FileAttributes]::Directory)
            $bytes = 0L; $hash = ''
            if ($isDirectory) { $pending.Push($item.FullName) }
            else {
                $bytes = $item.Length
                $stream = [IO.File]::OpenRead($item.FullName)
                try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
                finally { $stream.Dispose() }
            }
            $rows.Add([pscustomobject]@{ path = $relative; directory = $isDirectory; bytes = $bytes; sha256 = $hash; modified = $item.LastWriteTimeUtc.Ticks })
        }
    }
    ConvertTo-Json -InputObject @($rows | Sort-Object path) -Depth 3 -Compress
}

function Wait-AndroidConsumers {
    do {
        $consumers = @(Get-CimInstance Win32_Process | Where-Object {
            $_.Name -match '^(javaw?|dart|flutter_tester|aapt2?|cmake|ninja|clang.*|ld\.lld|.*gradle.*|.*kotlin.*)\.exe$' -and
            ($_.CommandLine -like "*$instance*" -or $_.CommandLine -like "*$project*")
        })
        if ($consumers.Count) {
            Write-Output "Waiting for local Android consumers to exit naturally: $($consumers.ProcessId -join ', ')"
            Start-Sleep -Seconds 2
        }
    } while ($consumers.Count)
}

function Invoke-Flutter([string[]]$Arguments) {
    & (Join-Path $flutter 'bin\flutter.bat') --no-version-check @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Local Flutter command failed with exit code $LASTEXITCODE." }
}

function Restore-PubSeed {
    $manifest = Get-Content -LiteralPath (Join-Path $environmentRoot 'manifests\pub-dart3.14.0-windows-b5fb94b4365c.json') -Raw | ConvertFrom-Json
    # Keep the accepted resolution byte-for-byte, including informational roles.
    # Offline enforce-lockfile validates direct references to already-locked packages.
    if ($manifest.schemaVersion -ne 1 -or $manifest.source -cne 'https://pub.flutter-io.cn' -or
        $manifest.inputLockSha256 -cne (Get-FileHash -LiteralPath (Join-Path $project 'pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Shared pub seed does not match the project lock identity.'
    }
    $marker = Join-Path $layout.pubCache '.portable-seed.json'
    $null = Assert-PortablePlainPath $marker
    if (Test-Path -LiteralPath $marker) {
        $identity = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if ($identity.id -cne $manifest.id -or $identity.sha256 -cne $manifest.sha256) { throw 'Pub seed identity changed; coordinate cache preparation.' }
        return
    }
    $archive = [IO.Path]::GetFullPath((Join-Path $environmentRoot $manifest.archive.Replace('/', '\')))
    $null = Assert-PortablePlainPath $archive
    if (!$archive.StartsWith((Join-Path $environmentRoot 'feeds\pub') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.sha256) {
        throw 'Shared pub seed archive path/checksum mismatch.'
    }
    $staging = Join-Path $layout.temp ('pub-seed-' + [guid]::NewGuid().ToString('N'))
    $null = Assert-PortablePlainPath $staging
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $staging
        foreach ($root in Get-ChildItem -LiteralPath $staging -Force) {
            if (!$root.PSIsContainer -or $root.Name -cnotin @('hosted', 'hosted-hashes')) { throw 'Unexpected non-public pub seed root.' }
        }
        foreach ($file in Get-ChildItem -LiteralPath $staging -File -Recurse -Force) {
            $null = Assert-PortablePlainPath $file.FullName
            $relative = [IO.Path]::GetRelativePath($staging, $file.FullName)
            $target = Join-Path $layout.pubCache $relative
            $null = Assert-PortablePlainPath $target
            if (Test-Path -LiteralPath $target) {
                if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
                    if ($relative -cmatch '^hosted\\pub\.flutter-io\.cn\\\.cache\\([a-z0-9_]+)-versions\.json$' -and
                        $manifest.packages.name -ccontains $Matches[1]) {
                        Write-Output "Restoring accepted public package-version metadata: $($Matches[1])"
                        [IO.File]::Copy($file.FullName, $target, $true)
                    } else { throw "Existing pub cache file differs from accepted seed: $target" }
                }
            } else {
                [void][IO.Directory]::CreateDirectory((Split-Path $target))
                [IO.File]::Copy($file.FullName, $target)
            }
        }
        @{ id = $manifest.id; sha256 = $manifest.sha256 } | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    } finally {
        if (Test-Path -LiteralPath $staging) {
            $null = Assert-PortablePlainPath $staging
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }
}

function Invoke-ApkBuild {
    Assert-AndroidSdk
    if (!(Test-Path -LiteralPath (Join-Path $layout.gradleHome 'caches\modules-2\.portable-input.json'))) { throw 'Prepare the accepted Maven seed before offline APK builds.' }
    Restore-MavenSeed
    $versionLine = Select-String -LiteralPath (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$'
    if (@($versionLine).Count -ne 1) { throw 'Expected a single explicit application version and build number.' }
    $version = $versionLine.Matches[0].Groups[1].Value
    $versionCode = $versionLine.Matches[0].Groups[2].Value
    $properties = @(
        'sdk.dir=' + $layout.androidSdk.Replace('\', '\\')
        'flutter.sdk=' + $flutter.Replace('\', '\\')
        "flutter.versionName=$version"
        "flutter.versionCode=$versionCode"
        'flutter.buildMode=release'
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $project 'android\local.properties'), $properties + "`n", [Text.UTF8Encoding]::new($false))
    $gradleVersion = & $gradleExecutable --version 2>&1
    if ($LASTEXITCODE -ne 0 -or ($gradleVersion -join "`n") -notmatch '(?m)^Gradle 9\.3\.1\s*$') { throw 'The shared Gradle executable is not the required 9.3.1 distribution.' }
    $arguments = @('--offline', '--no-daemon', '--console=plain', '--max-workers=2',
        '--project-cache-dir', (Join-Path $instance 'gradle-project-cache'), '-p', (Join-Path $project 'android'),
        '-Dorg.gradle.java.installations.auto-download=false', '-Pandroid.builder.sdkDownload=false',
        '-Pkotlin.compiler.execution.strategy=in-process', '-Ptarget-platform=android-arm64', '-Ptarget=lib/main.dart',
        '-Ptree-shake-icons=true', '-Pdart-obfuscation=false', "-Psplit-debug-info=$(Join-Path $layout.build 'debug-symbols')", 'assembleRelease')
    if ($ConfigureOnly) { $arguments += '--dry-run' }
    & $gradleExecutable @arguments
    if ($LASTEXITCODE -ne 0) { throw "Offline Android build failed with exit code $LASTEXITCODE." }
    if ($ConfigureOnly) { Write-Output 'Offline Android task graph configured; no APK produced.'; return }
    $outputs = Join-Path $layout.build 'app\outputs\apk\release'
    $apks = @(Get-ChildItem -LiteralPath $outputs -File -Filter '*.apk')
    if ($apks.Count -ne 1 -or $apks[0].Name -cne 'app-release-unsigned.apk') { throw 'Expected exactly one explicitly unsigned release APK.' }
    $apk = $apks[0].FullName
    $null = Assert-PortablePlainPath $apk
    $zip = [IO.Compression.ZipFile]::OpenRead($apk)
    try {
        $abis = @($zip.Entries.FullName | Where-Object { $_ -match '^lib/([^/]+)/[^/]+\.so$' } |
            ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)
        if ($abis.Count -ne 1 -or $abis[0] -cne 'arm64-v8a' -or !$zip.GetEntry('lib/arm64-v8a/libapp.so') -or !$zip.GetEntry('lib/arm64-v8a/libflutter.so')) {
            throw 'APK must contain the ARM64 application/engine and no other native ABI.'
        }
    } finally { $zip.Dispose() }
    $badging = & (Join-Path $layout.androidSdk 'build-tools\36.0.0\aapt2.exe') dump badging $apk 2>&1
    if ($LASTEXITCODE -ne 0 -or ($badging -join "`n") -notmatch "package: name='com\.ddnovelreader' versionCode='$versionCode' versionName='$([regex]::Escape($version))'") {
        throw 'APK package/version metadata does not match pubspec.yaml.'
    }
    $signature = & $java -jar (Join-Path $layout.androidSdk 'build-tools\36.0.0\lib\apksigner.jar') verify --verbose $apk 2>&1
    if ($LASTEXITCODE -ne 1 -or ($signature -join "`n") -notmatch 'Missing META-INF/MANIFEST.MF|No signatures') {
        throw 'APK was not verified as the expected unsigned staging artifact.'
    }
    @{ version = $version; versionCode = $versionCode; status = 'UNSIGNED'; abi = 'arm64-v8a'; gradle = '9.3.1'
       apk = $apks[0].Name; bytes = $apks[0].Length; sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
       lockSha256 = (Get-FileHash -LiteralPath (Join-Path $project 'pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant() } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $outputs 'unsigned-build-info.json') -Encoding UTF8
    'UNSIGNED: not installable; use SignApk under the existing fixed-key authorization, then LocalApk acceptance.' |
        Set-Content -LiteralPath (Join-Path $outputs 'SIGNING_STATUS.txt') -Encoding ASCII
    Write-Output "Verified unsigned ARM64 staging APK: $apk"
}

function Restore-MavenSeed {
    $manifest = Get-Content -LiteralPath (Join-Path $environmentRoot 'manifests\android-flutter-3.50.0-gradle9.3.1-agp9.1.1-b5fb94b4365c.json') -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.gradle -cne '9.3.1' -or $manifest.androidGradlePlugin -cne '9.1.1' -or
        $manifest.declaredKotlin -cne '2.4.0' -or
        $manifest.inputLockSha256 -cne (Get-FileHash -LiteralPath (Join-Path $project 'pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Shared Maven closure does not match the pinned build inputs.'
    }
    $spec = [pscustomobject]@{ id = $manifest.id; archive = $manifest.archive; sha256 = $manifest.sha256; prefix = 'modules-2' }
    Restore-ArchiveInput $spec (Join-Path $layout.gradleHome 'caches\modules-2') 'files-2.1' -ArchiveRoot 'feeds\gradle' -DirectoryArtifact
}

function Invoke-ApkSigning {
    $outputs = Join-Path $layout.build 'app\outputs\apk\release'
    $info = Get-Content -LiteralPath (Join-Path $outputs 'unsigned-build-info.json') -Raw | ConvertFrom-Json
    $versionLine = Select-String -LiteralPath (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$'
    if (@($versionLine).Count -ne 1 -or $info.status -cne 'UNSIGNED' -or $info.apk -cne 'app-release-unsigned.apk' -or
        $info.version -cne $versionLine.Matches[0].Groups[1].Value -or [string]$info.versionCode -cne $versionLine.Matches[0].Groups[2].Value) {
        throw 'Unsigned APK identity does not match the current delivery version.'
    }
    $apk = Join-Path $outputs $info.apk
    $null = Assert-PortablePlainPath $apk
    if ((Get-Item -LiteralPath $apk).Length -ne $info.bytes -or
        (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -cne $info.sha256) { throw 'Unsigned APK bytes changed.' }
    $destination = Join-Path $layout.build "v$($info.version)"
    $null = Assert-PortablePlainPath $destination
    if (Test-Path -LiteralPath $destination) { throw 'Signing destination already exists; preserve the existing transaction.' }
    $secret = Join-Path $context.dataRoot 'signing\signing-secret.json'
    $null = Assert-PortablePlainPath $secret
    if (!(Test-Path -LiteralPath $secret -PathType Leaf)) { throw 'Existing fixed signing input is missing; do not generate a replacement key.' }
    $python = & $entry -Action Tool -ProjectId ddnovelreader -Tool python
    $keytool = Join-Path (Split-Path $java) 'keytool.exe'
    $signer = Join-Path $layout.androidSdk 'build-tools\36.0.0\lib\apksigner.jar'
    $align = Join-Path $layout.androidSdk 'build-tools\36.0.0\zipalign.exe'
    $name = "DDNovelReader-v$($info.version)-arm64-v8a.apk"
    $signed = Join-Path $destination $name
    & $python -B (Join-Path $project 'scripts\sign_apk.py') --apk $apk --secret-json $secret --output $signed `
        --certificate-sha256 (Join-Path $project 'android\signing-certificate.sha256') --apksigner $signer --zipalign $align --keytool $keytool
    if ($LASTEXITCODE -ne 0) { throw 'Fixed-key APK signing failed; current published package is unchanged.' }
    $verification = & $python -B (Join-Path $project 'scripts\sign_apk.py') --apk $signed --verify-only `
        --certificate-sha256 (Join-Path $project 'android\signing-certificate.sha256') --apksigner $signer
    if ($LASTEXITCODE -ne 0) { throw 'Signed APK certificate verification failed.' }
    $pin = (Get-Content -LiteralPath (Join-Path $project 'android\signing-certificate.sha256') -Raw).Trim().ToLowerInvariant()
    $hash = (Get-FileHash -LiteralPath $signed -Algorithm SHA256).Hash.ToLowerInvariant()
    @{ version = $info.version; versionCode = $info.versionCode; apk = $name; bytes = (Get-Item -LiteralPath $signed).Length
       sha256 = $hash; certificateSha256 = $pin; abi = $info.abi; status = 'local-signed'; buildType = 'release'
       buildSource = 'local-offline'; unsignedSha256 = $info.sha256; lockSha256 = $info.lockSha256 } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destination 'build-info.json') -Encoding UTF8
    "$hash  $name" | Set-Content -LiteralPath (Join-Path $destination 'SHA256SUMS.txt') -Encoding ASCII
    $verification | Set-Content -LiteralPath (Join-Path $destination 'signature-verification.txt') -Encoding UTF8
    [IO.File]::Copy((Join-Path $project 'docs\third-party\MaterialSymbols-LICENSE.txt'), (Join-Path $destination 'MaterialSymbols-LICENSE.txt'))
    Write-Output "Signed APK ready for LocalApk Receive: $destination"
}

# Flutter commands mutate their SDK cache as well as project outputs. Use the
# existing exclusive Prepare lease throughout, not a second execution lock.
Invoke-PortableInstance -ProjectId ddnovelreader -InstanceId main -Mode Prepare -Body {
    param($resolved)
    $testBuild = Join-Path $project 'build'
    $testOwner = Join-Path $testBuild '.ddnovel-test-output.json'
    if ($Action -eq 'Finalize') {
        if (!(Test-Path -LiteralPath $testBuild)) { return }
        $null = Assert-PortablePlainPath $testOwner
        if (!(Test-Path -LiteralPath $testOwner -PathType Leaf)) { throw 'Refusing to retire unidentified source test output.' }
        $owner = Get-Content -LiteralPath $testOwner -Raw | ConvertFrom-Json
        if ($owner.projectId -cne 'ddnovelreader' -or $owner.instanceId -cne 'main' -or $owner.purpose -cne 'flutter-host-tests') {
            throw 'Source test output owner does not match.'
        }
        $entries = @(Get-ChildItem -LiteralPath $testBuild -Recurse -Force)
        if (@($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
            throw 'Refusing to retire source test output containing a reparse point.'
        }
        $files = @($entries | Where-Object { !$_.PSIsContainer })
        $bytes = ($files | Measure-Object -Property Length -Sum).Sum
        Remove-Item -LiteralPath $testBuild -Recurse -Force
        Write-Output "Retired owned source test output: $($files.Count) files, $bytes bytes."
        return
    }
    foreach ($directory in @($layout.temp, $layout.build, $layout.pubCache, $layout.gradleHome,
        (Join-Path $instance 'home'), (Join-Path $instance 'appdata'), (Join-Path $instance 'localappdata'))) {
        $null = Assert-PortablePlainPath $directory
        [void][IO.Directory]::CreateDirectory($directory)
    }
    if ($Action -eq 'Prepare') {
        Restore-Runtime 'flutter-3.50.0-windows-x64' $flutter 'bin\flutter.bat'
        if ($IncludeAndroid) {
            Assert-AndroidSdk
            Restore-MavenSeed
        }
        Restore-PubSeed
        if (!$Online) { return }
    }
    $null = Assert-PortablePlainPath $flutter
    if (!(Test-Path -LiteralPath (Join-Path $flutter '.portable-input.json'))) { throw 'Flutter runtime is missing. Run Prepare after shared archive acceptance.' }
    Restore-Runtime 'flutter-3.50.0-windows-x64' $flutter 'bin\flutter.bat'
    foreach ($artifact in @('bin\cache\flutter_tools.snapshot', 'bin\cache\dart-sdk\bin\dart.exe',
        'bin\cache\artifacts\engine\windows-x64\flutter_tester.exe', 'bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf')) {
        if (!$Online -and !(Test-Path -LiteralPath (Join-Path $flutter $artifact) -PathType Leaf)) {
            throw "Offline Flutter artifact is missing; request its fixed closure from shared maintenance: $artifact"
        }
    }
    $git = & $entry -Action Tool -ProjectId ddnovelreader -Tool git
    $java = & $entry -Action Tool -ProjectId ddnovelreader -Tool java
    $pwsh = & $entry -Action Tool -ProjectId ddnovelreader -Tool pwsh
    $values = @{}
    foreach ($property in $shared.PSObject.Properties) { $values[$property.Name] = [string]$property.Value }
    $values.PATH = ((Join-Path $flutter 'bin'), (Split-Path $git), (Split-Path $java), (Split-Path $pwsh),
        (Join-Path $env:SystemRoot 'System32'), $env:SystemRoot) -join ';'
    $values.TEMP = $layout.temp; $values.TMP = $layout.temp
    $values.PUB_CACHE = $layout.pubCache; $values.GRADLE_USER_HOME = $layout.gradleHome
    $values.FLUTTER_ROOT = $flutter
    $values.DDNOVEL_BUILD_DIR = $layout.build
    $values.PUB_HOSTED_URL = 'https://pub.flutter-io.cn'; $values.FLUTTER_STORAGE_BASE_URL = 'https://storage.googleapis.com'
    $values.ANDROID_HOME = $layout.androidSdk; $values.ANDROID_SDK_ROOT = $layout.androidSdk
    $values.HOME = Join-Path $instance 'home'; $values.USERPROFILE = $values.HOME
    $values.APPDATA = Join-Path $instance 'appdata'; $values.LOCALAPPDATA = Join-Path $instance 'localappdata'
    $values.GIT_CONFIG_GLOBAL = 'NUL'; $values.GIT_CONFIG_NOSYSTEM = '1'; $values.GIT_PAGER = 'cat'
    $values.FLUTTER_SUPPRESS_ANALYTICS = 'true'; $values.DART_SUPPRESS_ANALYTICS = 'true'; $values.CI = 'true'
    $values.DDNOVEL_SIGNING_PROPERTIES = $null; $values.DD_READER_CAPTURE_UI_PREVIEWS = $null
    $values.JAVA_TOOL_OPTIONS = '-Djava.io.tmpdir="{0}" -Duser.home="{1}"' -f $layout.temp, $values.HOME
    $values._JAVA_OPTIONS = $null; $values.JDK_JAVA_OPTIONS = $null; $values.JAVA_OPTS = $null
    $values.GRADLE_OPTS = '-Dorg.gradle.daemon=false'
    $previous = @{}
    $location = Get-Location
    $sdkCacheGuard = $null
    $sdkBefore = $null
    $sdkAudit = if ($ConfigureOnly) { 'configure' } else { $Action.ToLowerInvariant() }
    try {
        foreach ($name in $values.Keys) {
            $previous[$name] = @{ present = Test-Path -LiteralPath "Env:$name"; value = [Environment]::GetEnvironmentVariable($name, 'Process') }
            if ($null -eq $values[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $values[$name], 'Process') }
        }
        if ($Action -in @('BuildApk', 'DeliverApk')) {
            Assert-AndroidSdk
            # Android Repository tolerates a read-only cache but otherwise
            # rewrites it on each scan, even when SDK downloads are disabled.
            $sdkCacheGuard = [IO.File]::Open((Join-Path $layout.androidSdk '.knownPackages'),
                [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            if ($sdkCacheGuard.Length -ne 16) { throw 'Shared SDK .knownPackages must be an existing ordinary 16-byte cache file.' }
            Wait-AndroidConsumers
            $sdkBefore = Get-AndroidSdkInventory
            $sdkBefore | Set-Content -LiteralPath (Join-Path $layout.temp "sdk-$sdkAudit-before.json") -Encoding UTF8
        }
        Set-Location -LiteralPath $project
        foreach ($generated in @('.dart_tool', '.flutter-plugins-dependencies', 'android\local.properties')) {
            $null = Assert-PortablePlainPath (Join-Path $project $generated)
        }
        $relativeBuild = [IO.Path]::GetRelativePath($project, $layout.build)
        if ($Action -eq 'Test') {
            $TestPaths = @(foreach ($test in $TestPaths) {
                $path = if ([IO.Path]::IsPathRooted($test)) { [IO.Path]::GetFullPath($test) } else { [IO.Path]::GetFullPath((Join-Path $project $test)) }
                $null = Assert-PortablePlainPath $path
                if (!$path.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    [IO.Path]::GetExtension($path) -cne '.dart' -or !(Test-Path -LiteralPath $path -PathType Leaf)) {
                    throw "Expected a project Dart test file: $test"
                }
                $path
            })
            $null = Assert-PortablePlainPath $testBuild
            if ((Test-Path -LiteralPath $testBuild) -and !(Test-Path -LiteralPath $testOwner)) { throw 'Source build directory has no test-output owner; do not overwrite it.' }
            if (Test-Path -LiteralPath $testOwner) {
                $null = Assert-PortablePlainPath $testOwner
                $owner = Get-Content -LiteralPath $testOwner -Raw | ConvertFrom-Json
                if ($owner.projectId -cne 'ddnovelreader' -or $owner.instanceId -cne 'main' -or $owner.purpose -cne 'flutter-host-tests') { throw 'Source test-output owner does not match.' }
            }
            [void][IO.Directory]::CreateDirectory($testBuild)
            @{ projectId = 'ddnovelreader'; instanceId = 'main'; purpose = 'flutter-host-tests' } |
                ConvertTo-Json | Set-Content -LiteralPath $testOwner -Encoding UTF8
            # Windows impellerc rejects ../ outputs, while Flutter forbids an
            # absolute build-dir. Keep this tool-forced exception until Finalize.
            $relativeBuild = 'build'
        }
        Invoke-Flutter -Arguments @('config', "--build-dir=$relativeBuild")
        switch ($Action) {
            'Prepare' { Invoke-Flutter -Arguments @('precache', '--windows') }
            'Restore' {
                $arguments = @('pub', 'get', '--enforce-lockfile')
                if (!$Online) { $arguments += '--offline' }
                Invoke-Flutter -Arguments $arguments
                @{ pubspecLockSha256 = (Get-FileHash -LiteralPath (Join-Path $project 'pubspec.lock') -Algorithm SHA256).Hash.ToLowerInvariant()
                   flutterManifest = 'flutter-3.50.0-windows-x64'; pubCache = 'pub-cache'; offline = !$Online } |
                    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $instance 'pub-lock.json') -Encoding UTF8
            }
            'Analyze' { Invoke-Flutter -Arguments @('analyze', '--no-pub', '--no-fatal-infos', '--no-fatal-warnings') }
            'Test' {
                $arguments = @('test', '--no-pub', '--reporter', 'expanded') + $TestPaths
                if ($TestName) { $arguments += @('--plain-name', $TestName) }
                foreach ($define in $DartDefines) { $arguments += "--dart-define=$define" }
                Invoke-Flutter -Arguments $arguments
            }
            'BuildApk' { Invoke-ApkBuild }
            'SignApk' { Invoke-ApkSigning }
            'DeliverApk' {
                Invoke-ApkBuild
                Invoke-ApkSigning
                $buildInfo = Get-Content -LiteralPath (Join-Path $layout.build 'app\outputs\apk\release\unsigned-build-info.json') -Raw | ConvertFrom-Json
                & (Join-Path $PSScriptRoot 'LocalApk.ps1') -Action Receive -BuildDirectory (Join-Path $layout.build "v$($buildInfo.version)")
            }
        }
    } finally {
        try {
            if ($sdkCacheGuard) {
                Wait-AndroidConsumers
                if ($null -ne $sdkBefore) {
                    $sdkAfter = Get-AndroidSdkInventory
                    $sdkAfter | Set-Content -LiteralPath (Join-Path $layout.temp "sdk-$sdkAudit-after.json") -Encoding UTF8
                    if ($sdkBefore -cne $sdkAfter) { throw 'Shared Android SDK tree changed; stop and report the preserved before/after inventories to shared maintenance.' }
                    Write-Output 'Shared Android SDK full-tree audit passed, including all package metadata and .knownPackages.'
                }
            }
        } finally {
            if ($sdkCacheGuard) { $sdkCacheGuard.Dispose() }
            Set-Location -LiteralPath $location.Path
            foreach ($name in $previous.Keys) {
                if ($previous[$name].present) { [Environment]::SetEnvironmentVariable($name, $previous[$name].value, 'Process') }
                else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            }
        }
    }
}
