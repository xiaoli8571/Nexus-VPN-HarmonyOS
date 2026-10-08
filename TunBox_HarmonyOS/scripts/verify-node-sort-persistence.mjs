/**
 * NodeSortPersistence（排序 + 持久化）真实行为验证。
 *
 * 为什么需要这个套件：NodeSortSnapshot 是「可排序 / 结果可持久化」的全部实现，
 * 但在本次重做之前**没有任何套件覆盖它**（grep NodeSortSnapshot 在所有 verify 脚本里
 * 命中为 0）。它是纯逻辑，可以直接在 Node 里真实驱动 —— 比读源码断言强得多。
 *
 * 做法与 verify-latency-cache.mjs 一致：把 .ets 暂存成 .ts 后在 Node 里 import。
 * NodeSortPersistence 依赖 ProxyNode（模型）与 LatencyFailKind（ClashApiService，
 * 会拉进 @ohos.net.http，无法在 Node 里加载），所以为这两者生成**桩**；
 * 桩里的常量从真实源码里正则抽取，并断言抽取成功 —— 保证桩不会与真实值漂移。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const svc = path.join(root, 'entry/src/main/ets/commons/services/');

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
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${label}: expected ${b}, got ${a}`);
}
function ok(cond, label) {
  if (!cond) throw new Error(label);
}

// ── 从真实源码抽取 LatencyFailKind 常量（桩不许与真实值漂移） ──────────────
const apiSrc = fs.readFileSync(path.join(svc, 'ClashApiService.ets'), 'utf8');
const kindBlock = apiSrc.slice(apiSrc.indexOf('export class LatencyFailKind'));
const kindPairs = [...kindBlock.matchAll(/static readonly (\w+): string = '([^']*)'/g)]
  .map((m) => [m[1], m[2]]);
ok(kindPairs.length >= 7, `expected >=7 LatencyFailKind constants, got ${kindPairs.length}`);
const KIND = Object.fromEntries(kindPairs);

// ── 暂存 ──────────────────────────────────────────────────────────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'nodesort-'));
const stub = `
export class ProxyNodeType {
  static readonly SS: string = 'ss';
  static readonly SSR: string = 'ssr';
}
export class ProxyNode {
  name: string = '';
  type: string = '';
  server: string = '';
  port: number = 0;
}
`;
const kindsStub = `export class LatencyFailKind {\n${
  kindPairs.map(([k, v]) => `  static readonly ${k}: string = '${v}';`).join('\n')
}\n}\n`;
fs.writeFileSync(path.join(stage, 'ProxyNode.ts'), stub);
fs.writeFileSync(path.join(stage, 'ClashApiService.ts'), kindsStub);

let src = fs.readFileSync(path.join(svc, 'NodeSortPersistence.ets'), 'utf8');
src = src
  .replace(/from '\.\.\/models\/ProxyNode'/g, "from './ProxyNode.ts'")
  .replace(/from '\.\/ClashApiService'/g, "from './ClashApiService.ts'");
ok(!/from '@ohos/.test(src), 'staged module must not import ohos kits');
fs.writeFileSync(path.join(stage, 'NodeSortPersistence.ts'), src);

const mod = await import(pathToFileURL(path.join(stage, 'NodeSortPersistence.ts')).href);
const { NodeSortSnapshot, NodeLatencyRecord, NodeSortModes } = mod;

/** 造一条记录：latency>=0 实测 / -1 失败 / -2 未测 */
function rec(name, latency, opts = {}) {
  const r = new NodeLatencyRecord();
  r.name = name;
  r.latency = latency;
  r.failCount = opts.failCount ?? 0;
  r.lastOk = opts.lastOk ?? latency >= 0;
  r.failKind = opts.failKind ?? '';
  return r;
}
function snapOf(records, mode = NodeSortModes.AUTO, order = [], testedAt = 1000) {
  const s = new NodeSortSnapshot();
  s.testedAt = testedAt;
  s.mode = mode;
  s.records = records;
  s.order = order;
  return s;
}

// ── 1. 排序权重语义 ───────────────────────────────────────────────────────
check('latencyRank: 实测=0 / 未测=1 / 失败=2（失败绝不在最前）', () => {
  eq(NodeSortSnapshot.latencyRank(rec('a', 42)), 0, 'measured');
  eq(NodeSortSnapshot.latencyRank(rec('b', 0)), 0, '0ms 仍是实测档（有效性由上游把关）');
  eq(NodeSortSnapshot.latencyRank(rec('c', -2)), 1, 'untested');
  eq(NodeSortSnapshot.latencyRank(rec('d', -1)), 2, 'failed');
  eq(NodeSortSnapshot.latencyRank(null), 1, 'missing record counts as untested');
});

check('AUTO 排序：实测升序 → 未测 → 失败，且失败排最后', () => {
  const s = snapOf([
    rec('slow', 300), rec('fast', 20), rec('dead', -1), rec('untested', -2), rec('mid', 100),
  ]);
  eq(s.orderedNames(['slow', 'fast', 'dead', 'untested', 'mid']),
    ['fast', 'mid', 'slow', 'untested', 'dead'], 'order');
});

check('AUTO 排序稳定：延迟相同保持订阅原顺序', () => {
  const s = snapOf([rec('a', 50), rec('b', 50), rec('c', 50)]);
  eq(s.orderedNames(['c', 'a', 'b']), ['c', 'a', 'b'], 'ties keep original order');
});

check('无测速数据 / default 模式：返回空数组（调用方保持订阅顺序）', () => {
  const none = snapOf([rec('a', -2), rec('b', -2)]);
  eq(none.orderedNames(['b', 'a']), [], 'all untested -> no reorder');
  eq(none.hasLatencyData(), false, 'hasLatencyData false');
  const def = snapOf([rec('a', 10)], NodeSortModes.DEFAULT);
  eq(def.orderedNames(['a', 'b']), [], 'default mode -> no reorder');
});

check('MANUAL 排序：显式顺序优先，未列出的保持相对顺序沉底', () => {
  const s = snapOf([rec('a', 10), rec('b', 20), rec('c', 30)], NodeSortModes.MANUAL, ['c', 'a']);
  eq(s.orderedNames(['a', 'b', 'c']), ['c', 'a', 'b'], 'explicit order then remaining');
});

// ── 2. 失败分类：什么算「节点结论」 ────────────────────────────────────────
check('isNonVerdict: 通道/端口/未测/不支持 都不是节点结论', () => {
  for (const k of [KIND.CORE_NOT_READY, KIND.PORT_ONLY, KIND.UNTESTED, KIND.UNSUPPORTED]) {
    ok(NodeLatencyRecord.isNonVerdict(k), `${k} must be non-verdict`);
  }
  for (const k of ['', KIND.TIMEOUT, KIND.NETWORK_UNREACHABLE, KIND.SWITCH_FAILED]) {
    ok(!NodeLatencyRecord.isNonVerdict(k), `${k || '(none)'} must be a verdict`);
  }
});

check('recentSuccessRate: 未测=-1 / 失败=0 / 成功按失败次数衰减', () => {
  eq(rec('a', -2).recentSuccessRate(), -1, 'untested');
  eq(rec('b', -1, { lastOk: false }).recentSuccessRate(), 0, 'failed');
  eq(rec('c', 30, { lastOk: true, failCount: 0 }).recentSuccessRate(), 1, 'clean success');
  ok(rec('d', 30, { lastOk: true, failCount: 3 }).recentSuccessRate() < 1, 'decays with failures');
});

// ── 3. buildAuto：合并与沿用（「内核一抖半张列表变红」的持久化防线） ────────
check('buildAuto: 通道故障结果沿用上一次结论，绝不写成失败', () => {
  const prev = snapOf([rec('a', 42), rec('b', 88)]);
  const out = NodeSortSnapshot.buildAuto(Date.now(), [
    rec('a', -1, { failKind: KIND.CORE_NOT_READY }),
    rec('b', -1, { failKind: KIND.PORT_ONLY }),
  ], prev, ['a', 'b']);
  eq(out.recordFor('a').latency, 42, 'core_not_ready carries previous latency');
  eq(out.recordFor('b').latency, 88, 'port_only carries previous latency');
  eq(out.mode, NodeSortModes.AUTO, 'mode');
});

check('buildAuto: 真超时/真失败 才覆盖上一次结论', () => {
  const prev = snapOf([rec('a', 42, { lastOk: true })]);
  const out = NodeSortSnapshot.buildAuto(Date.now(), [
    rec('a', -1, { failKind: KIND.TIMEOUT, lastOk: false }),
  ], prev, ['a']);
  eq(out.recordFor('a').latency, -1, 'real timeout overwrites');
  ok(out.recordFor('a').failCount >= 1, 'failCount accumulates');
});

check('buildAuto: keepNames 让子集测速不截断整份快照', () => {
  const prev = snapOf([rec('a', 42), rec('b', 88), rec('c', 7)]);
  // 本轮只测了 a（例如按订阅筛选后测速）
  const out = NodeSortSnapshot.buildAuto(Date.now(), [rec('a', 11)], prev, ['a', 'b', 'c']);
  eq(out.records.length, 3, 'all three nodes present after merge');
  eq(out.recordFor('a').latency, 11, 'tested node updated');
  eq(out.recordFor('b').latency, 88, 'untouched node kept');
  eq(out.recordFor('c').latency, 7, 'untouched node kept');
});

check('buildAuto: 无 previous 时非节点结论保持未测（不冒充失败）', () => {
  const out = NodeSortSnapshot.buildAuto(Date.now(), [
    rec('a', -1, { failKind: KIND.CORE_NOT_READY }),
  ], null, ['a']);
  eq(out.recordFor('a').latency, -2, 'no previous verdict -> stays untested');
  eq(out.hasLatencyData(), false, 'so it cannot drive a reorder');
});

// ── 4. 持久化往返与容错 ───────────────────────────────────────────────────
check('序列化往返保真（records / order / mode / testedAt）', () => {
  const s = snapOf([rec('a', 42, { failCount: 2 }), rec('b', -1, { failKind: KIND.TIMEOUT })],
    NodeSortModes.MANUAL, ['b', 'a'], 123456);
  const back = NodeSortSnapshot.fromJsonText(s.toJsonText());
  ok(back !== null, 'must parse');
  eq(back.testedAt, 123456, 'testedAt');
  eq(back.mode, NodeSortModes.MANUAL, 'mode');
  eq(back.order, ['b', 'a'], 'order');
  eq(back.records.length, 2, 'records');
  eq(back.recordFor('b').failKind, KIND.TIMEOUT, 'failKind survives (needed to avoid mis-sorting)');
  eq(back.recordFor('a').failCount, 2, 'failCount');
});

check('损坏/空快照 → null（调用方回退默认顺序，绝不抛）', () => {
  eq(NodeSortSnapshot.fromJsonText(''), null, 'empty');
  eq(NodeSortSnapshot.fromJsonText('{not json'), null, 'malformed');
  eq(NodeSortSnapshot.fromJsonText('null'), null, 'literal null');
});

check('反序列化丢弃无效记录、夹紧非法数值', () => {
  const raw = JSON.stringify({
    testedAt: 'nope', mode: 'bogus', order: ['ok', '', 42],
    records: [
      { name: 'good', latency: 30, failCount: 1, lastOk: true },
      { name: '', latency: 10 },
      { latency: 10 },
      { name: 'nan', latency: 'x' },
      { name: 'neg', latency: 5, failCount: -3 },
      { name: 'longkind', latency: 5, failKind: 'x'.repeat(64) },
    ],
  });
  const s = NodeSortSnapshot.fromJsonText(raw);
  ok(s !== null, 'parses');
  eq(s.testedAt, 0, 'bad testedAt -> 0');
  eq(s.mode, NodeSortModes.DEFAULT, 'unknown mode normalized');
  eq(s.order, ['ok'], 'order filters non-strings/empties');
  eq(s.records.map((r) => r.name), ['good', 'nan', 'neg', 'longkind'], 'drops nameless records');
  eq(s.recordFor('nan').latency, -1, 'non-numeric latency -> -1 (failed, never 0)');
  eq(s.recordFor('neg').failCount, 0, 'negative failCount clamped');
  eq(s.recordFor('longkind').failKind, '', 'over-long failKind rejected');
});

check('缓存新鲜度 TTL = 5 分钟（边界）', () => {
  const s = snapOf([rec('a', 10)], NodeSortModes.AUTO, [], 1_000_000);
  ok(s.isCacheFresh(1_000_000 + 299_999), 'just inside');
  ok(!s.isCacheFresh(1_000_000 + 300_000), 'exactly at TTL is stale');
  ok(!snapOf([], NodeSortModes.AUTO, [], 0).isCacheFresh(1), 'testedAt=0 is never fresh');
});

// ── 5. 端到端：一次"内核故障"批测不得污染排序 ─────────────────────────────
check('端到端：整批通道故障后，排序与上次实测完全一致', () => {
  const first = NodeSortSnapshot.buildAuto(1_000_000, [
    rec('fast', 20), rec('mid', 100), rec('slow', 300),
  ], null, ['fast', 'mid', 'slow']);
  const before = first.orderedNames(['fast', 'mid', 'slow']);
  eq(before, ['fast', 'mid', 'slow'], 'baseline order');

  // 第二轮：内核挂了，三个节点全部 core_not_ready
  const second = NodeSortSnapshot.buildAuto(1_100_000, [
    rec('fast', -1, { failKind: KIND.CORE_NOT_READY }),
    rec('mid', -1, { failKind: KIND.CORE_NOT_READY }),
    rec('slow', -1, { failKind: KIND.CORE_NOT_READY }),
  ], first, ['fast', 'mid', 'slow']);
  eq(second.orderedNames(['fast', 'mid', 'slow']), before,
    'channel failure must not change the order');
  eq(second.orderedNames(['slow', 'mid', 'fast']), ['fast', 'mid', 'slow'],
    'order still derived from the carried verdicts');

  // 第三轮：真的都失败了 → 才允许变红
  const third = NodeSortSnapshot.buildAuto(1_200_000, [
    rec('fast', -1, { failKind: KIND.TIMEOUT, lastOk: false }),
    rec('mid', -1, { failKind: KIND.TIMEOUT, lastOk: false }),
    rec('slow', -1, { failKind: KIND.TIMEOUT, lastOk: false }),
  ], second, ['fast', 'mid', 'slow']);
  eq(third.orderedNames(['fast', 'mid', 'slow']).length, 3, 'all present');
  eq(third.recordFor('fast').latency, -1, 'real failures now recorded');
});

fs.rmSync(stage, { recursive: true, force: true });
console.log(`\nNode-sort persistence verification: ${passed} passed, ${failed} failed (EXEC real module; no device).`);
if (failures.length > 0) {
  console.log('Failures:');
  for (const f of failures) console.log(`  - ${f}`);
}
if (failed > 0) process.exitCode = 1;
