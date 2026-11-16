[CmdletBinding()]
param(
    [ValidateSet('Path', 'Receive', 'Finalize')][string]$Action = 'Path',
    [string]$BuildDirectory,
    [switch]$KeepArtifacts,
    # Compatibility only: successful Receive always retires superseded builds.
    [switch]$RetirePrevious = $true
)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspace = Split-Path $project
$releaseRoot = Join-Path $workspace '_releases/ddnovelreader'
$instance = Join-Path $workspace '_cache/projects/ddnovelreader/main'
$temp = Join-Path $instance 'temp'

function Assert-SafePath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current -and $current.Length -ge $workspace.Length) {
        if ((Test-Path -LiteralPath $current) -and
            ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Reparse point is not allowed: $current"
        }
        $current = Split-Path $current
    }
}
function Get-SafeFiles([string]$Path) {
    Assert-SafePath $Path
    foreach ($item in Get-ChildItem -LiteralPath $Path -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point: $($item.FullName)" }
        if ($item.PSIsContainer) { Get-SafeFiles $item.FullName } else { $item }
    }
}
function Get-Versions {
    if (Test-Path -LiteralPath $releaseRoot) {
        Assert-SafePath $releaseRoot
        Get-ChildItem -LiteralPath $releaseRoot -Directory -Force |
            Where-Object Name -Match '^v\d+\.\d+\.\d+$' |
            Sort-Object { [version]$_.Name.Substring(1) } -Descending
    }
}
function Assert-Apk([string]$Directory) {
    Assert-SafePath $Directory
    $info = Get-Content -LiteralPath (Join-Path $Directory 'build-info.json') -Raw | ConvertFrom-Json
    if ($info.version -notmatch '^\d+\.\d+\.\d+$' -or
        $info.apk -cne "DDNovelReader-v$($info.version)-arm64-v8a.apk" -or
        $info.sha256 -notmatch '^[0-9a-f]{64}$') { throw 'Invalid APK identity' }
    $apk = Join-Path $Directory $info.apk
    Assert-SafePath $apk
    if ((Get-Item -LiteralPath $apk).Length -ne $info.bytes -or
        (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant() -cne $info.sha256) {
        throw 'APK size or checksum mismatch'
    }
    return $info
}
function Test-RedundantArchive([string]$Archive) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entries = @($zip.Entries | Where-Object { $_.Name })
        $expected = if ((Split-Path $Archive -Leaf) -ceq 'apk-artifact.zip') {
            @('app-release.apk', 'SHA256SUMS.txt', 'SIGNING_STATUS.txt', 'signing-certificate.sha256')
        } else { @('apk-size-report.json', 'app.android-arm64.symbols') }
        if ($entries.Count -ne $expected.Count -or @($entries.Name | Sort-Object -Unique).Count -ne $expected.Count) { return $false }
        foreach ($entry in $entries) {
            if ($expected -cnotcontains $entry.Name) { return $false }
            $stream = $entry.Open()
            try {
                if ($entry.Name -in @('SHA256SUMS.txt', 'SIGNING_STATUS.txt', 'signing-certificate.sha256')) {
                    $reader = [IO.StreamReader]::new($stream)
                    try { $text = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
                    if ($entry.Name -ceq 'SHA256SUMS.txt' -and $text -cne "$($info.sha256)  app-release.apk") { return $false }
                    if ($entry.Name -ceq 'SIGNING_STATUS.txt' -and $text -cne 'SIGNED: fixed certificate verified') { return $false }
                    if ($entry.Name -ceq 'signing-certificate.sha256' -and $text -cne $info.certificateSha256) { return $false }
                } else {
                    $file = if ($entry.Name -ceq 'app-release.apk') { Join-Path $destination $info.apk } else { Join-Path $source $entry.Name }
                    Assert-SafePath $file
                    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
                    $sha = [Security.Cryptography.SHA256]::Create()
                    try { $actual = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') } finally { $sha.Dispose() }
                    if ($actual -cne (Get-FileHash -LiteralPath $file).Hash) { return $false }
                }
            } finally { $stream.Dispose() }
        }
        return $true
    } finally { $zip.Dispose() }
}
function Assert-Companions([string]$Directory) {
    foreach ($name in $names) {
        $file = Join-Path $Directory $name
        Assert-SafePath $file
        if (!(Test-Path -LiteralPath $file -PathType Leaf) -or (Get-Item -LiteralPath $file).Length -eq 0) { throw 'Published package is incomplete' }
    }
    $sum = (Get-Content -LiteralPath (Join-Path $Directory 'SHA256SUMS.txt') -Raw).Trim() -split '\s+'
    if ($sum.Count -ne 2 -or $sum[0] -cne $info.sha256 -or $sum[1] -cne $info.apk) { throw 'Published checksum record differs from APK identity' }
}

if ($Action -eq 'Path') {
    $latest = @(Get-Versions) | Select-Object -First 1
    if (!$latest) { throw 'No local APK has been received' }
    $info = Assert-Apk $latest.FullName
    return (Join-Path $latest.FullName $info.apk)
}

if (!$BuildDirectory) { throw 'Receive requires -BuildDirectory' }
$source = [IO.Path]::GetFullPath($BuildDirectory)
if ((Split-Path $source) -ine [IO.Path]::GetFullPath((Join-Path $instance 'build'))) {
    throw 'Receive only accepts this project instance build/version directory'
}
$leaf = Split-Path $source -Leaf
if ($leaf -notmatch '^v\d+\.\d+\.\d+$') { throw 'Invalid build directory version' }
$info = if ($Action -eq 'Finalize') { Assert-Apk (Join-Path $releaseRoot $leaf) } else { Assert-Apk $source }
$version = "v$($info.version)"
if ($source -ine [IO.Path]::GetFullPath((Join-Path $instance "build/$version"))) {
    throw 'Receive only accepts this project instance build/version directory'
}
$destination = Join-Path $releaseRoot $version
Assert-SafePath $destination
Assert-SafePath $temp
[void][IO.Directory]::CreateDirectory($temp)
$lock = [IO.File]::Open((Join-Path $temp 'local-apk.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$previous = @{}
$staging = $null
$publishedNew = $false
$selectionConfirmed = $false
try {
    if ($Action -eq 'Receive' -and (Test-Path -LiteralPath $destination)) { throw 'Destination already exists; do not overwrite a release' }
    if ($Action -eq 'Finalize' -and (@(Get-Versions)[0].FullName -ine $destination)) { throw 'Finalize requires the currently selected version' }
    $old = @(Get-Versions | Where-Object FullName -INE $destination)
    $retired = @()
    foreach ($directory in $old) {
        if ([version]$directory.Name.Substring(1) -ge [version]$info.version) { throw 'Incoming build must be newer' }
        $v = $directory.Name
        $allowed = @("DDNovelReader-$v-arm64-v8a.apk", 'build-info.json', 'SHA256SUMS.txt',
            'MaterialSymbols-LICENSE.txt', 'signature-verification.txt', "DDNovelReader-$v-arm64-v8a.apk.sha256",
            "DDNovelReader-$v-build-info.json", "$v-signature-verification.txt", "$v.md",
            'licenses/MaterialSymbols-LICENSE.txt')
        $files = @(Get-SafeFiles $directory.FullName)
        if (!($files.Name -contains "DDNovelReader-$v-arm64-v8a.apk")) { throw 'Old release has no expected APK' }
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($directory.FullName.Length + 1).Replace('\', '/')
            if ($allowed -cnotcontains $relative) { throw "Unrecognized old release file: $relative" }
            $handle = [IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
            $handle.Dispose()
        }
        $retired += [pscustomobject]@{ path = $directory.FullName; files = $files.Count; bytes = ($files | Measure-Object Length -Sum).Sum }
    }
    $portable = Join-Path $workspace '_env/bin/Invoke-Portable.ps1'
    $java = & $portable -Action Tool -Tool java
    $d8 = & $portable -Action Tool -Tool android-d8
    $signer = Join-Path (Split-Path $d8) 'apksigner.jar'
    foreach ($name in @('TEMP', 'TMP', 'PATH')) {
        $previous[$name] = @{ exists = Test-Path "Env:$name"; value = [Environment]::GetEnvironmentVariable($name, 'Process') }
    }
    $env:TEMP = $temp
    $env:TMP = $temp
    $env:PATH = (Split-Path $java) + ';' + (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32')
    $verifyDirectory = if ($Action -eq 'Finalize') { $destination } else { $source }
    $output = & $java "-Djava.io.tmpdir=$temp" -jar $signer verify --verbose --print-certs-pem (Join-Path $verifyDirectory $info.apk) 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'APK signature verification failed' }
    $pin = (Get-Content -LiteralPath (Join-Path $project 'android/signing-certificate.sha256') -Raw).Trim().ToLowerInvariant()
    $certificates = [regex]::Matches(($output -join "`n"), '-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----', 'Singleline')
    if (!$certificates.Count -or $info.certificateSha256 -cne $pin) { throw 'Missing or mismatched certificate' }
    foreach ($certificate in $certificates) {
        $der = [Convert]::FromBase64String(($certificate.Groups[1].Value -replace '\s', ''))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($sha.ComputeHash($der)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
        if ($actual -cne $pin) { throw 'Certificate differs from the pinned certificate' }
    }
    $names = @($info.apk, 'build-info.json', 'SHA256SUMS.txt', 'signature-verification.txt', 'MaterialSymbols-LICENSE.txt')
    if ($Action -eq 'Receive') {
        $staging = Join-Path $temp ('receive-apk-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($staging)
        foreach ($name in $names) {
            $inputFile = Join-Path $source $name
            Assert-SafePath $inputFile
            Copy-Item -LiteralPath $inputFile -Destination (Join-Path $staging $name)
            if ((Get-FileHash -LiteralPath $inputFile).Hash -cne (Get-FileHash -LiteralPath (Join-Path $staging $name)).Hash) {
                throw "Copy mismatch: $name"
            }
        }
        [void](Assert-Apk $staging)
        Assert-Companions $staging
        [void][IO.Directory]::CreateDirectory($releaseRoot)
        [IO.Directory]::Move($staging, $destination)
        $publishedNew = $true
    }
    [void](Assert-Apk $destination)
    Assert-Companions $destination
    if ((@(Get-Versions)[0].FullName) -ine $destination) { throw 'Published version is not selected; cleanup stopped' }
    $selectionConfirmed = $true
    $staging = $null
    # Outermost success tail only. Native invocation has returned; no child Job
    # is started by this entry. Never scan dependencies, previews or other runs.
    $pending = @()
    $removed = @()
    if (!$KeepArtifacts) {
        foreach ($directory in $old) {
            try {
                $files = @(Get-SafeFiles $directory.FullName)
                foreach ($file in $files) { $handle = [IO.File]::Open($file.FullName, 'Open', 'Read', 'None'); $handle.Dispose() }
                $count = $files.Count
                $bytes = ($files | Measure-Object Length -Sum).Sum
                Remove-Item -LiteralPath $directory.FullName -Recurse
                $removed += [pscustomobject]@{ path = $directory.FullName; files = $count; bytes = $bytes }
            } catch { $pending += $directory.FullName; Write-Warning "Published APK is valid; old release cleanup deferred: $($directory.FullName)" }
        }
        foreach ($name in @($names) + @('apk-artifact.zip', 'build-analysis.zip')) {
            $file = Join-Path $source $name
            if (!(Test-Path -LiteralPath $file)) { continue }
            try {
                Assert-SafePath $file
                if ($name -in $names) {
                    if ((Get-FileHash -LiteralPath $file).Hash -cne (Get-FileHash -LiteralPath (Join-Path $destination $name)).Hash) { throw 'Input is not an identical published copy' }
                } elseif (!(Test-RedundantArchive $file)) { throw 'Archive has current or unverified extra content' }
                $bytes = (Get-Item -LiteralPath $file).Length
                Remove-Item -LiteralPath $file
                $removed += [pscustomobject]@{ path = $file; files = 1; bytes = $bytes }
            } catch { $pending += $file; Write-Warning "Published APK is valid; input retained for later finalization: $file" }
        }
    }
    [pscustomobject]@{ apk = Join-Path $destination $info.apk; previous = $retired;
        previousRemoved = (@($old | Where-Object { Test-Path -LiteralPath $_.FullName }).Count -eq 0);
        cleanupDeferred = [bool]$KeepArtifacts; removed = $removed; cleanupPending = $pending } | ConvertTo-Json -Depth 4
} finally {
    if ($publishedNew -and !$selectionConfirmed) {
        try { [IO.Directory]::Move($destination, $staging) }
        catch { Write-Warning "Selection rollback blocked by a consumer; retained for recovery: $destination"; $staging = $null }
    }
    if ($staging -and !$KeepArtifacts -and (Test-Path -LiteralPath $staging)) {
        try {
            $files = @(Get-SafeFiles $staging)
            if (@($files | Where-Object { $names -cnotcontains $_.Name }).Count) { throw 'Unknown staging consumer' }
            Remove-Item -LiteralPath $staging -Recurse
        } catch { Write-Warning "Failed receive staging retained until safe finalization: $staging" }
    }
    if ($staging -and $KeepArtifacts) { Write-Warning "Parent KeepArtifacts retains failed staging: $staging" }
    foreach ($name in $previous.Keys) {
        if ($previous[$name].exists) { [Environment]::SetEnvironmentVariable($name, $previous[$name].value, 'Process') }
        else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    }
    $lock.Dispose()
}
