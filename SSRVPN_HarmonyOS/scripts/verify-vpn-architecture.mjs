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
