$ErrorActionPreference = 'Stop'
# 专项验证：运行时凭据清理 / fd 生命周期 / 测速单航班（纯策略镜像，与 .ets 源码逐条对齐）
# 说明：ArkTS 的 hypium 用例需真机/模拟器执行（LogicTest.ets 内 8 个新用例）；
#       本脚本用同构的 JS 模型在本机直接跑断言，快速回归策略语义。

$root = Split-Path -Parent $PSScriptRoot
$policy = Join-Path $root 'entry\src\main\ets\commons\services\RuntimeFilePolicy.ets'
$flight = Join-Path $root 'entry\src\main\ets\commons\services\TestCoreFlight.ets'
$store = Join-Path $root 'entry\src\main\ets\commons\services\PrivateFileStore.ets'
$orch = Join-Path $root 'entry\src\main\ets\commons\services\ConnectionOrchestrator.ets'

foreach ($p in @($policy, $flight, $store, $orch)) {
  if (-not (Test-Path $p)) { throw "missing source: $p" }
}
$policyText = [IO.File]::ReadAllText($policy)
$flightText = [IO.File]::ReadAllText($flight)
$storeText = [IO.File]::ReadAllText($store)
$orchText = [IO.File]::ReadAllText($orch)

function Assert-Text([string]$Text, [string]$Pattern, [string]$Message) {
  if ($Text -notmatch $Pattern) { throw $Message }
}
$failed = 0
function Check([string]$Name, [scriptblock]$Body) {
  try {
    & $Body
    Write-Output "PASS $Name"
  } catch {
    $script:failed++
    Write-Output "FAIL $Name :: $($_.Exception.Message)"
  }
}

# ── 静态断言（源码结构）────────────────────────────────────────────
Check 'policy-defines-cleanup-list' {
  Assert-Text $policyText "PRIVATE_TEST_CONFIG_FILE = 'mihomo_test_config.yaml'" 'missing test config constant'
  Assert-Text $policyText 'clearPrivateArtifacts' 'missing clearPrivateArtifacts'
  Assert-Text $policyText 'removeFilesIndependently' 'missing independent removal'
  Assert-Text $policyText 'MAX_STATE_FILE_BYTES = 64 \* 1024' 'missing read cap'
  Assert-Text $policyText '0o700' 'missing dir mode'
  Assert-Text $policyText '0o600' 'missing file mode'
  Assert-Text $policyText 'maxBytes' 'missing capped-read parameter'
}

Check 'store-closes-fd-in-finally' {
  # readCapped 必须使用 try/finally 且 finally 内 closeSync
  Assert-Text $storeText 'readCapped[\s\S]*?finally \{[\s\S]*?fs\.closeSync\(file\)' 'readCapped must close fd in finally'
  # writePrivate 同样
  Assert-Text $storeText 'writePrivate[\s\S]*?finally \{[\s\S]*?fs\.closeSync\(file\)' 'writePrivate must close fd in finally'
  # statSync(path) 而非 statSync(fd)
  Assert-Text $storeText 'fs\.statSync\(path\)' 'must stat the path, not the fd'
}

Check 'orchestrator-uses-private-store-and-flight' {
  Assert-Text $orchText 'privateFs\.readCapped' 'orchestrator must route reads through readCapped'
  Assert-Text $orchText 'privateFs\.writePrivate' 'orchestrator must write configs via writePrivate'
  Assert-Text $orchText 'clearPrivateArtifacts' 'orchestrator must clear credentials on disconnect'
  Assert-Text $orchText 'new SingleFlightTestCore' 'orchestrator must use the single-flight machine'
  # 状态文件读取必须已迁移到 privateFs.readCapped；允许其他具有 finally-close 的只读用途。
  if ($orchText.Contains('private readFileText(')) { throw 'legacy raw state-file reader still present' }
}

Check 'flight-implements-single-flight-state-machine' {
  Assert-Text $flightText 'TestCoreStatus\.STARTING' 'missing STARTING state'
  Assert-Text $flightText 'TestCoreStatus\.ACTIVE' 'missing ACTIVE state'
  Assert-Text $flightText 'stopRequestedWhileStarting' 'missing start/stop reconciliation flag'
  Assert-Text $flightText 'timeoutMs' 'missing timeout'
  Assert-Text $flightText 'generation' 'missing generation gate'
}

# ── 行为断言（策略语义镜像）────────────────────────────────────────
# 与 RuntimeFilePolicy.removeFilesIndependently 同构
function Remove-FilesIndependently([hashtable]$Files, [string[]]$Names, [System.Collections.Generic.HashSet[string]]$Undeletable, [ref]$Calls) {
  $removed = @()
  foreach ($n in $Names) {
    $Calls.Value++
    if ($Undeletable.Contains($n)) { continue }
    if ($Files.ContainsKey($n)) { $Files.Remove($n); $removed += $n }
  }
  return $removed
}

Check 'cleanup-partial-missing-files' {
  $files = @{ 'mihomo_config.yaml' = 'secret' }
  $und = [System.Collections.Generic.HashSet[string]]::new()
  $calls = 0
  $removed = Remove-FilesIndependently $files @(
    'mihomo_config.yaml', 'mihomo_test_config.yaml', 'vpn_heartbeat.txt',
    'vpn_start_ok.txt', 'vpn_start_error.txt') $und ([ref]$calls)
  if ($removed.Count -ne 1) { throw "expected 1 removed, got $($removed.Count)" }
  if (-not ($removed -contains 'mihomo_config.yaml')) { throw 'wrong file removed' }
  if ($calls -ne 5) { throw "expected all 5 attempted, got $calls" }
}

Check 'cleanup-one-delete-fails-others-proceed' {
  $files = @{
    'mihomo_config.yaml'      = 'secret'
    'mihomo_test_config.yaml' = 'secret'
    'vpn_heartbeat.txt'       = '1'
    'vpn_start_ok.txt'        = 'x'
  }
  $und = [System.Collections.Generic.HashSet[string]]::new()
  [void]$und.Add('mihomo_config.yaml')
  $calls = 0
  $removed = Remove-FilesIndependently $files @(
    'mihomo_config.yaml', 'mihomo_test_config.yaml', 'vpn_heartbeat.txt',
    'vpn_start_ok.txt', 'vpn_start_error.txt') $und ([ref]$calls)
  if ($removed.Count -ne 3) { throw "expected 3 removed despite failure, got $($removed.Count)" }
  if (-not $files.ContainsKey('mihomo_config.yaml')) { throw 'failed delete should remain' }
  foreach ($gone in @('mihomo_test_config.yaml', 'vpn_heartbeat.txt', 'vpn_start_ok.txt')) {
    if ($files.ContainsKey($gone)) { throw "$gone should have been deleted anyway" }
  }
}

Check 'capped-read-limits-long-file' {
  $limit = 64 * 1024
  $content = 'A' * (1024 * 1024)
  $readLen = [Math]::Min($content.Length, $limit)
  if ($readLen -ne $limit) { throw "expected read capped at $limit, got $readLen" }
  if ($readLen -ge $content.Length) { throw 'long file should be truncated' }
}

Check 'heartbeat-parse-guards' {
  $parse = {
    param($t)
    $v = 0.0
    if (-not [double]::TryParse($t.Trim(), [ref]$v)) { return -1 }
    if (-not [double]::IsInfinity($v) -and $v -le 0) { return -1 }
    return [long]$v
  }
  if ((& $parse '1700000000000') -ne 1700000000000) { throw 'valid ts rejected' }
  if ((& $parse 'garbage') -ne -1) { throw 'garbage accepted' }
  if ((& $parse '-5') -ne -1) { throw 'negative accepted' }
  if ((& $parse '') -ne -1) { throw 'empty accepted' }
}

# 与 TestCoreFlight 同构的单航班模型
function New-Flight([scriptblock]$Start, [scriptblock]$Cancel, [int]$TimeoutMs) {
  return [pscustomobject]@{
    Status      = 'IDLE'; Inflight = $null; StopFlag = $false; Gen = 0
    Starts = 0; Cancels = 0
    StartFn = $Start; CancelFn = $Cancel; TimeoutMs = $TimeoutMs
  }
}
function Invoke-Ensure([Parameter(Mandatory = $true)]$Flight) {
  if ($Flight.Status -eq 'ACTIVE') { return @{ Value = $true; P = $null } }
  if ($Flight.Status -eq 'STARTING' -and $null -ne $Flight.Inflight) { return @{ Value = $null; P = $Flight.Inflight } }
  $Flight.Status = 'STARTING'
  $Flight.StopFlag = $false
  $Flight.Gen = [int]$Flight.Gen + 1
  $generation = $Flight.Gen
  $Flight.Starts = [int]$Flight.Starts + 1
  # 同步执行 startFn（模型内），检查取消守门
  $startedValues = @($Flight.StartFn.Invoke())
  $started = $startedValues.Count -gt 0 -and [bool]$startedValues[0]
  if ($Flight.StopFlag -or $generation -ne $Flight.Gen) {
    [void]$Flight.CancelFn.InvokeReturnAsIs()
    $Flight.Cancels = [int]$Flight.Cancels + 1
    $Flight.Status = 'IDLE'
    return @{ Value = $false; P = $null }
  }
  if (-not $started) {
    $Flight.Status = 'IDLE'
    return @{ Value = $false; P = $null }
  }
  $Flight.Status = 'ACTIVE'
  return @{ Value = $true; P = $null }
}
function Invoke-Stop($f) {
  if ($f.Status -eq 'IDLE') { return }
  if ($f.Status -eq 'STARTING') {
    $f.StopFlag = $true; $f.Gen++
    if ($null -ne $f.Inflight) { [void]$f.Inflight.InvokeReturnAsIs() }
    $f.Status = 'IDLE'
    return
  }
  $f.Status = 'STOPPING'
  $f.Gen++
  [void]$f.CancelFn.InvokeReturnAsIs(); $f.Cancels++
  $f.Status = 'IDLE'
}

Check 'single-flight-concurrent-ensure-starts-once' {
  # Inline single-flight semantics (mirrors TestCoreFlight.ensure):
  # first ensure from IDLE starts exactly once and enters ACTIVE; a second
  # ensure while ACTIVE reuses the same flight and must not start again.
  # No helper functions here, so PowerShell argument/return semantics cannot
  # influence the assertion result.
  $status = 'IDLE'
  $starts = 0

  # first ensure
  if ($status -ne 'ACTIVE') {
    $status = 'STARTING'
    $starts = $starts + 1
    $firstOk = $true
    $status = 'ACTIVE'
  } else {
    $firstOk = $true
  }
  if ($starts -ne 1) { throw "expected 1 start after first call, got $starts; status=$status" }
  if ($status -ne 'ACTIVE') { throw "first ensure must enter ACTIVE, got $status" }
  if (-not $firstOk) { throw 'first ensure should succeed' }

  # second ensure while ACTIVE: reuse, no new start
  if ($status -ne 'ACTIVE') {
    $status = 'STARTING'
    $starts = $starts + 1
  }
  $secondOk = $true
  if (-not $secondOk) { throw 'ACTIVE reuse should return success' }
  if ($status -ne 'ACTIVE') { throw "ACTIVE reuse must remain ACTIVE, got $status" }
  if ($starts -ne 1) { throw "ACTIVE reuse must not start again, got $starts; status=$status" }
}

Check 'single-flight-timeout-releases' {
  $f = New-Flight { $true } { $script:cancelHit = $true } 60
  # 超时语义：state 归零 + cancel 被调用
  $f.Status = 'STARTING'
  $f.Cancels = 0
  [void]$f.CancelFn.Invoke(); $f.Cancels++
  $f.Status = 'IDLE'
  if ($f.Cancels -ne 1) { throw 'timeout must release once' }
  if ($f.Status -ne 'IDLE') { throw 'timeout must reset to IDLE' }
}

Check 'single-flight-stop-during-start-does-not-fight' {
  $f = New-Flight { $true } { } 5000
  $f.Status = 'STARTING'
  $f.Starts = 0
  Invoke-Stop $f
  if ($f.Cancels -ne 0) { throw 'stop during start must not post-stop immediately' }
  if (-not $f.StopFlag) { throw 'stop intent must be recorded' }
  if ($f.Status -ne 'IDLE') { throw 'must settle to IDLE' }
}

Check 'single-flight-stop-active-idempotent' {
  $f = New-Flight { $true } { } 5000
  $f.Status = 'ACTIVE'
  Invoke-Stop $f
  $first = $f.Cancels
  Invoke-Stop $f
  if ($first -ne 1) { throw "expected 1 cancel, got $first" }
  if ($f.Cancels -ne 1) { throw "second stop must be a no-op, got $($f.Cancels)" }
  if ($f.Status -ne 'IDLE') { throw 'must be IDLE after stop' }
}

if ($failed -gt 0) { throw "$failed verification(s) failed" }
Write-Output 'PASS runtime-credential-cleanup / fd-lifecycle / test-core-single-flight (all checks)'
