param(
  [string]$SourceRepo = (Split-Path -Parent $MyInvocation.MyCommand.Path),
  [ValidateSet('app','hap')] [string]$Kind = 'app'
)
# Sign the freshly built unsigned package with the project's release material,
# verify both layers, and publish under dist\ named by the AppScope version.
$ErrorActionPreference = 'Stop'
$java = 'C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe'
$tool = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar'
$project = Join-Path $SourceRepo 'SSRVPN_HarmonyOS'
$appJson = Get-Content (Join-Path $project 'AppScope/app.json5') -Raw
$versionName = [regex]::Match($appJson, '"versionName":\s*"([^"]+)"').Groups[1].Value
if (-not $versionName) { throw 'cannot read versionName from AppScope/app.json5' }
$dist = Join-Path $SourceRepo 'dist'
New-Item -ItemType Directory $dist -Force | Out-Null

function Invoke-SignTool {
  param([string[]]$ToolArgs)
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $script:toolLines = & $java -jar $tool @ToolArgs 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
  } finally { $ErrorActionPreference = $eap }
  if ($code -ne 0) {
    ($script:toolLines | Select-String 'ERROR' | Select-Object -First 6) | ForEach-Object { Write-Host $_.Line }
    throw ("sign tool failed (exit " + $code + '): ' + $ToolArgs[0])
  }
}

$work = Join-Path $env:TEMP ('ssrvpn-sign-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $work -Force | Out-Null
if (-not $env:SSRVPN_KEY_PASSWORD) { throw 'Set SSRVPN_KEY_PASSWORD locally before running.' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
  $common = @('-mode','localSign','-keyAlias','ssrvpn','-keyPwd',$env:SSRVPN_KEY_PASSWORD,'-keystorePwd',$env:SSRVPN_KEY_PASSWORD,'-signAlg','SHA256withECDSA','-appCertFile',(Join-Path $SourceRepo 'SSRVPN.cer'),'-profileFile',(Join-Path $SourceRepo 'SSRVPNRelease.p7b'),'-keystoreFile',(Join-Path $SourceRepo 'SSRVPN.p12'))
  if ($Kind -eq 'hap') {
    $in = Join-Path $project 'entry/build/default/outputs/default/entry-default-unsigned.hap'
    $outHap = Join-Path $dist ("SSRVPN-$versionName-release-signed.hap")
    if (-not (Test-Path $in)) { throw "missing unsigned hap: $in" }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($in)
    try {
      $reader = [System.IO.StreamReader]::new($zip.GetEntry('module.json').Open())
      try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $api = [string]$module.app.minAPIVersion
    if (-not $api) { throw 'Missing minAPIVersion' }
    Invoke-SignTool (@('sign-app') + $common + @('-compatibleVersion', $api, '-inFile', $in, '-outFile', $outHap))
    Invoke-SignTool @('verify-app', '-inFile', $outHap, '-outCertChain', (Join-Path $work 'hap-cert.cer'), '-outProfile', (Join-Path $work 'hap-profile.p7b'))
    Get-FileHash $outHap -Algorithm SHA256 | Select-Object Hash,Path
  } else {
    $inApp = Join-Path $project 'build/outputs/default/SSRVPN_HarmonyOS-default-unsigned.app'
    $outApp = Join-Path $dist ("SSRVPN_HarmonyOS-$versionName-release-signed.app")
    if (-not (Test-Path $inApp)) { throw "missing unsigned app: $inApp" }
    $payload = Join-Path $work 'payload'
    New-Item -ItemType Directory $payload -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($inApp, $payload)
    $haps = @(Get-ChildItem $payload -Filter '*.hap' -File)
    if ($haps.Count -ne 1) { throw 'Expected exactly one HAP in app pack.' }
    $unsignedHap = Join-Path $work 'unsigned.hap'
    Move-Item $haps[0].FullName $unsignedHap
    $zip = [System.IO.Compression.ZipFile]::OpenRead($unsignedHap)
    try {
      $reader = [System.IO.StreamReader]::new($zip.GetEntry('module.json').Open())
      try { $module = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $api = [string]$module.app.minAPIVersion
    if (-not $api) { throw 'Missing minAPIVersion' }
    Invoke-SignTool (@('sign-app') + $common + @('-compatibleVersion', $api, '-inFile', $unsignedHap, '-outFile', $haps[0].FullName))
    Invoke-SignTool @('verify-app', '-inFile', $haps[0].FullName, '-outCertChain', (Join-Path $work 'hap-cert.cer'), '-outProfile', (Join-Path $work 'hap-profile.p7b'))
    $outHap = Join-Path $dist ("SSRVPN-$versionName-release-signed.hap")
    Copy-Item $haps[0].FullName $outHap -Force
    $repacked = Join-Path $work 'repacked.app'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($payload, $repacked, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Invoke-SignTool (@('sign-app') + $common + @('-inFile', $repacked, '-outFile', $outApp))
    Invoke-SignTool @('verify-app', '-inFile', $outApp, '-outCertChain', (Join-Path $work 'app-cert.cer'), '-outProfile', (Join-Path $work 'app-profile.p7b'))
    Get-FileHash $outApp, $outHap -Algorithm SHA256 | Select-Object Hash,Path
  }
} finally {
  $common = $null
  Remove-Item Env:SSRVPN_KEY_PASSWORD -ErrorAction SilentlyContinue
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
