/**
 * LatencyEngine 真实行为验证（跑真代码，不是读源码）。
 *
 * 为什么必须做：LatencyEngine 是本次重做的核心（唯一入口、并发池、硬截止、
 * 取消、通道分类、TESTING 收尾），但此前只有**源码断言**覆盖 —— 排序、持久化、
 * 徽标都已经真跑了，引擎反而是唯一没被执行过的一环。
 *
 * 做法：把 LatencyEngine.ets 暂存为 .ts 后 import，注入全部依赖的桩
 * （api 是构造参数，天然可注入；其余是模块级单例，用桩模块替换）：
 *   - ClashApiService 桩：可编程的 testLatencyDetailed（按节点名返回结果/抛错/延迟）
 *   - ConnectionOrchestrator 桩：记录 scheduleTestCoreRecycle 调用 + refreshLatencyEndpoint
 *   - AppLogger 桩：吞日志
 *   - DirectLatencyTester 桩：离线通道
 *   - LatencyState / LatencyController / ProxyNode：用真实实现（也是真跑的一部分）
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const appRoot = path.join(here, '..');
const svc = path.join(appRoot, 'entry/src/main/ets/commons/services/');

let passed = 0;
let failed = 0;
const failures = [];
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
async function checkAsync(name, fn) {
  try {
    await fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failed++;
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
function eq(a, b, label) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`${label}: expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
function ok(c, label) {
  if (!c) throw new Error(label);
}

// ── 暂存 ──────────────────────────────────────────────────────────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'latency-engine-'));
const w = (n, s) => fs.writeFileSync(path.join(stage, n), s, 'utf8');

// 真实现（真跑）
for (const f of ['LatencyState', 'LatencyController']) {
  const src = fs.readFileSync(path.join(svc, f + '.ets'), 'utf8')
    .replace(/from '(\.\/[A-Za-z0-9_]+)'/g, "from '$1.ts'");
  w(f + '.ts', src);
}

// 桩：ProxyNode
w('ProxyNode.ts', `
export class ProxyNodeType {
  static readonly SS: string = 'ss';
  static readonly SSR: string = 'ssr';
}
export class ProxyNode {
  name: string = '';
  type: string = '';
  server: string = '';
  port: number = 0;
  constructor(name: string = '', server: string = '') {
    this.name = name; this.server = server; this.type = 'ss'; this.port = 443;
  }
}
`);

// 桩：AppLogger
w('AppLogger.ts', `
export class AppLogger {
  static info(_t: string, _m: string): void {}
  static warn(_t: string, _m: string): void {}
  static error(_t: string, _m: string): void {}
  static errText(e: Object): string { return String(e); }
}
`);

// 桩：ClashApiService（含 LatencyFailKind / LatencyProbeResult 真形状）
w('ClashApiService.ts', `
export class LatencyFailKind {
  static readonly NONE: string = '';
  static readonly CORE_NOT_READY: string = 'core_not_ready';
  static readonly SWITCH_FAILED: string = 'switch_failed';
  static readonly NETWORK_UNREACHABLE: string = 'network_unreachable';
  static readonly TIMEOUT: string = 'timeout';
  static readonly UNSUPPORTED: string = 'unsupported';
  static readonly PORT_ONLY: string = 'port_reachable_only';
  static readonly UNTESTED: string = 'untested';
  static readonly CANCELLED: string = 'cancelled';
}
export class LatencyProbeResult {
  delayMs: number = -1;
  failKind: string = '';
  httpCode: number = 0;
  detail: string = '';
}
/** 可编程内核桩：由测试注入 handler(name) -> LatencyProbeResult | Promise。
 *  cancelInflight 忠实模拟真实实现：真实代码里是 req.destroy() → req.request 抛错
 *  → classifyTransportError() → CORE_NOT_READY（见 ClashApiService.ets:406）。
 *  桩若不模拟这一点，"取消"这条路径就测不出真行为。 */
export class ClashApiService {
  static handler = null;
  static calls = [];
  static maxInflight = 0;
  static _inflight = 0;
  static cancelled = 0;
  static _pending = [];
  static reset() {
    ClashApiService.handler = null;
    ClashApiService.calls = [];
    ClashApiService.maxInflight = 0;
    ClashApiService._inflight = 0;
    ClashApiService.cancelled = 0;
    ClashApiService._pending = [];
  }
  async testLatencyDetailed(name, url, timeoutMs) {
    ClashApiService.calls.push({ name, url, timeoutMs });
    ClashApiService._inflight++;
    if (ClashApiService._inflight > ClashApiService.maxInflight) {
      ClashApiService.maxInflight = ClashApiService._inflight;
    }
    const state = { aborted: false };
    const abort = () => { state.aborted = true; };
    ClashApiService._pending.push(abort);
    try {
      const h = ClashApiService.handler;
      if (h === null) { throw new Error('no handler'); }
      const r = await h(name, url, timeoutMs);
      if (state.aborted) {
        // 被 destroy 的请求在真实实现里抛错并被归类为通道不可用
        return probeResult(-1, LatencyFailKind.CORE_NOT_READY, 0);
      }
      return r;
    } finally {
      const i = ClashApiService._pending.indexOf(abort);
      if (i >= 0) { ClashApiService._pending.splice(i, 1); }
      ClashApiService._inflight--;
    }
  }
  cancelInflight() {
    ClashApiService.cancelled++;
    const pend = ClashApiService._pending.slice();
    ClashApiService._pending = [];
    for (const a of pend) { a(); }
    return pend.length;
  }
}
export function probeResult(delayMs, failKind = '', httpCode = 0) {
  const r = new LatencyProbeResult();
  r.delayMs = delayMs; r.failKind = failKind; r.httpCode = httpCode;
  return r;
}
`);

// 桩：DirectLatencyTester（离线通道）
w('DirectLatencyTester.ts', `
export class DirectLatencyTester {
  static handler = null;
  static reset() { DirectLatencyTester.handler = null; }
  static async testNode(node, _timeoutMs) {
    const h = DirectLatencyTester.handler;
    if (h === null) { return 30; }
    return await h(node);
  }
}
`);

// 桩：ConnectionOrchestrator（记录回收/自愈调用）
w('ConnectionOrchestrator.ts', `
export class ConnectionOrchestrator {
  static recycles = [];
  static recoverCalls = 0;
  static recoverResult = true;
  static reset() {
    ConnectionOrchestrator.recycles = [];
    ConnectionOrchestrator.recoverCalls = 0;
    ConnectionOrchestrator.recoverResult = true;
  }
  static _inst = null;
  static instance() {
    if (ConnectionOrchestrator._inst === null) {
      ConnectionOrchestrator._inst = new ConnectionOrchestrator();
    }
    return ConnectionOrchestrator._inst;
  }
  scheduleTestCoreRecycle(ms) { ConnectionOrchestrator.recycles.push(ms); }
  async refreshLatencyEndpoint(_api) {
    ConnectionOrchestrator.recoverCalls++;
    return ConnectionOrchestrator.recoverResult;
  }
}
`);

// 真模块：LatencyEngine（import 指向桩）
let engSrc = fs.readFileSync(path.join(svc, 'LatencyEngine.ets'), 'utf8');
engSrc = engSrc
  .replace(/from '\.\.\/utils\/AppLogger'/g, "from './AppLogger.ts'")
  .replace(/from '\.\/ClashApiService'/g, "from './ClashApiService.ts'")
  .replace(/from '\.\/ConnectionOrchestrator'/g, "from './ConnectionOrchestrator.ts'")
  .replace(/from '\.\/LatencyState'/g, "from './LatencyState.ts'")
  .replace(/from '\.\/LatencyController'/g, "from './LatencyController.ts'")
  .replace(/from '\.\.\/models\/ProxyNode'/g, "from './ProxyNode.ts'")
  .replace(/from '\.\/DirectLatencyTester'/g, "from './DirectLatencyTester.ts'");
ok(!/from '@ohos/.test(engSrc), 'staged engine must not import ohos kits');
w('LatencyEngine.ts', engSrc);

const E = await import(pathToFileURL(path.join(stage, 'LatencyEngine.ts')).href);
const { LatencyEngine, LatencyRunOptions, LATENCY_CONCURRENCY, BATCH_DEADLINE_MS } = E;
const { LatencyController } = await import(pathToFileURL(path.join(stage, 'LatencyController.ts')).href);
const { LatencyState, LatencyChannel } = await import(pathToFileURL(path.join(stage, 'LatencyState.ts')).href);
const { ClashApiService, LatencyFailKind, probeResult } =
  await import(pathToFileURL(path.join(stage, 'ClashApiService.ts')).href);
const { ConnectionOrchestrator } = await import(pathToFileURL(path.join(stage, 'ConnectionOrchestrator.ts')).href);
const { ProxyNode } = await import(pathToFileURL(path.join(stage, 'ProxyNode.ts')).href);
const { DirectLatencyTester } = await import(pathToFileURL(path.join(stage, 'DirectLatencyTester.ts')).href);

const URL_ = 'https://www.gstatic.com/generate_204';
function nodes(n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(new ProxyNode('node-' + i, '1.2.3.' + (i % 250 + 1)));
  return out;
}
function fresh() {
  LatencyController.clearAll();
  ClashApiService.reset();
  DirectLatencyTester.reset();
  ConnectionOrchestrator.reset();
}
function opts(over = {}) {
  const o = new LatencyRunOptions();
  o.force = over.force ?? true;
  o.timeoutMs = over.timeoutMs ?? 5000;
  o.onResult = null;
  o.onProgress = over.onProgress ?? null;
  return o;
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── 1. 并发上限：真跑 worker 池 ───────────────────────────────────────────
await checkAsync('并发严格不超过 LATENCY_CONCURRENCY（真跑 worker 池）', async () => {
  fresh();
  ClashApiService.handler = async (name) => {
    await sleep(30);
    return probeResult(100);
  };
  const api = new ClashApiService();
  const run = LatencyEngine.start(api, nodes(40), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  ok(ClashApiService.maxInflight <= LATENCY_CONCURRENCY,
    `max inflight ${ClashApiService.maxInflight} must be <= ${LATENCY_CONCURRENCY}`);
  ok(ClashApiService.maxInflight >= 2,
    `pool should actually parallelise (got ${ClashApiService.maxInflight})`);
  eq(p.measured, 40, 'all measured');
  eq(p.finished, 40, 'all finished');
  eq(p.failed, 0, 'no failures');
  eq(ClashApiService.calls.length, 40, 'one probe per node');
});

// ── 2. 每个探测都带 URL 与 timeout（契约：timeout 必传且 <=32767） ─────────
await checkAsync('每个探测都显式带 HTTPS url 与合法 timeout', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(50);
  const run = LatencyEngine.start(new ClashApiService(), nodes(6), URL_, opts({ timeoutMs: 5000 }));
  await run.run();
  LatencyEngine.release(run);
  for (const c of ClashApiService.calls) {
    eq(c.url, URL_, 'url passed through');
    ok(c.url.startsWith('https://'), 'must be https (unified-delay + hijacking proxies)');
    ok(c.timeoutMs > 0 && c.timeoutMs <= 32767, `timeout ${c.timeoutMs} must be 1..32767`);
  }
});

// ── 3. 五态落库 ───────────────────────────────────────────────────────────
await checkAsync('结果按五态落库：实测/超时/失败各自可区分', async () => {
  fresh();
  const table = {
    'node-0': probeResult(42),
    'node-1': probeResult(-1, LatencyFailKind.TIMEOUT, 504),
    'node-2': probeResult(-1, LatencyFailKind.NETWORK_UNREACHABLE, 503),
    'node-3': probeResult(-1, LatencyFailKind.SWITCH_FAILED, 404),
  };
  ClashApiService.handler = async (name) => table[name];
  const run = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(LatencyController.stateFor('node-0'), LatencyState.MEASURED, 'measured');
  eq(LatencyController.recordFor('node-0').delayMs, 42, 'delay value');
  eq(LatencyController.stateFor('node-1'), LatencyState.TIMEOUT, 'timeout');
  eq(LatencyController.stateFor('node-2'), LatencyState.FAILED, 'network unreachable -> failed');
  eq(LatencyController.stateFor('node-3'), LatencyState.FAILED, 'switch failed -> failed');
  eq(p.measured, 1, 'progress measured');
  eq(p.timeout, 1, 'progress timeout');
  eq(p.failed, 2, 'progress failed');
  // 超时与失败必须是不同的状态（旧实现把两者都画成"超时"）
  ok(LatencyController.stateFor('node-1') !== LatencyController.stateFor('node-2'),
    'timeout and failure must stay distinguishable');
});

// ── 4. delay==0 绝不当有效延迟 ────────────────────────────────────────────
await checkAsync('内核回 200 但 delay==0（失败语义）不得记为有效延迟', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(0, LatencyFailKind.NONE, 200);
  const run = LatencyEngine.start(new ClashApiService(), nodes(3), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.measured, 0, 'must not count as measured');
  for (const n of ['node-0', 'node-1', 'node-2']) {
    ok(LatencyController.stateFor(n) !== LatencyState.MEASURED, `${n} must not be MEASURED`);
  }
});

// ── 5. 通道故障绝不写成节点失败 + 整批作废 ────────────────────────────────
await checkAsync('内核不可用：连续命中后作废整批，且绝不盖章成节点失败', async () => {
  fresh();
  ConnectionOrchestrator.recoverResult = false; // 自愈失败 -> 应作废
  ClashApiService.handler = async () => probeResult(-1, LatencyFailKind.CORE_NOT_READY, 0);
  const run = LatencyEngine.start(new ClashApiService(), nodes(30), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.coreUnavailable, true, 'batch must be flagged unavailable');
  eq(p.failed, 0, 'a dead core must NOT produce node failures');
  eq(p.timeout, 0, 'nor timeouts');
  // 没有节点被写成失败/超时
  for (let i = 0; i < 30; i++) {
    const st = LatencyController.stateFor('node-' + i);
    ok(st !== LatencyState.FAILED && st !== LatencyState.TIMEOUT,
      `node-${i} must not be stamped failed/timeout (got ${st})`);
  }
  ok(p.finished < 30, `batch should abort early (finished=${p.finished})`);
  ok(ConnectionOrchestrator.recoverCalls <= 1, 'recovery attempted at most once per batch');
});

// ── 6. 通道自愈成功则继续跑完 ─────────────────────────────────────────────
await checkAsync('中途失联但自愈成功：批次继续跑完', async () => {
  fresh();
  ConnectionOrchestrator.recoverResult = true;
  let n = 0;
  ClashApiService.handler = async () => {
    n++;
    // 前 3 次（触发阈值）通道故障，之后恢复
    return n <= 3 ? probeResult(-1, LatencyFailKind.CORE_NOT_READY, 0) : probeResult(77);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(12), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  ok(ConnectionOrchestrator.recoverCalls === 1, 'must attempt recovery once');
  ok(p.measured > 0, `should recover and measure (measured=${p.measured})`);
  eq(p.coreUnavailable, false, 'must not be flagged unavailable after successful recovery');
});

// ── 7. 取消：不产生任何节点结论，且不留下 TESTING ─────────────────────────
// 真实语义（由本套件首次真跑确认）：abort 之后引擎**不落任何记录** —— 因为
// start() 抢占旧批次用的是同一个 cancel()，旧 worker 若写记录会盖掉新批次的
// TESTING 标记。所以被打断的节点最终是「未测 `--`」（由 clearOwnTestingMarks
// 收回），progress.cancelled 只作计数。
await checkAsync('取消：不产生节点结论、不留 TESTING，被打断的记为未测', async () => {
  fresh();
  ClashApiService.handler = async () => {
    await sleep(40);
    return probeResult(100);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(40), URL_, opts());
  const started = run.run();
  for (let i = 0; i < 300 && ClashApiService._inflight === 0; i++) await sleep(2);
  ok(ClashApiService._inflight > 0, 'test needs at least one probe in flight');
  LatencyEngine.cancelCurrent();
  const p = await started;
  LatencyEngine.release(run);

  ok(p.finished < 40, `cancel must stop the batch (finished=${p.finished})`);
  let testing = 0;
  let failedCount = 0;
  let timeoutCount = 0;
  let untested = 0;
  for (let i = 0; i < 40; i++) {
    const st = LatencyController.stateFor('node-' + i);
    if (st === LatencyState.TESTING) testing++;
    if (st === LatencyState.FAILED) failedCount++;
    if (st === LatencyState.TIMEOUT) timeoutCount++;
    if (st === LatencyState.UNTESTED) untested++;
  }
  eq(testing, 0, 'no node may be left TESTING after cancel (the forever-spinner bug)');
  eq(failedCount, 0, 'cancel must never produce node failures');
  eq(timeoutCount, 0, 'cancel must never produce timeouts');
  ok(untested > 0, `interrupted nodes must read as untested "--" (got ${untested})`);
  ok(p.cancelled > 0, `interrupted probes must be counted (got ${p.cancelled})`);
  ok(ClashApiService.cancelled > 0, 'cancelInflight must be called to free http handles');
  eq(p.coreUnavailable, false,
    'cancel must not be misreported as "core unavailable" (CORE_NOT_READY under the hood)');
});

// ── 8. 单航班 / 抢占 ──────────────────────────────────────────────────────
await checkAsync('新批次抢占旧批次：旧批次作废且不留 TESTING', async () => {
  fresh();
  ClashApiService.handler = async () => {
    await sleep(40);
    return probeResult(100);
  };
  const first = LatencyEngine.start(new ClashApiService(), nodes(30), URL_, opts());
  const p1 = first.run();
  await sleep(50);
  const second = LatencyEngine.start(new ClashApiService(), nodes(5), URL_, opts());
  const p2 = await second.run();
  const r1 = await p1;
  LatencyEngine.release(second);
  eq(p2.measured, 5, 'second batch completes');
  ok(r1.finished < 30, 'first batch must be aborted by preemption');
  let testing = 0;
  for (let i = 0; i < 30; i++) {
    if (LatencyController.stateFor('node-' + i) === LatencyState.TESTING) testing++;
  }
  eq(testing, 0, 'preemption must not leave TESTING behind');
});

// ── 9. force=false 只补缺失/过期 ──────────────────────────────────────────
await checkAsync('force=false：新鲜结果跳过，过期结果重测', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(55);
  // 先测一批
  const r0 = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts({ force: true }));
  await r0.run();
  LatencyEngine.release(r0);
  eq(ClashApiService.calls.length, 4, 'initial probe count');

  // 再以 force=false 跑一次：应全部跳过
  const r1 = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts({ force: false }));
  const p1 = await r1.run();
  LatencyEngine.release(r1);
  eq(p1.skipped, 4, 'fresh results skipped');
  eq(ClashApiService.calls.length, 4, 'no extra probes for fresh results');

  // 把其中两个标记为过期 -> 只有它们重测
  const old = Date.now() - 11 * 60 * 1000;
  LatencyController.setRecord({
    name: 'node-1', state: LatencyState.MEASURED, delayMs: 55,
    atMs: old, channel: LatencyChannel.CORE,
    measured: () => true, failed: () => false, untested: () => false, hasValue: () => true,
    isFailure: () => false,
  });
  LatencyController.setRecord({
    name: 'node-2', state: LatencyState.MEASURED, delayMs: 55,
    atMs: old, channel: LatencyChannel.CORE,
    measured: () => true, failed: () => false, untested: () => false, hasValue: () => true,
    isFailure: () => false,
  });
  const r2 = LatencyEngine.start(new ClashApiService(), nodes(4), URL_, opts({ force: false }));
  const p2 = await r2.run();
  LatencyEngine.release(r2);
  eq(p2.skipped, 2, 'only the fresh two skipped');
  eq(ClashApiService.calls.length, 6, 'the two stale nodes re-probed');
});

// ── 10. 离线通道：api=null ────────────────────────────────────────────────
// 注意：progress.measured 统计"测出了值"的节点（离线值也算，否则顶栏
// 60/106 会与列表里 88 个数字对不上）；OFFLINE 状态本身才是"不是代理延迟"
// 的判据，不参与排序结论。断言要按这个真实语义写。
await checkAsync('无内核时走离线通道：标 OFFLINE（≈ms），不是失败也不是代理结论', async () => {
  fresh();
  DirectLatencyTester.handler = async () => 25;
  const run = LatencyEngine.start(null, nodes(5), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.channel, LatencyChannel.OFFLINE, 'channel must be labelled offline');
  for (let i = 0; i < 5; i++) {
    eq(LatencyController.stateFor('node-' + i), LatencyState.OFFLINE, `node-${i} offline`);
  }
  eq(p.failed, 0, 'offline is not a failure');
  eq(p.timeout, 0, 'offline is not a timeout');
  eq(ConnectionOrchestrator.recycles.length, 0, 'no core -> no recycle scheduled');
  // 离线值必须走 OFFLINE 状态，UI 才会加 ≈ 前缀
  ok(LatencyController.recordFor('node-0').channel === LatencyChannel.OFFLINE,
    'record channel must be OFFLINE so the UI shows ≈');
});

await checkAsync('离线探测返回 -2（不支持）：保持未测，不算失败', async () => {
  fresh();
  DirectLatencyTester.handler = async () => -2;
  const run = LatencyEngine.start(null, nodes(4), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.failed, 0, '-2 must not be a failure');
  eq(p.skipped, 4, 'unsupported offline probes are skipped');
  for (let i = 0; i < 4; i++) {
    ok(LatencyController.stateFor('node-' + i) !== LatencyState.FAILED,
      `node-${i} must not be marked failed`);
  }
});

// ── 11. 离线通道跳过环回/内网地址 ─────────────────────────────────────────
await checkAsync('离线通道跳过环回/内网地址（≈2ms 毫无意义）', async () => {
  fresh();
  DirectLatencyTester.handler = async () => 2;
  const list = [
    new ProxyNode('local-127', '127.0.0.1'),
    new ProxyNode('local-10', '10.0.0.5'),
    new ProxyNode('local-192', '192.168.1.9'),
    new ProxyNode('local-172', '172.20.3.4'),
    new ProxyNode('public', '8.8.8.8'),
  ];
  const run = LatencyEngine.start(null, list, URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  for (const n of ['local-127', 'local-10', 'local-192', 'local-172']) {
    ok(LatencyController.stateFor(n) !== LatencyState.OFFLINE,
      `${n} must not get a meaningless ≈2ms reading`);
  }
  eq(LatencyController.stateFor('public'), LatencyState.OFFLINE, 'public server still probed');
  eq(p.skipped, 4, 'loopback/private skipped');
});

// ── 12. 内核通道结束后挂回收（且只在有内核时） ────────────────────────────
await checkAsync('内核通道批次结束后挂一次宽限回收', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(30);
  const run = LatencyEngine.start(new ClashApiService(), nodes(3), URL_, opts());
  await run.run();
  LatencyEngine.release(run);
  eq(ConnectionOrchestrator.recycles.length, 1, 'exactly one recycle scheduled');
  ok(ConnectionOrchestrator.recycles[0] >= 30000,
    `recycle grace should be generous (got ${ConnectionOrchestrator.recycles[0]}ms)`);
});

// ── 13. worker 抛异常也必须收尾 ───────────────────────────────────────────
// 覆盖"客户端 api 直接 reject"（传输层抛错，而不是返回 failKind）。单个节点抛异常
// 必须就地收敛：不能带走整批（否则其余 lane 变孤儿，批次宣布结束后还在落库）。
await checkAsync('探测直接抛异常：只影响该节点，整批照常跑完', async () => {
  fresh();
  ClashApiService.handler = async (name) => {
    if (name === 'node-1') throw new Error('boom');
    return probeResult(20);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(5), URL_, opts());
  let threw = false;
  let p = null;
  try {
    p = await run.run();
  } catch (e) {
    threw = true;
  }
  LatencyEngine.release(run);
  eq(threw, false, 'a single throwing probe must not reject the whole batch');
  let testing = 0;
  for (let i = 0; i < 5; i++) {
    if (LatencyController.stateFor('node-' + i) === LatencyState.TESTING) testing++;
  }
  eq(testing, 0, 'a throwing probe must not leave TESTING behind');
  const st1 = LatencyController.stateFor('node-1');
  ok(st1 !== LatencyState.FAILED,
    `a thrown transport error must not become a node FAILED verdict (got ${st1})`);
  eq(st1, LatencyState.UNTESTED, 'the throwing node stays untested');
  eq(p.measured, 4, 'the other four nodes still get measured');
  eq(p.finished, 5, 'progress must still reach total (otherwise the bar hangs)');
});

// ── 14. 进度确定性 ────────────────────────────────────────────────────────
await checkAsync('进度确定性：finished 单调不减且最终等于 total', async () => {
  fresh();
  const seen = [];
  ClashApiService.handler = async () => {
    await sleep(5);
    return probeResult(10);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(25), URL_,
    opts({ onProgress: (p) => seen.push(p.finished) }));
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.finished, 25, 'finished == total at end');
  eq(p.total, 25, 'total');
  for (let i = 1; i < seen.length; i++) {
    ok(seen[i] >= seen[i - 1], `progress must be monotonic (${seen[i - 1]} -> ${seen[i]})`);
  }
  ok(seen.length > 1, 'progress must actually be reported');
  eq(p.running, false, 'running must be false when settled');
});

// ── 15. 硬截止：剩余保持未测而不是失败 ────────────────────────────────────
// 确定性做法：单次探测耗时 × 节点数 / 并发 必然超过整批截止，从而必然触达 deadline。
// 用 (BATCH_DEADLINE_MS * 并发 / 节点数) 量级的单次耗时，保证剩余节点跑不完。
await checkAsync('硬截止后剩余节点保持未测（绝不写成失败）', async () => {
  fresh();
  const total = 60;
  // 每个探测 ~ (deadline / (total/concurrency) ) * 2 → 必然用时超过 deadline
  const perProbeMs = Math.ceil((BATCH_DEADLINE_MS * LATENCY_CONCURRENCY / total) * 2);
  ClashApiService.handler = async () => {
    await sleep(perProbeMs);
    return probeResult(10);
  };
  const run = LatencyEngine.start(new ClashApiService(), nodes(total), URL_, opts());
  const p = await run.run();
  LatencyEngine.release(run);
  eq(p.failed, 0, 'deadline must not produce failures');
  eq(p.timeout, 0, 'deadline must not produce timeouts');
  let testing = 0;
  for (let i = 0; i < total; i++) {
    if (LatencyController.stateFor('node-' + i) === LatencyState.TESTING) testing++;
  }
  eq(testing, 0, 'deadline must not leave TESTING');
  ok(p.measured < total,
    `deadline should leave nodes untested (measured=${p.measured}/${total}, perProbe=${perProbeMs}ms)`);
  // 剩余节点既不是失败也不是超时 —— 就是"没测"
  eq(p.finished, p.measured, 'finished counts only the ones that actually settled');
});

// ── 16. release 语义 ──────────────────────────────────────────────────────
await checkAsync('release 之后引擎不再认为自己在跑', async () => {
  fresh();
  ClashApiService.handler = async () => probeResult(10);
  const run = LatencyEngine.start(new ClashApiService(), nodes(2), URL_, opts());
  ok(LatencyEngine.isRunning(), 'running while batch in flight');
  await run.run();
  ok(!LatencyEngine.isRunning(), 'settled batch is not running');
  LatencyEngine.release(run);
  ok(!LatencyEngine.isRunning(), 'released engine is not running');
  ok(LatencyEngine.currentProgress() === null || LatencyEngine.currentProgress() !== null,
    'currentProgress must not throw after release');
});

fs.rmSync(stage, { recursive: true, force: true });
console.log(`\nLatency engine verification: ${passed} passed, ${failed} failed (EXEC real engine; stubbed deps).`);
if (failures.length > 0) {
  console.log('Failures:');
  for (const f of failures) console.log(`  - ${f}`);
}
if (failed > 0) process.exitCode = 1;
