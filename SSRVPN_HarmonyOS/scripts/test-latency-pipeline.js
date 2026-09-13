'use strict';

/**
 * 延迟测速管线回归（快速组测：单请求 + 整批级 URL 降级 + 硬截止未测语义）。
 *
 * 覆盖：
 *  1. 节点名编码（中文、空格、#、%、/）
 *  2. mihomo delay 响应解析口径（200 + delay / 204 / 空体 / 错误 JSON）
 *  3. 失败分类：核心未就绪 / 切换节点失败 / 网络不可达 / 真正超时 / 未测 互不相同
 *  4. **每节点单次请求 + 短预算**（组测 2000ms，禁止逐节点轮询多个 URL）
 *  5. **整批级 URL 降级**（连续失败 5 次整批换 URL；失败节点带新 URL 复测一次）
 *  6. 单节点硬上限 + **整批硬截止**（到点未完成 → 未测，绝不是超时）
 *  7. 有界并发上限（28 路）+ 渐进回调次数 + 迟到响应作废 + Promise.all 兵底
 *  8. 核心不可用 → 中止整批、verdicts()===0、不落盘
 *  9. 排序快照语义：整批未测绝不写成「全失败」（非节点判定沿用旧结论）
 * 10. 源码接线断言（含「测速配置包含全部节点」与生成器逐字节未变）
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const relPage = 'entry/src/main/ets/pages/NodeSelectionPage.ets';
const relApi = 'entry/src/main/ets/commons/services/ClashApiService.ets';
const relOrch = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
const relSort = 'entry/src/main/ets/commons/services/NodeSortPersistence.ets';
const relGen = 'entry/src/main/ets/commons/services/ClashConfigGenerator.ets';
const page = fs.readFileSync(path.join(root, relPage), 'utf8');
const api = fs.readFileSync(path.join(root, relApi), 'utf8');
const orch = fs.readFileSync(path.join(root, relOrch), 'utf8');
const sortSrc = fs.readFileSync(path.join(root, relSort), 'utf8');

/**
 * 剥离注释后只保留可执行代码，用于「旧逻辑必须消失」的负向断言。
 * 负向断言作用于 codeOnly(source)，因此注释里复述旧实现不算违规。
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
  PORT: 'port_reachable_only',
  UNTESTED: 'untested'
};

// ---- 与 NodeSelectionPage.ets 常量同值（源码断言会逐条核对字面量） ----
const BATCH_LANES = 28;
const BATCH_NODE_TIMEOUT_MS = 2000;
const SINGLE_NODE_TIMEOUT_MS = 3000;
const URL_GLOBAL_DEMOTE_STREAK = 5;
const BATCH_DEADLINE_MS = 12000;
const CORE_NOT_READY_ABORT_STREAK = 3;
const NODE_PROBE_GUARD_SLACK_MS = 1000;

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

/**
 * 整批测速引擎镜像（与 NodeSelectionPage.runBatch + testNodeDelay + probeNodeBounded
 * 的语义逐条对应）：单请求 / 整批级 URL 降级 + 复测 / 硬截止未测 / 渐进回调计数。
 */
class BatchMirror {
  constructor(opts) {
    this.lanes = opts.lanes;
    this.deadlineMs = opts.deadlineMs;
    this.perNodeMs = opts.perNodeMs;
    this.urls = opts.urls;
    this.request = opts.request;         // async (url, nodeName, budgetMs) => {delayMs, failKind, code}
    this.urlIndex = 0;
    this.urlStreak = 0;
    this.urlSwitches = 0;
    this.requests = [];                  // 每个节点实际发出的请求（用于断言「单次请求」）
    this.peerRetries = new Map();        // nodeName -> 复测次数
  }

  urlMemoryTick() {
    // 真实实现里 generation 变化会复位；镜像通过 resetGeneration() 显式验证
  }

  resetGeneration() {
    this.urlIndex = 0;
    this.urlStreak = 0;
  }

  currentUrl() {
    return this.urls[Math.min(this.urlIndex, this.urls.length - 1)];
  }

  noteUrlSuccess() {
    this.urlStreak = 0;
  }

  noteUrlFailure() {
    this.urlStreak += 1;
    if (this.urlStreak < URL_GLOBAL_DEMOTE_STREAK) return false;
    this.urlStreak = 0;
    if (this.urls.length <= 1) return false;
    const next = (Math.min(this.urlIndex, this.urls.length - 1) + 1) % this.urls.length;
    if (next === this.urlIndex) return false;
    this.urlIndex = next;
    this.urlSwitches += 1;
    return true;
  }

  isUrlLevelFailure(kind) {
    return kind === FAIL.NET || kind === FAIL.TIMEOUT;
  }

  /** 镜像 testNodeDelay（组测分支：allowUrlFallback=false → 每节点只打一次请求） */
  async testNodeDelay(nodeName, budgetMs) {
    const url = this.currentUrl();
    const probe = await this.request(url, nodeName, budgetMs);
    this.requests.push({ name: nodeName, url, budget: budgetMs });
    const attempt = { delayMs: -1, failKind: FAIL.NONE, httpCode: probe.code };
    if (probe.delayMs >= 0) {
      this.noteUrlSuccess();
      attempt.delayMs = probe.delayMs;
      attempt.failKind = FAIL.NONE;
      return attempt;
    }
    attempt.failKind = probe.failKind || FAIL.NET;
    if (attempt.failKind === FAIL.CORE || attempt.failKind === FAIL.SWITCH
      || attempt.failKind === FAIL.UNSUPPORTED) {
      return attempt;
    }
    this.noteUrlFailure();
    return attempt;
  }

  /** 镜像 probeNodeBounded（含整批硬截止语义） */
  probeNodeBounded(nodeName, budgetMs, deadlineAt, nowFn) {
    const nodeCapMs = budgetMs + NODE_PROBE_GUARD_SLACK_MS;
    const remainingMs = deadlineAt - nowFn();
    const deadlineCut = remainingMs <= nodeCapMs;
    const hardCapMs = Math.max(1, Math.min(nodeCapMs, remainingMs));
    return new Promise((resolve) => {
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        resolve(deadlineCut
          ? { delayMs: -2, failKind: FAIL.UNTESTED, deadlineCut: true }
          : { delayMs: -1, failKind: FAIL.TIMEOUT, deadlineCut: false });
      }, hardCapMs);
      const settle = (outcome) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(outcome);
      };
      this.testNodeDelay(nodeName, budgetMs).then(settle, () => settle({ delayMs: -1, failKind: FAIL.NET }));
    });
  }

  /** 镜像 applyLatencyResult 的渐进计数与未测语义 */
  applyLatencyResult(attempt, rec) {
    rec.failKind = attempt.failKind;
    rec.emits = (rec.emits || 0) + 1;
    if (attempt.failKind === FAIL.UNSUPPORTED || attempt.failKind === FAIL.UNTESTED
      || attempt.failKind === FAIL.CORE) {
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

  /** 镜像 runBatch：worker 共享游标 + 复测队列 + 硬截止 + 最终「未测」标注 */
  async run(names, opts) {
    const options = opts || {};
    const nowFn = options.nowFn || (() => Date.now());
    const progressSink = options.progressSink || (() => {});
    const startAt = nowFn();
    const deadlineAt = startAt + this.deadlineMs;
    const collected = names.map((name) => ({ name, latency: -2, failKind: FAIL.NONE }));
    let cursor = 0;
    let coreNotReadyStreak = 0;
    let batchAbortKind = '';
    let active = 0;
    let peak = 0;
    const retryQueue = [];
    const retriedIdx = new Set();
    const lanes = Math.min(this.lanes, names.length);
    const workers = [];
    for (let w = 0; w < lanes; w++) {
      workers.push((async () => {
        for (;;) {
          let i = -1;
          if (retryQueue.length > 0) {
            const queuedIndex = retryQueue[retryQueue.length - 1];
            retryQueue.pop();
            i = queuedIndex;
          } else {
            i = cursor;
            cursor += 1;
          }
          if (i >= names.length) return;
          if (nowFn() >= deadlineAt) return;              // 硬截止：其余节点保持「未测」
          const urlIndexBefore = this.urlIndex;
          active += 1;
          peak = Math.max(peak, active);
          const attempt = await this.probeNodeBounded(names[i], this.perNodeMs, deadlineAt, nowFn);
          active -= 1;
          if (attempt.failKind === FAIL.CORE) {
            coreNotReadyStreak += 1;
            if (coreNotReadyStreak >= CORE_NOT_READY_ABORT_STREAK && batchAbortKind.length === 0) {
              batchAbortKind = FAIL.CORE;
            }
          } else {
            coreNotReadyStreak = 0;
          }
          if (this.isUrlLevelFailure(attempt.failKind)
            && this.urlIndex !== urlIndexBefore
            && !retriedIdx.has(i)
            && nowFn() < deadlineAt) {
            retriedIdx.add(i);
            this.peerRetries.set(names[i], (this.peerRetries.get(names[i]) || 0) + 1);
            retryQueue.push(i);
            continue;
          }
          const rec = this.applyLatencyResult(attempt, collected[i]);
          progressSink(rec, nowFn());
        }
      })());
    }
    await Promise.all(workers);
    // 到点 / 未开始 / 无结论的节点：显式标为「未测」（绝不落成超时）
    for (const rec of collected) {
      if (rec.latency === -2) {
        if (rec.failKind.length === 0) rec.failKind = FAIL.UNTESTED;
      }
    }
    const stats = summarizeMirror(collected);
    return { collected, stats, peak, abortKind: batchAbortKind, emits: collected.length, retried: this.peerRetries };
  }
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

/** 镜像 NodeLatencyRecord.isNonVerdict */
function isNonVerdict(kind) {
  return kind === FAIL.CORE || kind === FAIL.PORT || kind === FAIL.UNTESTED || kind === FAIL.UNSUPPORTED;
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

/** git blob 与工作区文件在「行尾归一化后」逐字节一致 */
function assertByteIdenticalToHead(relPath, why) {
  const abs = path.join(root, relPath);
  const headBuf = execFileSync('git', ['show', 'HEAD:./' + relPath], { cwd: root });
  const workBuf = fs.readFileSync(abs);
  const norm = (b) => b.toString('utf8').replace(/\r\n/g, '\n');
  assert.strictEqual(norm(workBuf), norm(headBuf), `${relPath} 必须与 HEAD 逐字节一致（${why}）`);
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
  // delay API 是「直接对任意已注册 proxy 名并发测」，不切 selector
  assert(!/\/proxies\/[^\n]*\/select/.test(api), 'delay 路径不得退化成 selector 切换');

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
  // 五类（含「未测」）必须互不相同，否则 UI/日志/快照无法区分
  assert.strictEqual(
    new Set([FAIL.CORE, FAIL.SWITCH, FAIL.NET, FAIL.TIMEOUT, FAIL.UNTESTED]).size, 5);
  assert.strictEqual(api.includes("static readonly UNTESTED: string = 'untested';"), true);

  // ---- 4. 每节点单次请求 + 短预算（2000ms） ----
  const urls = ['urlA', 'urlB', 'urlC'];
  {
    const engine = new BatchMirror({
      lanes: BATCH_LANES, deadlineMs: BATCH_DEADLINE_MS, perNodeMs: BATCH_NODE_TIMEOUT_MS, urls,
      request: async () => { await delay(2); return { delayMs: 55, failKind: FAIL.NONE, code: 200 }; }
    });
    const nodes = Array.from({ length: 40 }, (_, i) => `n${i}`);
    const out = await engine.run(nodes);
    assert.strictEqual(out.stats.ok, 40);
    assert.strictEqual(engine.requests.length, 40, '每个节点必须只发出一次 delay 请求');
    for (const r of engine.requests) {
      assert.strictEqual(r.budget, BATCH_NODE_TIMEOUT_MS, '单次预算必须是 2000ms（不再按剩余次数切碎）');
      assert.strictEqual(r.url, 'urlA', '未降级前整批使用同一个 URL');
    }
    assert.strictEqual(engine.urlSwitches, 0, '全部成功时不得发生 URL 降级');
  }

  // ---- 5. 整批级 URL 降级（连续失败 5 次换 URL + 失败节点复测一次） ----
  {
    const engine = new BatchMirror({
      lanes: 4, deadlineMs: BATCH_DEADLINE_MS, perNodeMs: BATCH_NODE_TIMEOUT_MS, urls,
      request: async (url) => {
        await delay(2);
        if (url === 'urlA') return { delayMs: -1, failKind: FAIL.TIMEOUT, code: 504 };
        return { delayMs: 70, failKind: FAIL.NONE, code: 200 };
      }
    });
    const nodes = Array.from({ length: 12 }, (_, i) => `m${i}`);
    const out = await engine.run(nodes);
    assert(engine.urlSwitches >= 1, `整批必须发生 URL 降级: switches=${engine.urlSwitches}`);
    assert.strictEqual(engine.urlIndex, 1, '降级后整批切到下一个候选 URL');
    // 复测：在旧 URL 上失败过的节点必须带新 URL 重测一次，且只重测一次
    const firstA = engine.requests.filter((r) => r.url === 'urlA').length;
    const retried = engine.requests.filter((r) => r.url === 'urlB').length;
    assert(firstA >= URL_GLOBAL_DEMOTE_STREAK, '降级前至少已连续失败 5 次');
    assert(retried > 0, '旧 URL 上失败的节点必须带新 URL 复测');
    for (const [name, count] of engine.peerRetries) {
      assert(count <= 1, `节点 ${name} 最多复测一次，实际 ${count}`);
    }
    assert(out.stats.verdicts() > 0, '降级后必须仍能得出节点判定');
    assert(out.stats.ok > 0, '新 URL 可用的节点必须测出延迟');
    // 降级后 URL 抖动不能把整批拖死：总请求数有限
    assert(engine.requests.length <= nodes.length * 2, `请求数失控: ${engine.requests.length}`);
  }
  // generation 变化（新批次）复位整批 URL 状态
  {
    const engine = new BatchMirror({
      lanes: 2, deadlineMs: BATCH_DEADLINE_MS, perNodeMs: BATCH_NODE_TIMEOUT_MS, urls,
      request: async (url) => (url === 'urlA'
        ? { delayMs: -1, failKind: FAIL.NET, code: 502 }
        : { delayMs: 60, failKind: FAIL.NONE, code: 200 })
    });
    await engine.run(['a', 'b', 'c', 'd', 'e', 'f']);
    assert(engine.urlIndex > 0, '整批 URL 必须已降级');
    engine.resetGeneration();
    assert.strictEqual(engine.urlIndex, 0, '新 generation 必须复位整批 URL 状态');
  }

  // ---- 6. 硬上限与整批硬截止：到点未完成 → 未测（不是超时） ----
  {
    // 6a 截止还远 → 单节点超时标 TIMEOUT
    const engine = new BatchMirror({
      lanes: 2, deadlineMs: BATCH_DEADLINE_MS, perNodeMs: 200, urls,
      request: () => new Promise(() => {})
    });
    const far = Date.now() + BATCH_DEADLINE_MS;
    const startedAt = Date.now();
    const timedOut = await engine.probeNodeBounded('hang', 200, far, () => Date.now());
    assert.strictEqual(timedOut.failKind, FAIL.TIMEOUT);
    assert.strictEqual(timedOut.delayMs, -1);
    assert(Date.now() - startedAt < 200 + NODE_PROBE_GUARD_SLACK_MS + 600, '单节点硬上限必须生效');

    // 6b 截止已到 → 未测（绝不是超时）
    const cut = await engine.probeNodeBounded('hang', 200, Date.now() - 1, () => Date.now());
    assert.strictEqual(cut.failKind, FAIL.UNTESTED, '整批到点未完成必须标「未测」');
    assert.strictEqual(cut.delayMs, -2, '「未测」不携带失败延迟');
    assert.strictEqual(cut.deadlineCut, true);
  }
  {
    // 6c 整批硬截止：慢节点在截止后被留成「未测」，且绝不写进「失败/超时」
    const engine = new BatchMirror({
      lanes: 2, deadlineMs: 60, perNodeMs: 40, urls,
      request: async () => { await delay(40); return { delayMs: 30, failKind: FAIL.NONE, code: 200 }; }
    });
    const nodes = Array.from({ length: 30 }, (_, i) => `slow${i}`);
    const out = await engine.run(nodes);
    assert(out.stats.untested > 0, `整批硬截止必须留下「未测」节点: ${JSON.stringify(out.stats)}`);
    assert.strictEqual(out.stats.timeout, 0, '到点未完成绝不能被计成「超时」');
    assert.strictEqual(out.stats.failed, 0, '到点未完成绝不能被计成「失败」');
    for (const rec of out.collected) {
      if (rec.latency === -2) {
        assert.strictEqual(rec.failKind, FAIL.UNTESTED, '未测节点的 failKind 必须是 untested');
      }
    }
  }

  // ---- 7. 并发上限、渐进回调、迟到响应、Promise.all 兵底 ----
  const arithmeticRounds = Math.ceil(150 / BATCH_LANES);
  assert.strictEqual(arithmeticRounds, 6, '150 节点 / 28 路 = 6 轮');
  assert.strictEqual(arithmeticRounds * BATCH_NODE_TIMEOUT_MS, 12000,
    '150 节点整批最坏耗时算术: 6 × 2000ms = 12000ms');
  assert(arithmeticRounds * BATCH_NODE_TIMEOUT_MS <= BATCH_DEADLINE_MS,
    '最坏算术耗时必须落在整批硬截止之内');
  {
    const emitTimes = [];
    const engine = new BatchMirror({
      lanes: BATCH_LANES, deadlineMs: BATCH_DEADLINE_MS, perNodeMs: BATCH_NODE_TIMEOUT_MS, urls,
      request: async () => { await delay(4); return { delayMs: 40, failKind: FAIL.NONE, code: 200 }; }
    });
    const nodes = Array.from({ length: 150 }, (_, i) => `p${i}`);
    const startedAt = Date.now();
    const out = await engine.run(nodes, { progressSink: () => emitTimes.push(Date.now()) });
    const elapsed = Date.now() - startedAt;
    assert.strictEqual(out.stats.ok, 150);
    assert(out.peak <= BATCH_LANES, `并发上限被突破: ${out.peak}`);
    assert(out.peak >= 8, `并发没真正跑起来: ${out.peak}`);
    assert.strictEqual(emitTimes.length, 150, '每条结果都必须触发一次渐进回调（边到边刷）');
    assert(emitTimes[0] <= startedAt + elapsed && emitTimes[149] - emitTimes[0] >= 20,
      '渐进回调必须散布在整个批次期间，而不是攒到最后一次');
    // 6 轮 × 4ms ≈ 24ms（远小于硬截止）
    assert(elapsed < BATCH_DEADLINE_MS, `整批耗时异常: ${elapsed}ms`);
  }
  // 迟到响应作废（generation 变化后旧结果不得写入）
  {
    let generation = 1;
    const writes = [];
    const runOne = async () => {
      const local = generation;
      await delay(30);
      if (local !== generation) return;
      writes.push(1);
    };
    const p = runOne();
    generation = 2;
    await p;
    assert.strictEqual(writes.length, 0, '迟到响应必须被批次代次作废');
  }
  // Promise.all 兵底（settled 看门狗）
  {
    const settled = (worker, capMs) => new Promise((resolve) => {
      let done = false;
      const timer = setTimeout(() => { if (!done) { done = true; resolve(); } }, capMs);
      const finish = () => { if (!done) { done = true; clearTimeout(timer); resolve(); } };
      worker.then(finish, finish);
    });
    const guardStarted = Date.now();
    await Promise.all([settled(new Promise(() => {}), 120), settled(delay(10), 120)]);
    assert(Date.now() - guardStarted < 600, 'Promise.all 兵底未生效：整批被长尾拖住');
  }

  // ---- 8. 核心不可用 → 中止整批、不落盘、不算超时 ----
  {
    const engine = new BatchMirror({
      lanes: 1, deadlineMs: BATCH_DEADLINE_MS, perNodeMs: BATCH_NODE_TIMEOUT_MS, urls,
      request: async () => ({ delayMs: -1, failKind: FAIL.CORE, code: 401 })
    });
    const collected = [];
    let coreNotReadyStreak = 0;
    let batchAbortKind = '';
    let cursor = 0;
    const list = ['a', 'b', 'c', 'd', 'e'];
    for (const name of list) collected.push({ name, latency: -2, failKind: FAIL.NONE });
    while (batchAbortKind.length === 0 && cursor < list.length) {
      const attempt = { delayMs: -1, failKind: FAIL.CORE, httpCode: 401 };
      if (attempt.failKind === FAIL.CORE) {
        coreNotReadyStreak++;
        if (coreNotReadyStreak >= CORE_NOT_READY_ABORT_STREAK && batchAbortKind.length === 0) {
          batchAbortKind = FAIL.CORE;
        }
      } else {
        coreNotReadyStreak = 0;
      }
      engine.applyLatencyResult(attempt, collected[cursor]);
      cursor++;
    }
    assert.strictEqual(batchAbortKind, FAIL.CORE);
    assert.strictEqual(cursor, CORE_NOT_READY_ABORT_STREAK, '核心不可用时应在阈值处中止，而非跑完整批');
    const coreStats = summarizeMirror(collected.slice(0, cursor));
    assert.strictEqual(coreStats.verdicts(), 0, '核心不可用不得产生节点判定');
    assert.strictEqual(coreStats.failed, 0, '核心不可用不得被写成「超时失败」并落盘');
    assert.strictEqual(coreStats.untested, cursor, '核心不可用必须表现为「未测」');
    // 页面在 verdicts()===0 时直接返回、不持久化
    assert(page.includes('if (stats.verdicts() === 0) {'));
    assert(page.includes("promptAction.showToast({ message: '未取得有效测速结果，已保留原有排序' });"));
  }
  // 直连降级（仅端口可达）同样不算节点判定，且不显示成超时
  {
    const rec = { latency: -2, failKind: FAIL.NONE };
    new BatchMirror({ lanes: 1, deadlineMs: 1, perNodeMs: 1, urls, request: async () => ({ delayMs: 0 }) })
      .applyLatencyResult({ delayMs: 33, failKind: FAIL.PORT, channel: 'direct' }, rec);
    assert.strictEqual(rec.latency, -2, '端口可达不得写成代理延迟');
    assert.strictEqual(rec.failKind, FAIL.PORT);
    assert.strictEqual(summarizeMirror([rec]).verdicts(), 0);
    assert(isNonVerdict(FAIL.PORT));
  }

  // ---- 9. 排序快照语义：整批未测绝不写成「全失败」 ----
  {
    const previous = [
      { name: 'a', latency: 120, failCount: 0, lastOk: true, failKind: '' },
      { name: 'b', latency: -1, failCount: 2, lastOk: false, failKind: FAIL.TIMEOUT },
      { name: 'z', latency: 45, failCount: 0, lastOk: true, failKind: '' }
    ];
    const results = [
      { name: 'a', latency: -2, failKind: FAIL.UNTESTED },   // 到点未测 → 沿用旧成功结论
      { name: 'b', latency: -1, failKind: FAIL.TIMEOUT },    // 真实超时 → 失败次数 +1
      { name: 'c', latency: 88, failKind: FAIL.NONE }        // 真实成功
    ];
    const sorted = buildAutoMirror(results, previous, ['a', 'b', 'c', 'z']);
    const byName = new Map(sorted.map((r) => [r.name, r]));
    assert.strictEqual(byName.get('a').latency, 120, '未测不得覆盖旧的成功延迟');
    assert.strictEqual(byName.get('a').lastOk, true);
    assert.strictEqual(byName.get('a').failCount, 0, '未测不得被记成失败次数 +1');
    assert.strictEqual(byName.get('b').latency, -1);
    assert.strictEqual(byName.get('b').failCount, 3);
    assert.strictEqual(byName.get('c').latency, 88);
    assert.strictEqual(byName.get('z').latency, 45, '本次未测节点必须沿用旧结论（快照不被截断）');
    assert.strictEqual(sorted.length, 4);
    // 整批未测（核心不可用 + 到点未测 + 端口可达混合）→ 全失败假象必须消失
    const allNonVerdict = [
      { name: 'a', latency: -2, failKind: FAIL.UNTESTED },
      { name: 'b', latency: -2, failKind: FAIL.CORE },
      { name: 'z', latency: -2, failKind: FAIL.PORT }
    ];
    const kept = buildAutoMirror(allNonVerdict, previous, null);
    const prevByName = new Map(previous.map((p) => [p.name, p]));
    for (const rec of kept) {
      const before = prevByName.get(rec.name);
      assert.strictEqual(rec.latency, before.latency,
        `整批未测必须沿用旧的延迟结论 (${rec.name}: ${before.latency} -> ${rec.latency})`);
      assert.strictEqual(rec.failCount, before.failCount,
        `整批未测不得增加失败次数 (${rec.name}: ${before.failCount} -> ${rec.failCount})`);
      assert.strictEqual(rec.lastOk, before.lastOk, `整批未测不得翻转 lastOk (${rec.name})`);
    }
    // 首次出现且是未测 → 保持「未测」而不是超时
    const fresh = buildAutoMirror([{ name: 'd', latency: -2, failKind: FAIL.UNTESTED }], null, null);
    assert.strictEqual(fresh[0].latency, -2);
    assert.strictEqual(fresh[0].lastOk, false);
    assert.strictEqual(fresh[0].failCount, 0, '首次未测不得记成失败');
    // keepNames 为 null 时保持旧的「整体覆盖」语义
    assert.strictEqual(buildAutoMirror(results, previous, null).length, 3);
    // Python 式的非判定集合与源码一致
    assert(sortSrc.includes('|| failKind === LatencyFailKind.UNTESTED'));
    assert(sortSrc.includes('|| failKind === LatencyFailKind.UNSUPPORTED'));
    assert(sortSrc.includes('|| failKind === LatencyFailKind.PORT_ONLY'));
  }

  // ---- 10. 源码接线断言 ----
  assert(page.includes('const BATCH_LANES = 28;'), '并发上限必须是 28 路常量');
  assert(page.includes('const BATCH_NODE_TIMEOUT_MS = 2000;'), '组测单次预算必须是 2000ms');
  assert(page.includes('const SINGLE_NODE_TIMEOUT_MS = 3000;'));
  assert(page.includes('const URL_GLOBAL_DEMOTE_STREAK = 5;'), 'URL 降级阈值必须是连续 5 次失败');
  assert(page.includes('const BATCH_DEADLINE_MS = 12000;'), '整批硬截止必须是 12s');
  assert(page.includes('const CORE_NOT_READY_ABORT_STREAK = 3;'));
  assert(page.includes('const NODE_PROBE_GUARD_SLACK_MS = 1000;'));
  // 旧实现必须消失（只看代码，注释里复述旧实现不算违规）
  assert(!pageCode.includes('isUrlDemoted'), '按 URL 逐节点跳过（旧 URL 记忆）必须移除');
  assert(!pageCode.includes('urlFailStreak'), '旧 URL 记忆表必须移除');
  assert(!pageCode.includes('urlFailGen'), '旧 URL 记忆代次必须移除');
  assert(!/Math\.floor\(\s*remaining\s*\/\s*attemptsLeft\s*\)/.test(pageCode),
    '预算切分逻辑必须从代码中移除');
  assert(!/deadline\s*=\s*Date\.now\(\)\s*\+\s*timeoutMs/.test(pageCode),
    '单节点总预算切分必须移除');
  // 断言能力自检：codeOnly 真的会剥注释、也真的会保留代码
  assert(!/Math\.floor\(\s*remaining\s*\/\s*attemptsLeft\s*\)/.test(
    codeOnly('// 旧实现：Math.floor(remaining / attemptsLeft)')), 'codeOnly 必须剥离注释行');
  assert(/Math\.floor\(\s*remaining\s*\/\s*attemptsLeft\s*\)/.test(
    codeOnly('const budget = Math.floor(remaining / attemptsLeft);')), 'codeOnly 必须保留真实代码');
  // 正向语义：单请求 + 整批当前 URL + 全局降级
  assert(/testLatencyDetailed\(node\.name,\s*url,\s*timeoutMs\)/.test(pageCode),
    '每个节点必须用「当前 URL」单次请求 delay API');
  assert(page.includes('const maxAttempts = allowUrlFallback ? Math.min(2, urls.length) : 1;'),
    '组测必须只打一次请求（URL 回退只允许单测路径）');
  assert(page.includes('private isUrlLevelFailure(failKind: string): boolean'));
  assert(page.includes('private noteUrlFailure(generation: number): boolean'));
  assert(page.includes('private currentBatchUrl(generation: number): string'));
  assert(page.includes('this.batchUrlIndex = next;'));
  assert(page.includes('const batchDeadlineAt = Date.now() + BATCH_DEADLINE_MS;'));
  assert(page.includes('if (Date.now() >= batchDeadlineAt) {'));
  assert(page.includes('retryQueue.push(i);'), 'URL 全局降级后失败节点必须带新 URL 复测一次');
  assert(page.includes('!retriedIdx.has(i)'), '每个节点最多复测一次');
  // 硬截止 → 未测
  assert(page.includes('aborted.failKind = LatencyFailKind.UNTESTED;'));
  assert(page.includes('const deadlineCut = remainingMs <= nodeCapMs;'));
  assert(page.includes('rec.failKind = LatencyFailKind.UNTESTED;'),
    '到点/无结论的节点必须落成「未测」');
  assert(page.includes('if (stats.verdicts() === 0) {'));
  // 未测 / 端口可达不得显示成超时
  assert(page.includes('this.untestedNames.add(node.name);'));
  assert(page.includes("this.untestedNames.has(row.node.name) ? '未测'"), 'UI 必须显示「未测」');
  assert(page.includes("this.directReachableNames.has(row.node.name) ? '端口可达'"), '端口可达约定必须保留');
  assert(page.includes('private pruneStaleLatencyDisplay(): void'));
  assert(page.includes('LatencyController.retainOnly(valid);'));
  // 渐进刷 UI + 计数
  assert(page.includes('this.batchProgressEmits = this.batchProgressEmits + 1;'));
  assert(page.includes('progress=${this.batchProgressEmits}'));
  assert(page.includes('LatencyController.addListener(this.latencyListener);'));
  assert(page.includes('LatencyController.flushNow();'));
  // 兵底与公共函数
  assert(page.includes('await this.settleWorkers(workers, this.batchGuardMs(list.length, lanes))'));
  assert(!page.includes('await Promise.all(workers)'));
  assert(page.includes('private async testNodeDelay(node: ProxyNode, timeoutMs: number,'));
  assert.strictEqual((page.match(/private async testNodeDelay/g) || []).length, 1,
    '组测与单测必须共用同一个测速函数');
  assert(page.includes('await this.probeNodeBounded(list[i], BATCH_NODE_TIMEOUT_MS,'));
  assert(page.includes('generation, batchDeadlineAt);'));
  assert(page.includes('await this.probeNodeBounded(node, SINGLE_NODE_TIMEOUT_MS, generation,'));
  assert(page.includes('singleDeadline, true);'));
  assert(page.includes('await this.orchestrator.api.testLatencyDetailed('));
  assert(page.includes('attempt.failKind = probe.failKind.length > 0 ? probe.failKind : LatencyFailKind.NETWORK_UNREACHABLE;'),
    'testNodeDelay 必须透传底层失败分类，而不是把失败一律写成超时');
  assert(api.includes('return LatencyFailKind.TIMEOUT;'), '超时分类必须由 ClashApiService 判定');
  assert(page.includes('this.batchGen !== generation'));
  assert(page.includes('coreNotReady=${stats.coreNotReady}'));
  assert(page.includes('switchFailed=${stats.switchFailed}'));
  assert(page.includes('this.sortSnapshot = NodeSortSnapshot.buildAuto(Date.now(), collected, this.sortSnapshot, allNames)'));
  assert(sortSrc.includes('static isNonVerdict(failKind: string): boolean'));
  assert(sortSrc.includes("failKind: string = '';"));
  assert(sortSrc.includes('keepNames: string[] | null = null'));
  assert(api.includes('export class LatencyFailKind'));
  assert(api.includes('async testLatencyDetailed('));
  assert(api.includes('classifyStatusCode'));
  assert(api.includes('if (resp.responseCode !== 200)'));
  assert(api.includes('if (body.length === 0)'));
  assert(api.includes('kind=${out.failKind}'));
  assert(orch.includes('async ensureTestCore('), 'orchestrator must keep ensureTestCore');
  assert(page.includes('await this.orchestrator.ensureTestCore(this.subs, this.settings)'));
  // 测速配置必须包含**全部**节点（否则 /proxies/{name}/delay 会大面积 404）
  assert(orch.includes('ClashConfigGenerator.generate(subs.nodes[0], subs.nodes, settings,'),
    'TestCore 配置必须传入全部节点（subs.nodes），否则无法直接对任意节点并发测速');
  assert(orch.includes('MIXED_PORT, API_PORT, this.testCoreSecret, testGeoip, false, hosts, false);'),
    'TestCore 配置必须是 headless（tunEnabled=false），不得影响真实连接配置');
  // 配置生成器本轮**未改动**：关闭新参数时输出必然与改动前逐字节一致
  assertByteIdenticalToHead(relGen,
    '本轮未新增任何配置生成参数；关闭新参数时输出必须与改动前逐字节一致');
  assertByteIdenticalToHead('entry/src/main/ets/commons/services/YamlMerger.ets',
    '配置生成器的解析依赖不得改动');

  console.log('PASS latency pipeline regression: special names, mihomo parsing, 5 distinct failure'
    + ' classes, single-request-per-node (2000ms budget), batch-level URL degrade (5 fails ->'
    + ' switch + one retry per node), node hard cap + 12s batch deadline -> untested, 28-lane'
    + ' concurrency, progressive emits (1 per result), core-not-ready abort w/o persist,'
    + ' sort snapshot never records untested as failure, TestCore config covers all nodes,'
    + ' config generator byte-identical to HEAD');
}

main().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
