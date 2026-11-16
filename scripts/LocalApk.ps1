[CmdletBinding()]
param(
    [ValidateSet('Path', 'Receive')][string]$Action = 'Path',
    [string]$BuildDirectory,
    [switch]$RetirePrevious
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
$info = Assert-Apk $source
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
try {
    if (Test-Path -LiteralPath $destination) { throw 'Destination already exists; do not overwrite a release' }
    $old = @(Get-Versions)
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
    $output = & $java "-Djava.io.tmpdir=$temp" -jar $signer verify --verbose --print-certs-pem (Join-Path $source $info.apk) 2>&1
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
    [void][IO.Directory]::CreateDirectory($releaseRoot)
    [IO.Directory]::Move($staging, $destination)
    $staging = $null
    [void](Assert-Apk $destination)
    foreach ($name in $names) { Remove-Item -LiteralPath (Join-Path $source $name) }
    if ($RetirePrevious) {
        foreach ($directory in $old) {
            [void]@(Get-SafeFiles $directory.FullName)
            Remove-Item -LiteralPath $directory.FullName -Recurse
        }
    }
    [pscustomobject]@{ apk = Join-Path $destination $info.apk; previous = $retired; previousRemoved = [bool]$RetirePrevious } | ConvertTo-Json -Depth 4
} finally {
    foreach ($name in $previous.Keys) {
        if ($previous[$name].exists) { [Environment]::SetEnvironmentVariable($name, $previous[$name].value, 'Process') }
        else { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
    }
    $lock.Dispose()
    # Failed staging is left for inspection; it never replaces a working APK.
}
