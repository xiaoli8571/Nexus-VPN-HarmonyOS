$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Join-Path $repo 'SSRVPN_HarmonyOS'
$deveco = 'C:\Program Files\Huawei\DevEco Studio'
$java = Join-Path $deveco 'jbr\bin\java.exe'
$signTool = Join-Path $deveco 'sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$unsignedApp = Join-Path $project 'build\outputs\default\SSRVPN_HarmonyOS-default-unsigned.app'
$keyStore = Join-Path $repo 'SSRVPN.p12'
$cert = Join-Path $repo 'SSRVPN.cer'
$profile = Join-Path $repo 'SSRVPNRelease.p7b'
$dist = Join-Path $repo 'dist'
$baseSignedApp = Join-Path $dist 'SSRVPN_HarmonyOS-5.2.3-release-signed.app'
$signedApp = $baseSignedApp
if (Test-Path -LiteralPath $signedApp) {
  $signedApp = Join-Path $dist ('SSRVPN_HarmonyOS-5.2.3-release-signed-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.app')
}

foreach ($required in @($java, $signTool, $unsignedApp, $keyStore, $cert, $profile)) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "Missing required file: $required"
  }
}
if (-not $env:SSRVPN_KEY_PASSWORD) {
  throw 'SSRVPN_KEY_PASSWORD is empty'
}

$work = Join-Path $env:TEMP ('ssrvpn-sign-' + (Get-Date -Format 'yyyyMMddHHmmss'))
$payload = Join-Path $work 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
New-Item -ItemType Directory -Path $dist -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem

$archive = [System.IO.Compression.ZipFile]::OpenRead($unsignedApp)
try {
  foreach ($metadataName in @('pac.json', 'pack.info')) {
    $metadata = $archive.Entries | Where-Object { $_.FullName -eq $metadataName } | Select-Object -First 1
    if ($null -eq $metadata) {
      throw "Missing APP metadata: $metadataName"
    }
    $metadataPath = Join-Path $payload $metadataName
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($metadata, $metadataPath, $true)
  }
  $hapEntry = $archive.Entries | Where-Object { $_.FullName -like '*.hap' } | Select-Object -First 1
  if ($null -eq $hapEntry) {
    throw 'Missing inner HAP in unsigned APP'
  }
  $unsignedHap = Join-Path $work 'entry-default-unsigned.hap'
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($hapEntry, $unsignedHap, $true)
} finally {
  $archive.Dispose()
}

$hapArchive = [System.IO.Compression.ZipFile]::OpenRead($unsignedHap)
try {
  $moduleEntry = $hapArchive.Entries | Where-Object { $_.FullName -eq 'module.json' } | Select-Object -First 1
  if ($null -eq $moduleEntry) {
    throw 'Missing module.json in inner HAP'
  }
  $reader = New-Object System.IO.StreamReader($moduleEntry.Open())
  try {
    $moduleJson = $reader.ReadToEnd() | ConvertFrom-Json
  } finally {
    $reader.Dispose()
  }
  $compatibleVersion = [string]$moduleJson.app.minAPIVersion
  if (-not $compatibleVersion) {
    throw 'Missing app.minAPIVersion in module.json'
  }
} finally {
  $hapArchive.Dispose()
}

$signedHap = Join-Path $payload 'entry-default.hap'
& $java -jar $signTool sign-app -mode localSign -keyAlias ssrvpn -keyPwd $env:SSRVPN_KEY_PASSWORD -keystorePwd $env:SSRVPN_KEY_PASSWORD -signAlg SHA256withECDSA -appCertFile $cert -profileFile $profile -keystoreFile $keyStore -compatibleVersion $compatibleVersion -inFile $unsignedHap -outFile $signedHap
if ($LASTEXITCODE -ne 0) {
  throw 'Inner HAP signing failed'
}

$repackedApp = Join-Path $work 'SSRVPN_HarmonyOS-repacked.app'
[System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $repackedApp, [System.IO.Compression.CompressionLevel]::Optimal, $false)
& $java -jar $signTool sign-app -mode localSign -keyAlias ssrvpn -keyPwd $env:SSRVPN_KEY_PASSWORD -keystorePwd $env:SSRVPN_KEY_PASSWORD -signAlg SHA256withECDSA -appCertFile $cert -profileFile $profile -keystoreFile $keyStore -inFile $repackedApp -outFile $signedApp
if ($LASTEXITCODE -ne 0) {
  throw 'APP shell signing failed'
}

Write-Output 'SIGNED_APP_READY'
Get-Item -LiteralPath $signedApp | Select-Object FullName, Length, LastWriteTime
Get-FileHash -LiteralPath $signedApp -Algorithm SHA256 | Select-Object Algorithm, Hash, Path
