'use strict';

/**
 * 延迟测速管线回归（组测 / 单测统一语义）。
 *
 * 覆盖：
 *  1. 节点名编码（中文、空格、#、%、/）
 *  2. mihomo delay 响应解析口径（200 + delay / 204 / 空体 / 错误 JSON）
 *  3. 失败分类：核心未就绪 / 切换节点失败 / 网络不可达 / 真正超时（镜像 ClashApiService）
 *  4. 每个 fallback URL 的**独立**预算（禁止把单节点总预算按剩余尝试次数切碎）
 *  5. 单节点硬上限（长尾保护）与批次级 URL 记忆（带 generation 作废）
 *  6. 有界并发 + Promise.all 兵底（settled 看门狗）
 *  7. 核心未就绪 → 中止整批、不落盘、可重新测速
 *  8. 排序快照语义：非节点判定（核心未就绪 / 仅端口可达）不得覆盖旧结论
 *  9. 源码接线断言（组测与单测共用同一函数、同一套超时语义）
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');

const root = path.resolve(__dirname, '..');
const pagePath = path.join(root, 'entry/src/main/ets/pages/NodeSelectionPage.ets');
const apiPath = path.join(root, 'entry/src/main/ets/commons/services/ClashApiService.ets');
const orchPath = path.join(root, 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets');
const sortPath = path.join(root, 'entry/src/main/ets/commons/services/NodeSortPersistence.ets');
const page = fs.readFileSync(pagePath, 'utf8');
const api = fs.readFileSync(apiPath, 'utf8');
const orch = fs.readFileSync(orchPath, 'utf8');
const sortSrc = fs.readFileSync(sortPath, 'utf8');

/**
 * 剥离注释后只保留可执行代码，用于「旧逻辑必须消失」的负向断言。
 *
 * 为什么必须这样做：负向断言过去写作 !page.includes('<旧代码字面量>')，
 * 而新实现旁边的**说明性注释**里往往会原样引用被删掉的旧代码
 * （例如 NodeSelectionPage.ets 里写着「不再 Math.floor(remaining / attemptsLeft) 切碎预算」），
 * 于是断言实际上在检查注释文字，出现"实现已改对、测试却红"的假失败。
 * 因此负向断言统一作用于 codeOnly(source)：
 *   - 注释里提及旧实现 → 不算违规（这正是我们要允许的写作方式）；
 *   - 代码里残留旧实现 → 仍然会被抓到。
 */
function codeOnly(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, '')          // 块注释 /* ... */
    .replace(/(^|[^:])\/\/[^\r\n]*/g, '$1');   // 行注释 // ...（[^:] 保护 http:// 等字符串）
}

const pageCode = codeOnly(page);

/** 与 ClashApiService.LatencyFailKind 同值 */
const FAIL = {
  NONE: '',
  CORE: 'core_not_ready',
  SWITCH: 'switch_failed',
  NET: 'network_unreachable',
  TIMEOUT: 'timeout',
  UNSUPPORTED: 'unsupported',
  PORT: 'port_reachable_only'
};

const BATCH_NODE_TIMEOUT_MS = 4000;
const SINGLE_NODE_TIMEOUT_MS = 5000;
const URL_DEMOTE_AFTER_FAILURES = 3;
const CORE_NOT_READY_ABORT_STREAK = 3;

function delay(ms, value, reject) {
  return new Promise((resolve, rejectFn) => setTimeout(() => reject ? rejectFn(value) : resolve(value), ms));
}

function parseMihomo(response) {
  if (!response || response.code !== 200 || typeof response.body !== 'string' || response.body.length === 0) return -1;
  try {
    const parsed = JSON.parse(response.body);
    return Number.isFinite(parsed.delay) && parsed.delay >= 0 ? parsed.delay : -1;
  } catch (_) {
    return -1;
  }
}

/** 镜像 ClashApiService.classifyStatusCode */
function classifyStatus(code) {
  if (code === 401 || code === 403) return FAIL.CORE;
  if (code === 404) return FAIL.SWITCH;
  if (code === 408 || code === 504) return FAIL.TIMEOUT;
  return FAIL.NET;
}

/** 镜像 ClashApiService.classifyTransportError */
function classifyTransport(message) {
  const m = String(message).toLowerCase();
  if (m.includes('refused') || m.includes('econnrefused') || m.includes('not connected')) return FAIL.CORE;
  if (m.includes('broken pipe') || m.includes('epipe') || m.includes('failed to connect')) return FAIL.CORE;
  if (m.includes('timeout') || m.includes('timed out')) return FAIL.TIMEOUT;
  return FAIL.NET;
}

/** 镜像新 testNodeDelay：每个 URL 独立预算 + 批次级 URL 记忆 */
function makeUrlMemory() {
  return { generation: -1, streak: new Map() };
}

function memoryFor(memory, generation) {
  if (memory.generation !== generation) {
    memory.generation = generation;
    memory.streak = new Map();
  }
  return memory.streak;
}

async function testNodeDelayMirror(nodeName, urls, perUrlBudgetMs, memory, generation, request) {
  const attempt = { delayMs: -1, failKind: FAIL.NONE, httpCode: 0 };
  const streak = memoryFor(memory, generation);
  let candidates = urls.filter((url) => (streak.get(url) || 0) < URL_DEMOTE_AFTER_FAILURES);
  if (candidates.length === 0) candidates = urls.slice();
  for (const url of candidates) {
    // 每个 URL 独立预算：budget 就是 perUrlBudgetMs，不按剩余尝试次数切分
    const probe = await request(url, perUrlBudgetMs);
    attempt.httpCode = probe.code;
    if (probe.delayMs >= 0) {
      streak.set(url, 0);
      attempt.delayMs = probe.delayMs;
      attempt.failKind = FAIL.NONE;
      return attempt;
    }
    attempt.delayMs = -1;
    attempt.failKind = probe.failKind || FAIL.NET;
    if (attempt.failKind === FAIL.CORE || attempt.failKind === FAIL.SWITCH) return attempt;
    streak.set(url, (streak.get(url) || 0) + 1);
  }
  return attempt;
}

/** 镜像 probeNodeBounded：单节点硬上限 */
function probeNodeBoundedMirror(timeoutMs, urlCount, probe) {
  const hardCapMs = timeoutMs * Math.max(1, urlCount) + 1000;
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolve({ delayMs: -1, failKind: FAIL.TIMEOUT, guarded: true });
    }, hardCapMs);
    const settle = (outcome) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(outcome);
    };
    probe().then(settle, () => settle({ delayMs: -1, failKind: FAIL.NET }));
  });
}

/** 镜像 settleOne：Promise.all 兵底 */
function settleOneMirror(worker, capMs) {
  return new Promise((resolve) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      resolve();
    }, capMs);
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    worker.then(finish, finish);
  });
}

async function runLimited(items, lanes, generation, getGeneration, worker) {
  let cursor = 0;
  const writes = [];
  const jobs = Array.from({ length: Math.min(lanes, items.length) }, async () => {
    for (;;) {
      if (generation !== getGeneration()) return;
      const index = cursor++;
      if (index >= items.length) return;
      const result = await worker(items[index], index);
      if (generation !== getGeneration()) return;
      writes.push([index, result]);
    }
  });
  await Promise.all(jobs);
  return writes;
}

function applyLatencyResultMirror(attempt, rec) {
  rec.failKind = attempt.failKind;
  if (attempt.failKind === FAIL.UNSUPPORTED) {
    rec.latency = -2;
    return rec;
  }
  if (attempt.failKind === FAIL.CORE) {
    rec.latency = -2;
    return rec;
  }
  if (attempt.channel === 'direct' && attempt.delayMs >= 0) {
    rec.latency = -2;
    rec.failKind = FAIL.PORT;
    return rec;
  }
  rec.latency = attempt.delayMs;
  return rec;
}

function summarizeMirror(collected) {
  const stats = { ok: 0, failed: 0, untested: 0, coreNotReady: 0, switchFailed: 0, network: 0, timeout: 0 };
  for (const rec of collected) {
    if (rec.latency === -2) stats.untested++;
    else if (rec.latency < 0) stats.failed++;
    else stats.ok++;
    if (rec.failKind === FAIL.CORE) stats.coreNotReady++;
    else if (rec.failKind === FAIL.SWITCH) stats.switchFailed++;
    else if (rec.failKind === FAIL.NET) stats.network++;
    else if (rec.failKind === FAIL.TIMEOUT) stats.timeout++;
  }
  stats.verdicts = () => stats.ok + stats.failed;
  return stats;
}

function isNonVerdict(kind) {
  return kind === FAIL.CORE || kind === FAIL.PORT;
}

/** 镜像 NodeSortSnapshot.buildAuto（含非节点判定沿用旧结论 + keepNames 合并） */
function buildAutoMirror(results, previous, keepNames) {
  const merged = [];
  const covered = new Set();
  for (const r of results) {
    covered.add(r.name);
    const rec = { name: r.name, failKind: r.failKind };
    if (isNonVerdict(r.failKind)) {
      const carried = previous ? previous.find((p) => p.name === r.name) : undefined;
      if (carried) {
        rec.latency = carried.latency;
        rec.failCount = carried.failCount;
        rec.lastOk = carried.lastOk;
        rec.failKind = carried.failKind;
      } else {
        rec.latency = -2;
        rec.lastOk = false;
        rec.failCount = 0;
      }
      merged.push(rec);
      continue;
    }
    rec.latency = r.latency;
    rec.lastOk = r.latency >= 0;
    if (rec.lastOk) {
      rec.failCount = 0;
    } else {
      const prev = previous ? previous.find((p) => p.name === r.name) : undefined;
      rec.failCount = (prev ? prev.failCount : 0) + 1;
    }
    merged.push(rec);
  }
  if (previous && keepNames) {
    const keep = new Set(keepNames);
    for (const prevRec of previous) {
      if (covered.has(prevRec.name) || !keep.has(prevRec.name)) continue;
      merged.push(prevRec);
    }
  }
  return merged;
}

async function main() {
  // ---- 1. 节点名编码 ----
  const names = ['中文 节点', 'space node', 'hash#node', 'percent%node', 'slash/node'];
  for (const name of names) {
    const encoded = encodeURIComponent(name);
    assert.strictEqual(decodeURIComponent(encoded), name);
    assert(!encoded.includes('#'));
    assert(!encoded.includes('/'));
  }
  assert(api.includes('/proxies/${encodeURIComponent(nodeName)}/delay'));
  assert.strictEqual((api.match(/encodeURIComponent\(nodeName\)/g) || []).length, 1);

  // ---- 2. mihomo 响应解析 ----
  assert.strictEqual(parseMihomo({ code: 200, body: '{"delay":42}' }), 42);
  assert.strictEqual(parseMihomo({ code: 200, body: '{"delay":380}' }), 380);
  assert.strictEqual(parseMihomo({ code: 204, body: '' }), -1);
  assert.strictEqual(parseMihomo({ code: 200, body: '' }), -1);
  assert.strictEqual(parseMihomo({ code: 200, body: '{"error":"timeout"}' }), -1);

  // ---- 3. 失败分类 ----
  assert.strictEqual(classifyStatus(401), FAIL.CORE);
  assert.strictEqual(classifyStatus(403), FAIL.CORE);
  assert.strictEqual(classifyStatus(404), FAIL.SWITCH);
  assert.strictEqual(classifyStatus(504), FAIL.TIMEOUT);
  assert.strictEqual(classifyStatus(408), FAIL.TIMEOUT);
  assert.strictEqual(classifyStatus(400), FAIL.NET);
  assert.strictEqual(classifyStatus(502), FAIL.NET);
  assert.strictEqual(classifyTransport('Failed to connect to /127.0.0.1:9090'), FAIL.CORE);
  assert.strictEqual(classifyTransport('connect ECONNREFUSED 127.0.0.1:9090'), FAIL.CORE);
  assert.strictEqual(classifyTransport('request timeout'), FAIL.TIMEOUT);
  assert.strictEqual(classifyTransport('dial tcp: i/o error'), FAIL.NET);
  // 四类必须互不相同，否则 UI/日志无法区分
  assert.strictEqual(new Set([FAIL.CORE, FAIL.SWITCH, FAIL.NET, FAIL.TIMEOUT]).size, 4);

  // ---- 4. 每个 fallback URL 独立预算 ----
  const urls = ['primary', 'https://cp.cloudflare.com/generate_204', 'https://www.gstatic.com/generate_204'];

  // a) 主 URL 失败后，备用 URL 拿到的仍是完整预算（旧实现只剩 floor(remaining/2)）
  let budgets = [];
  let memory = makeUrlMemory();
  let attempt = await testNodeDelayMirror('n1', urls, BATCH_NODE_TIMEOUT_MS, memory, 1, async (url, budget) => {
    budgets.push({ url, budget });
    if (url === 'primary') return { delayMs: -1, failKind: FAIL.NET, code: 400 };
    return { delayMs: 61, failKind: FAIL.NONE, code: 200 };
  });
  assert.strictEqual(attempt.delayMs, 61);
  assert.deepStrictEqual(budgets.map((b) => b.url), ['primary', 'https://cp.cloudflare.com/generate_204']);
  for (const b of budgets) {
    assert.strictEqual(b.budget, BATCH_NODE_TIMEOUT_MS, '每个 URL 必须拿到独立完整预算');
  }

  // b) 慢成功：主 URL 在 1500ms 后成功（旧实现组测只有 250~750ms 预算 → 假超时）
  budgets = [];
  memory = makeUrlMemory();
  attempt = await testNodeDelayMirror('n2', urls, BATCH_NODE_TIMEOUT_MS, memory, 1, async (url, budget) => {
    budgets.push(budget);
    return delay(Math.min(600, budget), { delayMs: 820, failKind: FAIL.NONE, code: 200 });
  });
  assert.strictEqual(attempt.delayMs, 820);
  assert.strictEqual(budgets.length, 1);

  // c) 核心未就绪 / 节点缺失时不再浪费其它 URL
  let calls = 0;
  memory = makeUrlMemory();
  attempt = await testNodeDelayMirror('n3', urls, BATCH_NODE_TIMEOUT_MS, memory, 1, async () => {
    calls++;
    return { delayMs: -1, failKind: FAIL.CORE, code: 401 };
  });
  assert.strictEqual(attempt.failKind, FAIL.CORE);
  assert.strictEqual(calls, 1);
  calls = 0;
  memory = makeUrlMemory();
  attempt = await testNodeDelayMirror('n4', urls, BATCH_NODE_TIMEOUT_MS, memory, 1, async () => {
    calls++;
    return { delayMs: -1, failKind: FAIL.SWITCH, code: 404 };
  });
  assert.strictEqual(attempt.failKind, FAIL.SWITCH);
  assert.strictEqual(calls, 1);

  // d) 批次级 URL 记忆（带 generation）：连续失败后跳过该 URL，换批次立即恢复
  memory = makeUrlMemory();
  const tried = [];
  const requesting = async (url, budget) => {
    tried.push({ gen: memory.generation, url });
    if (url === 'primary') return { delayMs: -1, failKind: FAIL.TIMEOUT, code: 504 };
    return { delayMs: 90, failKind: FAIL.NONE, code: 200 };
  };
  for (let i = 0; i < 4; i++) {
    await testNodeDelayMirror('n5', urls, BATCH_NODE_TIMEOUT_MS, memory, 7, requesting);
  }
  const primaryHitsGen7 = tried.filter((t) => t.gen === 7 && t.url === 'primary').length;
  assert.strictEqual(primaryHitsGen7, URL_DEMOTE_AFTER_FAILURES, '同批次内第 4 个节点应跳过已降级 URL');
  tried.length = 0;
  await testNodeDelayMirror('n6', urls, BATCH_NODE_TIMEOUT_MS, memory, 8, requesting);
  assert(tried.some((t) => t.gen === 8 && t.url === 'primary'), '新 generation 必须作废旧 URL 记忆');

  // ---- 5. 单节点硬上限（长尾保护） ----
  const hangStarted = Date.now();
  const bounded = await probeNodeBoundedMirror(400, 3, () => new Promise(() => {}));
  const hangElapsed = Date.now() - hangStarted;
  assert.strictEqual(bounded.failKind, FAIL.TIMEOUT);
  assert.strictEqual(bounded.delayMs, -1);
  assert(hangElapsed < 400 * 3 + 1000 + 600, `硬上限未生效: ${hangElapsed}ms`);

  // ---- 6. 有界并发 + Promise.all 兵底 ----
  let active = 0;
  let peak = 0;
  let generation = 1;
  const writes = await runLimited(Array.from({ length: 24 }, (_, i) => i), 8, generation, () => generation, async (item) => {
    active++;
    peak = Math.max(peak, active);
    const result = await delay(5 + (item % 3), item);
    active--;
    return result;
  });
  assert.strictEqual(writes.length, 24);
  assert(peak <= 8, `并发上限被突破: ${peak}`);

  generation = 2;
  const latePromise = runLimited([1, 2, 3], 2, generation, () => generation, async (item) => delay(50, item));
  setTimeout(() => { generation = 3; }, 5);
  const lateWrites = await latePromise;
  assert.strictEqual(lateWrites.length, 0);

  const guardStarted = Date.now();
  await Promise.all([settleOneMirror(new Promise(() => {}), 120), settleOneMirror(delay(10), 120)]);
  assert(Date.now() - guardStarted < 600, 'Promise.all 兵底未生效：整批被长尾拖住');

  // ---- 7. 核心不可用 → 中止整批且不落盘 ----
  const collected = [];
  for (const name of ['a', 'b', 'c', 'd', 'e']) {
    collected.push({ name, latency: -2, failKind: FAIL.NONE });
  }
  let coreNotReadyStreak = 0;
  let batchAbortKind = '';
  let batchTesting = true;
  let cursor = 0;
  const list = ['a', 'b', 'c', 'd', 'e'];
  while (batchTesting && cursor < list.length) {
    const attemptCore = { delayMs: -1, failKind: FAIL.CORE, httpCode: 401 };
    if (attemptCore.failKind === FAIL.CORE) {
      coreNotReadyStreak++;
      if (coreNotReadyStreak >= CORE_NOT_READY_ABORT_STREAK && batchAbortKind.length === 0) {
        batchAbortKind = FAIL.CORE;
        batchTesting = false;
      }
    } else {
      coreNotReadyStreak = 0;
    }
    applyLatencyResultMirror(attemptCore, collected[cursor]);
    cursor++;
  }
  assert.strictEqual(batchAbortKind, FAIL.CORE);
  assert.strictEqual(cursor, CORE_NOT_READY_ABORT_STREAK, '核心不可用时应在阈值处中止，而非跑完整批');
  const coreStats = summarizeMirror(collected);
  assert.strictEqual(coreStats.coreNotReady, CORE_NOT_READY_ABORT_STREAK);
  assert.strictEqual(coreStats.verdicts(), 0, '核心不可用不得产生节点判定');
  assert.strictEqual(coreStats.ok, 0);
  assert.strictEqual(coreStats.failed, 0, '核心不可用不得被写成「超时失败」并落盘');
  // 页面在 verdicts()===0 时直接返回、不持久化
  assert(page.includes('if (stats.verdicts() === 0) {'));
  assert(page.includes("promptAction.showToast({ message: '未取得有效测速结果，已保留原有排序' });"));

  // 直连降级（仅端口可达）同样不算节点判定
  const directRec = { latency: -2, failKind: FAIL.NONE };
  applyLatencyResultMirror({ delayMs: 33, failKind: FAIL.PORT, channel: 'direct' }, directRec);
  assert.strictEqual(directRec.latency, -2, '端口可达不得写成代理延迟');
  assert.strictEqual(directRec.failKind, FAIL.PORT);
  const directStats = summarizeMirror([directRec]);
  assert.strictEqual(directStats.verdicts(), 0);

  // ---- 8. 排序快照语义 ----
  const previous = [
    { name: 'a', latency: 120, failCount: 0, lastOk: true, failKind: '' },
    { name: 'b', latency: -1, failCount: 2, lastOk: false, failKind: FAIL.TIMEOUT },
    { name: 'z', latency: 45, failCount: 0, lastOk: true, failKind: '' }
  ];
  const results = [
    { name: 'a', latency: -1, failKind: FAIL.CORE },       // 核心不可用 → 沿用旧成功结论
    { name: 'b', latency: -1, failKind: FAIL.TIMEOUT },    // 真实超时 → 失败次数 +1
    { name: 'c', latency: 88, failKind: FAIL.NONE }        // 真实成功
  ];
  const sorted = buildAutoMirror(results, previous, ['a', 'b', 'c', 'z']);
  const byName = new Map(sorted.map((r) => [r.name, r]));
  assert.strictEqual(byName.get('a').latency, 120, '核心不可用不得覆盖旧的成功延迟');
  assert.strictEqual(byName.get('a').lastOk, true);
  assert.strictEqual(byName.get('b').latency, -1);
  assert.strictEqual(byName.get('b').failCount, 3);
  assert.strictEqual(byName.get('c').latency, 88);
  assert.strictEqual(byName.get('z').latency, 45, '本次未测节点必须沿用旧结论（快照不被截断）');
  assert.strictEqual(sorted.length, 4);
  // 首次出现且是核心不可用 → 保持「未测」而不是超时
  const freshSorted = buildAutoMirror([{ name: 'd', latency: -1, failKind: FAIL.CORE }], null, null);
  assert.strictEqual(freshSorted[0].latency, -2);
  assert.strictEqual(freshSorted[0].lastOk, false);
  // keepNames 为 null 时保持旧的「整体覆盖」语义
  const legacySorted = buildAutoMirror(results, previous, null);
  assert.strictEqual(legacySorted.length, 3);

  // ---- 9. 源码接线断言 ----
  assert(page.includes('const BATCH_LANES = 8'));
  assert(page.includes('const BATCH_NODE_TIMEOUT_MS = 4000;'), '组测预算必须 ≥4000ms 且与单测同量级');
  assert(page.includes('const SINGLE_NODE_TIMEOUT_MS = 5000;'));
  assert(page.includes('const URL_DEMOTE_AFTER_FAILURES = 3;'));
  assert(page.includes('const CORE_NOT_READY_ABORT_STREAK = 3;'));
  assert(page.includes('const NODE_PROBE_GUARD_SLACK_MS = 1000;'));
  // 负向断言只看剥离注释后的代码：注释里复述旧实现是合法的写作方式，
  // 不能被当成「旧逻辑残留」（详见文件头 codeOnly 的说明）。
  assert(!/Math\.floor\(\s*remaining\s*\/\s*attemptsLeft\s*\)/.test(pageCode),
    '预算切分逻辑必须从代码中移除（注释提及不算）');
  assert(!/deadline\s*=\s*Date\.now\(\)\s*\+\s*timeoutMs/.test(pageCode),
    '单节点总预算切分必须移除');
  // 正向语义：每个 fallback URL 都拿完整 timeoutMs，总预算靠 hardCap 兜底，
  // 而不是把 timeoutMs 按剩余尝试次数切碎后逐次递减。
  assert(/testLatencyDetailed\(node\.name,\s*candidates\[index\],\s*timeoutMs\)/.test(pageCode),
    '每个 fallback URL 必须使用完整且独立的 timeoutMs 预算');
  // 断言能力自检：保证 codeOnly 真的会剥离注释、也真的会保留代码，
  // 避免以后有人把负向断言改成「永远通过」的空壳。
  assert(!/Math\.floor\(\s*remaining\s*\/\s*attemptsLeft\s*\)/.test(
    codeOnly('// 旧实现：Math.floor(remaining / attemptsLeft)')), 'codeOnly 必须剥离注释行');
  assert(/Math\.floor\(\s*remaining\s*\/\s*attemptsLeft\s*\)/.test(
    codeOnly('const budget = Math.floor(remaining / attemptsLeft);')), 'codeOnly 必须保留真实代码');
  assert(page.includes('const hardCapMs = timeoutMs * Math.max(1, this.buildLatencyUrls().length)'));
  assert(page.includes('await this.settleWorkers(workers, this.batchGuardMs(list.length, lanes))'));
  assert(!page.includes('await Promise.all(workers)'));
  assert(page.includes('private async testNodeDelay(node: ProxyNode, timeoutMs: number,'));
  assert.strictEqual((page.match(/private async testNodeDelay/g) || []).length, 1,
    '组测与单测必须共用同一个测速函数');
  assert.strictEqual((page.match(/testNodeDelay\(node, (SINGLE|BATCH)_NODE_TIMEOUT_MS/g) || []).length, 0);
  assert(page.includes('await this.probeNodeBounded(node, SINGLE_NODE_TIMEOUT_MS, generation)'));
  assert(page.includes('await this.probeNodeBounded(list[i], BATCH_NODE_TIMEOUT_MS, generation)'));
  assert(page.includes('await this.orchestrator.api.testLatencyDetailed('));
  assert(page.includes('attempt.failKind = LatencyFailKind.NETWORK_UNREACHABLE;'));
  // TIMEOUT 分类的归属变了：由 ClashApiService 依据 HTTP 码 / 传输错误判定（408/504/timeout），
  // testNodeDelay 只做**透传**，页面自身仅在「单节点硬上限丢弃长尾」时标 TIMEOUT。
  // 旧断言写死页面里必须出现 'attempt.failKind = LatencyFailKind.TIMEOUT;'，
  // 那是「分类逻辑留在页面里、一律写成超时」的旧实现，已过时。
  assert(api.includes('return LatencyFailKind.TIMEOUT;'), '超时分类必须由 ClashApiService 判定');
  assert(page.includes('attempt.failKind = probe.failKind.length > 0 ? probe.failKind : LatencyFailKind.NETWORK_UNREACHABLE;'),
    'testNodeDelay 必须透传底层失败分类，而不是把失败一律写成超时');
  assert(page.includes('aborted.failKind = LatencyFailKind.TIMEOUT;'), '硬上限丢弃长尾必须标为 timeout');
  assert(page.includes('if (attempt.failKind === LatencyFailKind.CORE_NOT_READY) {'));
  assert(page.includes('LatencyController.set(node.name, -2)'));
  assert(page.includes("this.directReachableNames.has(row.node.name) ? '端口可达'"), '端口可达约定必须保留');
  assert(page.includes('this.batchGen !== generation'));
  assert(page.includes('coreNotReady=${stats.coreNotReady}'));
  assert(page.includes('switchFailed=${stats.switchFailed}'));
  // 排序快照语义
  assert(page.includes('this.sortSnapshot = NodeSortSnapshot.buildAuto(Date.now(), collected, this.sortSnapshot, allNames)'));
  assert(sortSrc.includes('static isNonVerdict(failKind: string): boolean'));
  assert(sortSrc.includes("failKind: string = '';"));
  assert(sortSrc.includes('keepNames: string[] | null = null'));
  // API 分类
  assert(api.includes('export class LatencyFailKind'));
  assert(api.includes('async testLatencyDetailed('));
  assert(api.includes('classifyStatusCode'));
  assert(api.includes('if (resp.responseCode !== 200)'));
  assert(api.includes('if (body.length === 0)'));
  assert(api.includes('kind=${out.failKind}'));
  // 编排器接线（症状 2）
  assert(orch.includes('async ensureTestCore('), 'orchestrator must keep ensureTestCore');
  assert(page.includes('await this.orchestrator.ensureTestCore(this.subs, this.settings)'));

  console.log('PASS latency pipeline regression: special names, mihomo parsing, failure classes,'
    + ' independent per-URL budget, URL memory w/ generation, node hard cap, bounded concurrency,'
    + ' Promise.all guard, core-not-ready abort + no-persist, sort snapshot semantics, source wiring');
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
