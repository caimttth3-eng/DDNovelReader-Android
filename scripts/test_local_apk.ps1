$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temp = Join-Path (Split-Path $project) '_cache/projects/ddnovelreader/main/temp'
$fixtureRoot = Join-Path $temp ('local-apk-test-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$ancestor = $temp
while ($ancestor -and $ancestor.Length -ge (Split-Path $project).Length) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Fixture parent is a reparse point'
    }
    $ancestor = Split-Path $ancestor
}

function Assert-That($Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function New-FileBuild([string]$Directory, [string]$Version) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $name = "DDNovelReader-v$Version-arm64-v8a.apk"
    $apk = Join-Path $Directory $name
    [IO.File]::WriteAllText($apk, "Synthetic file fixture $Version; not an APK", $utf8)
    $info = [ordered]@{ version = $Version; apk = $name; bytes = (Get-Item $apk).Length;
        sha256 = (Get-FileHash $apk).Hash.ToLowerInvariant(); certificateSha256 = ('0' * 64) }
    [IO.File]::WriteAllText((Join-Path $Directory 'build-info.json'), ($info | ConvertTo-Json), $utf8)
    [IO.File]::WriteAllText((Join-Path $Directory 'SHA256SUMS.txt'), "$($info.sha256)  $name", $utf8)
    foreach ($file in @('signature-verification.txt', 'MaterialSymbols-LICENSE.txt')) {
        [IO.File]::WriteAllText((Join-Path $Directory $file), 'Synthetic fixture only', $utf8)
    }
}

# Run the real file lifecycle against tiny synthetic files. Replace only the
# native signature-verification block in the isolated script copy; no SDK,
# certificate, runnable APK, real release, signing, or network is used here.
$sourcePath = Join-Path $PSScriptRoot 'LocalApk.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
Assert-That (!$errors.Count) 'Receiver syntax is invalid'
$start = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$portable'
}, $true))
$end = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$names'
}, $true))
Assert-That ($start.Count -eq 1 -and $end.Count -eq 1) 'Native verification block cannot be isolated'
$fixtureScript = $source.Substring(0, $start[0].Extent.StartOffset) +
    "# Native signature verification is mocked only in this synthetic fixture.`n" + $source.Substring($end[0].Extent.StartOffset)

$cases = @('default', 'legacy-true', 'legacy-false', 'bad-checksum', 'unknown-old-file', 'busy-old-file', 'busy-lock', 'existing-version')
$passed = 0
try {
    foreach ($case in $cases) {
        $workspace = Join-Path $fixtureRoot $case
        $scripts = Join-Path $workspace 'DDNovelReader/scripts'
        [void][IO.Directory]::CreateDirectory($scripts)
        $receiver = Join-Path $scripts 'LocalApk.ps1'
        [IO.File]::WriteAllText($receiver, $fixtureScript, $utf8)
        $releases = Join-Path $workspace '_releases/ddnovelreader'
        foreach ($v in @('0.0.1', '0.0.2')) { New-FileBuild (Join-Path $releases "v$v") $v }
        $incoming = if ($case -eq 'existing-version') { '0.0.2' } else { '0.0.3' }
        $instance = Join-Path $workspace '_cache/projects/ddnovelreader/main'
        $build = Join-Path $instance "build/v$incoming"
        New-FileBuild $build $incoming
        $oldApk = Join-Path $releases 'v0.0.1/DDNovelReader-v0.0.1-arm64-v8a.apk'
        $oldHash = (Get-FileHash $oldApk).Hash
        $handle = $null
        if ($case -eq 'bad-checksum') { [IO.File]::AppendAllText((Join-Path $build "DDNovelReader-v$incoming-arm64-v8a.apk"), 'corrupt', $utf8) }
        if ($case -eq 'unknown-old-file') { [IO.File]::WriteAllText((Join-Path $releases 'v0.0.1/protect.txt'), 'keep', $utf8) }
        if ($case -eq 'busy-old-file') { $handle = [IO.File]::Open($oldApk, 'Open', 'Read', 'None') }
        if ($case -eq 'busy-lock') {
            [void][IO.Directory]::CreateDirectory((Join-Path $instance 'temp'))
            $handle = [IO.File]::Open((Join-Path $instance 'temp/local-apk.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        }
        $arguments = @{ Action = 'Receive'; BuildDirectory = $build }
        if ($case -eq 'legacy-true') { $arguments.RetirePrevious = $true }
        if ($case -eq 'legacy-false') { $arguments.RetirePrevious = $false }
        $failure = $null
        $result = $null
        try { $result = (& $receiver @arguments) | ConvertFrom-Json } catch { $failure = $_ } finally { if ($handle) { $handle.Dispose() } }
        $versions = @(Get-ChildItem -LiteralPath $releases -Directory)
        if ($case -in @('default', 'legacy-true', 'legacy-false')) {
            Assert-That (!$failure) "$case failed: $failure"
            Assert-That ($versions.Count -eq 1 -and $versions[0].Name -ceq 'v0.0.3') "$case accumulated old builds"
            Assert-That ($result.previousRemoved -eq $true -and $result.previous.Count -eq 2) "$case reported incorrect retirement"
            Assert-That (@(Get-ChildItem -LiteralPath $build -File).Count -eq 0) "$case retained duplicate build files"
            Assert-That ((& $receiver -Action Path) -ceq $result.apk) "$case selected the wrong APK"
        } else {
            Assert-That ($null -ne $failure) "$case unexpectedly succeeded"
            Assert-That ($versions.Count -eq 2) "$case changed existing releases"
            Assert-That ((Get-FileHash $oldApk).Hash -ceq $oldHash) "$case modified the old APK"
            Assert-That (@(Get-ChildItem -LiteralPath $build -File).Count -eq 5) "$case removed incoming files"
        }
        $passed++
    }
    Write-Output "PASS: $passed synthetic file lifecycle cases; native verification mocked; no real releases touched"
} finally {
    $full = [IO.Path]::GetFullPath($fixtureRoot)
    if (!$full.StartsWith([IO.Path]::GetFullPath($temp) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path' }
    if (Test-Path -LiteralPath $full) {
        $items = @((Get-Item -LiteralPath $full)) + @(Get-ChildItem -LiteralPath $full -Recurse -Force)
        if ($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) { throw 'Unexpected fixture reparse point; cleanup stopped' }
        Remove-Item -LiteralPath $full -Recurse
    }
}
