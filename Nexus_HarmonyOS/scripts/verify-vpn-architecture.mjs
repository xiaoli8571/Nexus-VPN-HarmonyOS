#!/usr/bin/env node
/**
 * 架构与性能改造自动化验证（对应《SSRVPN HarmonyOS + mihomo VPN 架构与性能优化建议》
 * 全部尚未达标项）。分两层给出证据：
 *
 *   A) 可执行验证（真逻辑）：用 Node 24 原生 TS type-stripping 直接加载
 *      TunnelAuthority.ets 与 VpnRecoveryPolicy.ets（二者零 SDK 依赖，是 Extension
 *      运行态判定的单一真值源），对其纯函数逐分支断言，并仿真以下场景：
 *        - 后台 / 锁屏 / UI 进程被系统回收后：打开 App 直接还原真实 VPN 状态
 *        - 网络切换（Wi-Fi↔蜂窝↔断网）→ MTU 动态、恢复编排、去抖/退避
 *        - 内核崩溃 → 有限热恢复 → 升级一次 TUN 重建 → 耗尽 → Kill Switch 阻断
 *        - 弱网（恢复退避封顶、重连风暴抑制）
 *        - 长时间运行（恢复计数在存活时归零，不跨事件累计）
 *        - 心跳从 3s 定周期改为低频/事件驱动（陈旧窗口判定仍成立）
 *
 *   B) 源码级不变量断言：对 ClashConfigGenerator / VpnExtensionAbility /
 *      ConnectionOrchestrator 的真实 .ets 源文本，断言关键配置与结构约束
 *      （IPv4-only、DNS 分流/fallback/缓存、keepalive/连接池、动态 MTU 接线、
 *      移除周期心跳、热重载/热切换、Extension 状态消费）确实存在。
 *      这是对无法在离线 Node 里执行的 SDK 依赖代码的静态回归护栏，明确标注为
 *      SOURCE 断言，不冒充真机运行结果。
 *
 * 用法: node scripts/verify-vpn-architecture.mjs
 * 退出码: 0 = 全部通过；1 = 有断言失败
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');
const svcDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const etsRoot = join(appRoot, 'entry', 'src', 'main', 'ets');

let passed = 0;
const failures = [];
function record(label, cond, detail) {
  if (cond) { passed += 1; } else { failures.push(label + (detail ? ' -> ' + detail : '')); }
}
function eq(label, actual, expected) {
  record(label, Object.is(actual, expected), 'expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
}
function ok(label, cond) { record(label, cond === true, 'expected true, got ' + JSON.stringify(cond)); }
function has(label, text, needle) { record(label, text.includes(needle), 'missing: ' + needle); }
function notHas(label, text, needle) { record(label, !text.includes(needle), 'must NOT contain: ' + needle); }

// ── A) 加载真实纯逻辑源码（零 SDK 依赖，直接 type-strip 导入）───────────
const sandbox = join(tmpdir(), 'ssrvpn-arch-verify-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

function stageFrom(absPath, outName) {
  const src = readFileSync(absPath, 'utf8');
  const out = join(sandbox, outName + '.ts');
  writeFileSync(out, src, 'utf8');
  return out;
}
const taPath = stageFrom(join(svcDir, 'TunnelAuthority.ets'), 'TunnelAuthority');
const rpPath = stageFrom(join(svcDir, 'VpnRecoveryPolicy.ets'), 'VpnRecoveryPolicy');

let TA, RP;
try {
  TA = await import(pathToFileURL(taPath).href);
  RP = await import(pathToFileURL(rpPath).href);
} catch (e) {
  console.error('FATAL: 加载纯逻辑 .ets 源码失败: ' + (e && e.stack ? e.stack : e));
  process.exit(1);
}

// ── TunnelAuthority.parseExtensionStatus ────────────────────────────────
{
  const good = TA.parseExtensionStatus('{"phase":"running","mtu":1360,"netType":"cellular","coreAlive":true,"recoveryAttempts":0,"rebuilds":1,"seq":7,"ts":111,"detail":"tun-rebuilt:mtu-change"}');
  ok('parse.ok', good.ok === true);
  eq('parse.phase', good.phase, 'running');
  eq('parse.mtu', good.mtu, 1360);
  eq('parse.netType', good.netType, 'cellular');
  ok('parse.coreAlive', good.coreAlive === true);
  eq('parse.rebuilds', good.rebuilds, 1);
  eq('parse.seq', good.seq, 7);

  const notAlive = TA.parseExtensionStatus('{"phase":"leak-blocked","mtu":1400,"netType":"none","coreAlive":false,"recoveryAttempts":3,"rebuilds":0,"seq":9,"ts":222,"detail":"network-lost"}');
  ok('parse.coreAlive.false', notAlive.coreAlive === false);
  eq('parse.phase.blocked', notAlive.phase, 'leak-blocked');

  eq('parse.empty.ok=false', TA.parseExtensionStatus('').ok, false);
  eq('parse.garbage.ok=false', TA.parseExtensionStatus('not-json').ok, false);
  eq('parse.nophase.ok=false', TA.parseExtensionStatus('{"mtu":1400}').ok, false);
}

// ── TunnelAuthority.deriveUiPhase（UI 进程回收后还原真实状态）────────────
{
  const running = TA.parseExtensionStatus('{"phase":"running","mtu":1400,"netType":"wifi","coreAlive":true,"recoveryAttempts":0,"rebuilds":0,"seq":1,"ts":1,"detail":""}');
  eq('ui.running.fresh', TA.deriveUiPhase(running, true), 'connected');
  eq('ui.running.stale', TA.deriveUiPhase(running, false), 'stale');
  const rec = TA.parseExtensionStatus('{"phase":"recovering","mtu":1400,"netType":"wifi","coreAlive":false,"recoveryAttempts":1,"rebuilds":0,"seq":2,"ts":1,"detail":""}');
  eq('ui.recovering', TA.deriveUiPhase(rec, false), 'recovering');
  const blk = TA.parseExtensionStatus('{"phase":"leak-blocked","mtu":1400,"netType":"none","coreAlive":false,"recoveryAttempts":3,"rebuilds":2,"seq":3,"ts":1,"detail":""}');
  eq('ui.leak-blocked', TA.deriveUiPhase(blk, false), 'leak-blocked');
  const stopped = TA.parseExtensionStatus('{"phase":"stopped","mtu":1400,"netType":"wifi","coreAlive":false,"recoveryAttempts":0,"rebuilds":0,"seq":4,"ts":1,"detail":""}');
  eq('ui.stopped', TA.deriveUiPhase(stopped, true), 'disconnected');
  eq('ui.nostatus.fresh', TA.deriveUiPhase(new TA.ExtensionStatusView(), true), 'connected');
  eq('ui.nostatus.stale', TA.deriveUiPhase(new TA.ExtensionStatusView(), false), 'stale');
}

// ── TunnelAuthority.resolveAuthority（低频租约陈旧窗口判定）───────────────
{
  ok('auth.fresh.desired', TA.resolveAuthority(true, 3000, true).connected === true);
  ok('auth.stale.blocked', TA.resolveAuthority(true, TA.HEARTBEAT_STALE_MS + 1, false).connected === false);
  eq('auth.stale.reason', TA.resolveAuthority(true, TA.HEARTBEAT_STALE_MS + 1, false).reason, 'heartbeat-timeout');
  ok('auth.marker.keepalive', TA.resolveAuthority(true, -1, true).coreAlive === true);
  ok('auth.user-disc', TA.resolveAuthority(false, 0, true).connected === false);
  eq('auth.window', TA.HEARTBEAT_STALE_MS, 15000);
}

// ── VpnRecoveryPolicy: MTU 动态按承载 ────────────────────────────────────
eq('mtu.wifi', RP.mtuForNetType('wifi'), 1400);
eq('mtu.ethernet', RP.mtuForNetType('ethernet'), 1400);
eq('mtu.cellular', RP.mtuForNetType('cellular'), 1360);
eq('mtu.none.baseline', RP.mtuForNetType('none'), 1400);
eq('mtu.unknown.baseline', RP.mtuForNetType('unknown'), 1400);

// ── VpnRecoveryPolicy: 退避封顶（弱网重连风暴抑制）───────────────────────
eq('recover.delay0', RP.coreRecoveryDelayMs(0), 1000);
eq('recover.delay1', RP.coreRecoveryDelayMs(1), 2000);
eq('recover.delay2', RP.coreRecoveryDelayMs(2), 4000);
ok('recover.delayMonotonic', RP.coreRecoveryDelayMs(0) < RP.coreRecoveryDelayMs(1) && RP.coreRecoveryDelayMs(1) < RP.coreRecoveryDelayMs(2));
eq('recover.delayCap', RP.coreRecoveryDelayMs(20), 8000);
eq('recover.delayNeg', RP.coreRecoveryDelayMs(-3), 1000);
eq('rebuild.delay0', RP.tunnelRebuildDelayMs(0), 1500);
eq('rebuild.delay1', RP.tunnelRebuildDelayMs(1), 3000);
eq('rebuild.delayCap', RP.tunnelRebuildDelayMs(30), 8000);

// ── VpnRecoveryPolicy: Kill Switch / 泄漏阻断判定 ────────────────────────
eq('ks.userStopped.down', RP.leakSwitchDecision(true, 'wifi', false), 'down');
eq('ks.netlost.blocked', RP.leakSwitchDecision(false, 'none', false), 'leak-blocked');
eq('ks.coreDeadNetUp.recover', RP.leakSwitchDecision(false, 'wifi', false), 'recover');
eq('ks.alive.keep', RP.leakSwitchDecision(false, 'wifi', true), 'keep');

// ── VpnRecoveryPolicy: decideRecoveryAction 全场景状态机 ─────────────────
function inp(o) {
  const i = new RP.RecoveryInput();
  Object.assign(i, o);
  return i;
}
{
  eq('dec.none.alive', RP.decideRecoveryAction(inp({ coreAlive: true })), 'none');
  eq('dec.none.userStopped', RP.decideRecoveryAction(inp({ userStopped: true, coreAlive: false })), 'none');
  eq('dec.none.rebuilding', RP.decideRecoveryAction(inp({ rebuilding: true, coreAlive: false })), 'none');
  eq('dec.none.noConn', RP.decideRecoveryAction(inp({ connectionUp: false, coreAlive: false, netType: 'wifi' })), 'none');
  eq('dec.blocked.netlost', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'none', connectionUp: true })), 'leak-blocked');
  eq('dec.core0', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 0 })), 'core-recovery');
  eq('dec.core2', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 2 })), 'core-recovery');
  eq('dec.exhaust.rebuild', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 3, tunnelRebuilds: 0 })), 'tun-rebuild');
  eq('dec.exhaust.block', RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: 3, tunnelRebuilds: 2 })), 'leak-blocked');
}

// ── 场景仿真：内核崩溃 → 有限热恢复 → 一次 TUN 重建 → 耗尽 → 阻断 ─────────
{
  let attempts = 0, rebuilds = 0, actions = [];
  let coreAlive = false;
  for (let step = 0; step < 20 && !coreAlive; step++) {
    const a = RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: attempts, tunnelRebuilds: rebuilds }));
    actions.push(a);
    if (a === 'core-recovery') {
      attempts++;
      if (attempts >= 2) { coreAlive = true; } // 第 2 次恢复成功（弱网下多次才稳）
    } else if (a === 'tun-rebuild') { rebuilds++; coreAlive = true; }
    else if (a === 'leak-blocked') { break; }
  }
  ok('sim.core-crash.recovers', coreAlive === true);
  ok('sim.core-crash.first.core-recovery', actions[0] === 'core-recovery');
  ok('sim.core-crash.bounded', attempts <= RP.MAX_CORE_RECOVERY_ATTEMPTS && rebuilds <= RP.MAX_TUNNEL_REBUILDS);
}
// ── 场景仿真：无法恢复的持续内核死亡 → 必然收敛到 leak-blocked（不漏） ──────
{
  let attempts = 0, rebuilds = 0, last = '';
  for (let step = 0; step < 30; step++) {
    const a = RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'wifi', connectionUp: true, recoveryAttempts: attempts, tunnelRebuilds: rebuilds }));
    last = a;
    if (a === 'core-recovery') { attempts++; }
    else if (a === 'tun-rebuild') { rebuilds++; }
    else if (a === 'leak-blocked') { break; }
  }
  eq('sim.hopeless.converge.blocked', last, 'leak-blocked');
  ok('sim.hopeless.attemptsCapped', attempts === RP.MAX_CORE_RECOVERY_ATTEMPTS);
  ok('sim.hopeless.rebuildsCapped', rebuilds === RP.MAX_TUNNEL_REBUILDS);
}
// ── 场景仿真：断网期间不消耗恢复预算，保持阻断 ──────────────────────────
{
  const a = RP.decideRecoveryAction(inp({ coreAlive: false, netType: 'none', connectionUp: true, recoveryAttempts: 0, tunnelRebuilds: 0 }));
  eq('sim.netlost.noBudgetBurn', a, 'leak-blocked');
}
// ── 场景仿真：网络恢复后应重新具备恢复能力（计数归零）───────────────────
{
  ok('sim.recovered.reset', RP.shouldResetRecovery(true, 'wifi') === true);
  ok('sim.recovered.reset.cell', RP.shouldResetRecovery(true, 'cellular') === true);
  ok('sim.notAlive.noReset', RP.shouldResetRecovery(false, 'wifi') === false);
  ok('sim.netNone.noReset', RP.shouldResetRecovery(true, 'none') === false);
}
// ── 场景仿真：长稳（存活 tick 不触发动作）───────────────────────────────
{
  let actionsIn20 = 0;
  for (let s = 0; s < 20; s++) {
    const a = RP.decideRecoveryAction(inp({ coreAlive: true, netType: 'wifi', connectionUp: true }));
    if (a !== 'none') actionsIn20++;
  }
  eq('sim.longrun.idle.noActions', actionsIn20, 0);
}

// ══════════════════════════════════════════════════════════════════════
// B) 源码级不变量断言（真实 .ets 源文本）
// ══════════════════════════════════════════════════════════════════════
const genSrc = readFileSync(join(svcDir, 'ClashConfigGenerator.ets'), 'utf8');
{
  has('gen.ipv6-false', genSrc, "lines.push('ipv6: false')");
  has('gen.disable-ipv6', genSrc, "lines.push('disable-ipv6: true')");
  has('gen.dns.ipv6-false', genSrc, "lines.push('  ipv6: false')");
  notHas('gen.no.fake-ip-range6', genSrc, 'fake-ip-range6');
  notHas('gen.no.inet6-address', genSrc, 'inet6-address');
  has('gen.keepalive-idle', genSrc, 'keep-alive-idle:');
  has('gen.keepalive-interval', genSrc, 'keep-alive-interval:');
  has('gen.udp-timeout', genSrc, 'udp-timeout:');
  has('gen.tcp-concurrent', genSrc, 'tcp-concurrent: true');
  has('gen.unified-delay', genSrc, 'unified-delay: true');
  has('gen.dns.fallback', genSrc, "lines.push('  fallback:')");
  // 坑 40：fallback 非空会让内核在 config.Parse 阶段加载 MMDB（默认
  // fallback-filter.geoip=true），geoip.metadb 未就绪时启动被联网下载挂死。
  // 因此 fallback 必须被 useGeoip 包住（与 GEOIP 规则同开关）。
  has('gen.dns.fallback-guarded', genSrc, 'if (useGeoip) {');
  notHas('gen.dns.no.explicit-fallback-filter', genSrc, "lines.push('  fallback-filter:')");
  // ── 内核 smart 组（自动选择 / LightGBM）──────────────────────────────────
  // 与坑 24/40 同类：smart 组一旦声明，内核 GetModel() 会在启动路径同步下载
  // Model.bin（实测 90.1s 阻塞）。所以整块必须被 useSmart 约束，
  // 且 prefer-asn 必须显式 false（否则 geodata.InitASN() 同样同步拉 ASN.mmdb）。
  has('gen.smart.type', genSrc, "lines.push('    type: smart')");
  has('gen.smart.gated', genSrc, 'const emitSmart = useSmart &&');
  has('gen.smart.uselightgbm', genSrc, "lines.push('    uselightgbm: true')");
  has('gen.smart.prefer-asn-false', genSrc, "lines.push('    prefer-asn: false')");
  has('gen.smart.collectdata-false', genSrc, "lines.push('    collectdata: false')");
  has('gen.smart.group-name', genSrc, 'SMART_GROUP_NAME');
  has('gen.smart.no-single-node', genSrc, 'validNodes.length >= 2');
  has('gen.dns.cache-arc', genSrc, 'cache-algorithm: arc');
  has('gen.dns.disable-cache-false', genSrc, 'disable-cache: false');
  has('gen.dns.strategy', genSrc, 'strategy: prefer_ipv4');
  has('gen.dns.fake-ip-filter', genSrc, 'fake-ip-filter:');
  has('gen.dns.proxy-server-nameserver', genSrc, 'proxy-server-nameserver:');
  has('gen.profile.store-selections', genSrc, 'store-selections: true');
  has('gen.find-process-off', genSrc, 'find-process-mode: off');
  has('gen.log-warning', genSrc, 'log-level: warning');
  has('gen.auto-route-false', genSrc, 'auto-route: false');
}

const extSrc = readFileSync(join(etsRoot, 'vpnability', 'VpnExtensionAbility.ets'), 'utf8');
{
  has('ext.ipv6Accepted-false', extSrc, 'isIPv6Accepted: false');
  notHas('ext.no-ipv6-route', extSrc, "'::'");
  has('ext.mtu-from-active', extSrc, 'mtu: this.activeMtu');
  has('ext.attachTun-activeMtu', extSrc, 'attachTun(tunFd, this.activeMtu)');
  has('ext.uses-policy', extSrc, "from '../commons/services/VpnRecoveryPolicy'");
  has('ext.mtuForNetType', extSrc, 'mtuForNetType(netType)');
  has('ext.coreRecoveryDelay', extSrc, 'coreRecoveryDelayMs(');
  has('ext.tunnelRebuildDelay', extSrc, 'tunnelRebuildDelayMs(');
  has('ext.watchNetwork', extSrc, 'new NetworkStateWatcher()');
  has('ext.coreMonitor', extSrc, 'startCoreMonitor');
  has('ext.networkListenerImpl', extSrc, 'implements NetworkStateListener');
  has('ext.statusFile', extSrc, "STATUS_FILE = 'vpn_status.json'");
  has('ext.writeStatus', extSrc, 'private writeStatus(');
  has('ext.lease', extSrc, 'touchLivenessLease(');
  has('ext.recoverCoreNoTun', extSrc, 'scheduleCoreRecovery');
  has('ext.rebuildTun', extSrc, 'private async rebuildTunnel');
  has('ext.ensureConfigMtu', extSrc, 'ensureConfigMtu()');
  has('ext.publishStatus', extSrc, 'publishStateSnapshot(');
  // 移除 3s 定周期心跳：不应再有周期 setInterval 写心跳 / HEARTBEAT_INTERVAL_MS 常量
  notHas('ext.no-heartbeat-interval-const', extSrc, 'HEARTBEAT_INTERVAL_MS');
  notHas('ext.no-periodic-heartbeat-fn', extSrc, 'startHeartbeat(');
  notHas('ext.no-3000-ms', extSrc, '3000)');
}

const orchSrc = readFileSync(join(svcDir, 'ConnectionOrchestrator.ets'), 'utf8');
const pageSrc = readFileSync(join(etsRoot, 'pages', 'NodeSelectionPage.ets'), 'utf8');
const subsSrc = readFileSync(join(svcDir, 'SubscriptionService.ets'), 'utf8');
const settingsSrc = readFileSync(join(etsRoot, 'commons', 'models', 'AppSettings.ets'), 'utf8');
{
  has('orch.consume-extension-status', orchSrc, 'privateFs.readCapped');
  has('orch.extensionStatus', orchSrc, 'extensionStatus()');
  has('orch.deriveUiPhase', orchSrc, 'deriveUiPhase(');
  has('orch.statusFileConst', orchSrc, "EXTENSION_STATUS_FILE = 'vpn_status.json'");
  has('orch.reloadHot', orchSrc, 'async reloadRulesHot');
  has('orch.applyRulesChanged', orchSrc, 'async applyRulesChanged');
  has('orch.switchNodeHot', orchSrc, 'async switchNodeHot');
  has('orch.reloadFromPath', orchSrc, 'this.api.reloadFromPath');
  has('orch.ipv4-only-pass', orchSrc, 'false, proxyHosts');
  ok('orch.no-ipv6-detect-call', !orchSrc.includes('Ipv6Detector.hasIPv6'));
  // ── smart 组在编排层的接线 ──────────────────────────────────────────────
  has('orch.smart.model-ready-check', orchSrc, 'private isSmartModelReady()');
  has('orch.smart.magic-tree', orchSrc, '0x74 && b[1] === 0x72');
  // 内置 rawfile 铺盘是首选路径：纯联网下载在国内基本不可用
  // （jsdelivr 取不到 release 附件 → 404；更可用的 gh-proxy 限速严重）
  has('orch.smart.seed-from-rawfile', orchSrc, 'private seedSmartModelFromRawfile()');
  has('orch.smart.rawfile-api', orchSrc, "getRawFileContentSync('Model.bin')");
  has('orch.smart.seed-first', orchSrc,
    'this.seedSmartModelFromRawfile() || this.isSmartModelReady()');
  has('orch.smart.background-download', orchSrc, 'private downloadSmartModelInBackground()');
  // 模型准备必须与 autoSelectMode 解耦：默认就是 manual，只在 auto 下准备
  // 会让用户切到 auto 后还要再多等一轮连接
  has('orch.smart.prep-any-mode', orchSrc, 'if (!smartReady) {');
  has('orch.smart.gated-by-auto', orchSrc,
    'settings.autoSelectMode === AutoSelectModes.AUTO && smartReady');
  has('orch.smart.reused-on-reload', orchSrc, 'this.lastUseSmart');
  // 关键：auto+smart 时不能把 PROXY 钉到具体节点，否则内核按连接选点被彻底架空
  has('orch.smart.pin-group', orchSrc, 'pinSmartGroup');
  has('orch.smart.select-group', orchSrc, 'ClashConfigGenerator.SMART_GROUP_NAME');
  // UI 入口：smart 组只在内核配置里，而节点列表页的数据源是**订阅**（subs.nodes），
  // 所以不补一个合成行，用户在「全部节点」里永远看不到它。
  has('orch.smart.ui-ready-api', orchSrc, 'ensureSmartModelReady()');
  has('page.smart.row-id', pageSrc, "const SMART_ROW_ID = '__smart_group__'");
  has('page.smart.mk-row', pageSrc, 'private mkSmartRow()');
  has('page.smart.selectable', pageSrc, 'private smartSelectable()');
  has('page.smart.unshift', pageSrc, 'rows.unshift(this.mkSmartRow())');
  has('page.smart.row-flag', pageSrc, 'isSmart?: boolean');
  // 合成行没有 server/port：必须排除在测速之外，否则永远显示「超时」
  has('page.smart.skip-latency', pageSrc, 'if (row.isSmart === true) {');
  has('page.smart.skip-delete', pageSrc, 'if (row.isSmart === true) {');
  // 选中合成行的语义 = 切到自动模式（不是把它当节点传给 reconnectWithNode）
  has('page.smart.select-sets-auto', pageSrc, 'this.settings.autoSelectMode = AutoSelectModes.AUTO');
  // 真机踩过的坑：auto 模式下点真实节点，preferredNodeId 被存下但 connect() 里
  // pinSmartGroup 仍把 PROXY 指向 smart 组 → 手动选择被静默架空（"没法手动选节点"）。
  // 手动点真实节点必须退出自动模式。
  {
    const pick = /private async selectNode\(node: ProxyNode\)[\s\S]*?\n  \}/.exec(pageSrc);
    const pickSrc = pick ? pick[0] : '';
    ok('page.select.manual-exits-auto',
      pickSrc.includes('this.settings.autoSelectMode = AutoSelectModes.MANUAL;'));
    // 顺序必须在设置 preferredNodeId 之前，否则中间态是"auto + 新偏好"，语义混乱
    const exitAt = pickSrc.indexOf('AutoSelectModes.MANUAL');
    const prefAt = pickSrc.indexOf('this.settings.preferredNodeId = node.id;');
    ok('page.select.exit-before-pref', exitAt >= 0 && prefAt > exitAt);
    // 横幅读的是 @State，不同步会继续显示"自动选点"，与落库值矛盾
    ok('page.select.syncs-banner-state', pickSrc.includes('this.autoSelectMode = AutoSelectModes.MANUAL;'));
    // 真实节点分支绝不能带 SMART_ROW_ID 的提前 return
    ok('page.select.real-node-not-shortcircuited',
      !/node\.id === SMART_ROW_ID[\s\S]{0,1200}?this\.settings\.preferredNodeId = node\.id;[\s\S]{0,80}?return;/.test(pickSrc));
  }
  // 空状态必须区分"没启用自动模式"与"暂时没流量"，否则用户以为功能坏了
  has('page.smart.empty-title', pageSrc, 'private smartEmptyTitle()');
  has('page.smart.empty-hint', pageSrc, 'private smartEmptyHint()');
  has('page.smart.empty-distinguishes-mode', pageSrc, "return '尚未启用自动选择';");
  has('page.smart.card', pageSrc, 'SmartCard(row: NodeRow)');
  has('page.smart.no-reconnect-fake-node', pageSrc, "'autoSelectMode=auto'");
  ok('page.smart.sorts-top', pageSrc.includes('rows[0].isSmart === true'));
  // ── 新内核能力落地：info-node 过滤 / testLatencyUrl / policy-priority ──
  has('gen.smart.exclude-filter-constant', genSrc, 'SMART_INFO_NODE_FILTER');
  has('gen.smart.exclude-filter-emitted', genSrc,
    'exclude-filter: "${ClashConfigGenerator.SMART_INFO_NODE_FILTER}"');
  has('gen.smart.url-from-settings', genSrc,
    'const smartUrl: string = (settings.testLatencyUrl ?? \'\').trim();');
  has('gen.smart.policy-priority-setting', settingsSrc, 'smartPolicyPriority: string = \'\';');
  has('gen.smart.policy-priority-emitted', genSrc, 'policy-priority:');
  has('settings.smart-policy-serialize', settingsSrc, 'j.smartPolicyPriority = this.smartPolicyPriority;');
  has('settings.smart-policy-deserialize', settingsSrc,
    "s.smartPolicyPriority = typeof j.smartPolicyPriority === 'string'");
  // ── 自动选择视图（分组 chips 里的第二个）──
  has('page.smart.view-state', pageSrc, '@State smartView: boolean = false;');
  has('page.smart.view-chip', pageSrc, "Text('自动选择')");
  has('page.smart.enter', pageSrc, 'private enterSmartView()');
  has('page.smart.exit', pageSrc, 'private exitSmartView()');
  // 轮询必须在 onPageHide 停掉，否则退到后台还在每 3s 打内核 API
  has('page.smart.poll-stop-on-hide', pageSrc, 'this.stopSmartPoll();');
  has('page.smart.active-source', pageSrc, 'smartActiveNodes');
  // 真机踩过的坑：refreshSmartActive() 只改了 @State 却没重建 this.nodes，
  // 而 UI 渲染的是 this.nodes → 分组永远空白。异步拉取完成后必须 rebuildRows()。
  {
    const body = /private async refreshSmartActive\(\)[\s\S]*?\n  \}/.exec(pageSrc);
    const bodySrc = body ? body[0] : '';
    ok('page.smart.refresh-found', bodySrc.length > 0);
    ok('page.smart.refresh-rebuilds', bodySrc.includes('this.rebuildRows();'));
    // rebuildRows 必须在 await 之后：在 await 之前重建拿到的还是旧（空）数组
    const awaitAt = bodySrc.indexOf('await this.orchestrator.api.smartActiveNodes');
    const lastRebuild = bodySrc.lastIndexOf('this.rebuildRows();');
    ok('page.smart.rebuild-after-await', awaitAt >= 0 && lastRebuild > awaitAt);
  }
  // 不能复用 filterSubId 表达自动选择视图：它是订阅 id，混用会让过滤分支误判合成行
  ok('page.smart.no-filterSubId-reuse',
    !pageSrc.includes('this.filterSubId = SMART_ROW_ID'));
  // ── 测速频率：只在本次启动 / 订阅变更后测一次 ──
  has('page.latency.session-gate', pageSrc, "AppStorage.get<string>('latency_session_stamp')");
  has('page.latency.revision-key', pageSrc, "'subscription_revision'");
  has('subs.revision-bump', subsSrc, "AppStorage.setOrCreate('subscription_revision'");
  // 注意只能查数组本体：源码注释里为了说明「为什么删掉」会提到这些域名，查全文会误报。
  // 文件里有多个 `const mirrors`（geoip 的在前），必须挑出 Model.bin 那一个。
  const mirrorBlock = (() => {
    const all = [...orchSrc.matchAll(/const mirrors: string\[\] = \[([\s\S]*?)\];/g)]
      .map(m => m[1]);
    return all.find(b => b.includes('Model.bin')) || '';
  })();
  ok('orch.smart.mirror-block-found', mirrorBlock.length > 0);
  ok('orch.smart.no-dead-jsdelivr-mirror', !mirrorBlock.includes('@LightGBM-Model/Model.bin'));
  ok('orch.smart.no-dead-ghfast', !mirrorBlock.includes('ghfast.top'));
  ok('orch.smart.has-usable-mirror', mirrorBlock.includes('gh-proxy.com'));
  ok('orch.no-ipv6-inbound-param', !orchSrc.includes('ipv6Inbound'));
  // IPv4-only 统一：IPv6 探测模块已整体移除，杜绝任何双栈回开通道。
  ok('ipv4only.detector-removed', !existsSync(join(svcDir, 'Ipv6Detector.ets')));
}

const apiSrc = readFileSync(join(svcDir, 'ClashApiService.ets'), 'utf8');
{
  has('api.reloadFromPath', apiSrc, 'async reloadFromPath');
  has('api.putConfigs-force', apiSrc, '/configs?force=true');
  has('api.setMode-via-put', apiSrc, "payload['mode']");
}

const homeSrc = readFileSync(join(etsRoot, 'pages', 'HomePage.ets'), 'utf8');
const rulesSrc = readFileSync(join(etsRoot, 'pages', 'RulesPage.ets'), 'utf8');
has('home.hotmode', homeSrc, 'applyProxyMode');
// 2026-09-17 规则入口集中到主页「网络规则」4 选项弹窗（规则/强制代理/强制直连/应用分流），
// RulesPage 仍由弹窗跳转进入并保留 applyRulesChanged。
has('home.rules-entry', homeSrc, 'pages/RulesPage');
has('rules.hotmode', rulesSrc, 'applyRulesChanged');
const nselSrc = readFileSync(join(etsRoot, 'pages', 'NodeSelectionPage.ets'), 'utf8');
has('nsel.forceReconnectWithNode', nselSrc, 'reconnectWithNode(node, this.subs');
notHas('nsel.no-hot-node-switch', nselSrc, 'this.orchestrator.switchNodeHot(node.name)');
// 2026-09-17 规则入口已集中到主页卡片：网站规则改走 SiteRoutingPage（applyRulesChanged），
// 节点页不再承载规则编辑，因此这里断言节点页确实不再包含规则热更新入口。
const siteSrc = readFileSync(join(etsRoot, 'pages', 'SiteRoutingPage.ets'), 'utf8');
has('site.rules-changed', siteSrc, 'applyRulesChanged');
notHas('nsel.rules-entry-removed', nselSrc, 'openNetworkRules');

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log('===== SSRVPN 架构与性能改造自动化验证 =====');
console.log('[A] 可执行纯逻辑：TunnelAuthority.ets / VpnRecoveryPolicy.ets（Node 24 type-stripping）');
console.log('[B] 源码级不变量：ClashConfigGenerator / VpnExtensionAbility / ConnectionOrchestrator / ClashApiService / 页面');
console.log('-----------------------------------------');
console.log(`PASSED=${passed}  FAILED=${failures.length}  TOTAL=${passed + failures.length}`);
if (failures.length > 0) {
  for (const f of failures) console.log('  FAIL ' + f);
  console.log('RESULT: ARCHITECTURE CHECKS FAILED');
  process.exit(1);
}
console.log('RESULT: ALL ARCHITECTURE CHECKS PASSED');
