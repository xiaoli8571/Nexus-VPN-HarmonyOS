$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repo = 'C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\SSRVPN-HarmonyOS'
$project = Join-Path $repo 'SSRVPN_HarmonyOS'
$source = Join-Path $project 'entry\build\default\outputs\default\entry-default-unsigned.hap'
$dist = Join-Path $repo 'dist'

if (-not (Test-Path -LiteralPath $source)) {
    throw "Build artifact missing: $source"
}

$sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.Directory]::CreateDirectory($dist) | Out-Null
$dest = Join-Path $dist ('SSRVPN_HarmonyOS-5.3.2-groups-device-fix2-unsigned-' + $sourceHash.Substring(0, 12) + '.hap')
Copy-Item -LiteralPath $source -Destination $dest -Force

$destHash = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
if ($destHash -ne $sourceHash) {
    throw 'Copied HAP SHA-256 mismatch'
}

$tmp = Join-Path $env:TEMP ('ssrvpn_fix2_verify_' + [System.IO.Path]::GetRandomFileName().Replace('.', ''))
[System.IO.Directory]::CreateDirectory($tmp) | Out-Null
try {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($dest, $tmp)
    $allFiles = [System.IO.Directory]::EnumerateFiles($tmp, '*', [System.IO.SearchOption]::AllDirectories)
    $moduleFiles = @($allFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq 'module.json' })
    $packFiles = @($allFiles | Where-Object { [System.IO.Path]::GetFileName($_) -eq 'pack.info' })
    if ($moduleFiles.Count -lt 1) { throw 'module.json not found in HAP' }
    if ($packFiles.Count -lt 1) { throw 'pack.info not found in HAP' }

    $metadata = [System.IO.File]::ReadAllText($moduleFiles[0]) + "`n" + [System.IO.File]::ReadAllText($packFiles[0])
    if ($metadata -notmatch 'com\.ssrvpn\.client') { throw 'bundleName verification failed' }
    if ($metadata -notmatch '5\.3\.2') { throw 'versionName verification failed' }
    if ($metadata -notmatch '50302') { throw 'versionCode verification failed' }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($dest)
    try {
        $signatureEntries = @($zip.Entries | Where-Object {
            $_.FullName -match '(?i)(^|/)(META-INF|signature|signatures?)(/|$)|\.(rsa|dsa|ec|sf|p7b|p7c|pem|cer|crt)$'
        })
        $signatureCount = $signatureEntries.Count
    }
    finally {
        $zip.Dispose()
    }
    if ($signatureCount -ne 0) {
        throw "Unexpected signature-related entries: $signatureCount"
    }
}
finally {
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
}

$file = Get-Item -LiteralPath $dest
Write-Output ('HAP_PATH=' + $file.FullName)
Write-Output ('SHA256=' + $destHash)
Write-Output ('BYTES=' + $file.Length)
Write-Output ('LAST_WRITE=' + $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss zzz'))
Write-Output 'BUNDLE_NAME=com.ssrvpn.client'
Write-Output 'VERSION_NAME=5.3.2'
Write-Output 'VERSION_CODE=50302'
Write-Output ('SIGNATURE_ENTRIES=' + $signatureCount)
Write-Output ('TEMP_CLEANED=' + (-not (Test-Path -LiteralPath $tmp)))

Set-Location -LiteralPath $repo
git status --short
if ($LASTEXITCODE -ne 0) {
    throw "git status failed with exit code $LASTEXITCODE"
}
