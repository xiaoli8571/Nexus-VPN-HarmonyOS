#!/usr/bin/env node
/**
 * 延迟结果存储回归（运行时，非源码断言）。
 *
 * 把 `LatencyState.ets` / `LatencyController.ets` 按 .ts 暂存到临时目录后直接 import，
 * 真实驱动状态机与存储（Node 24 的 type-stripping 只接受可擦除语法，所以这两个文件
 * 必须避免 `enum`；LatencyState 因此用 class + static readonly）。
 *
 * 覆盖（延迟测试重做后新增的语义）：
 *  1. 旧数字入口的兼容语义：`set(n, >=1)` → 实测；`set(n, -1)` → 超时；`set(n, -2)` → 未测
 *  2. 五态可区分：未测**不是**超时（旧实现把 -2 也画成"超时"）
 *  3. `latencyFor` 兼容视图：TIMEOUT/FAILED → -1，UNTESTED/TESTING/CANCELLED → null
 *  4. 过期结果保留但可判旧（LatencyPolicy.isStale）
 *  5. retainOnly 回收已消失节点，且只在真正删除时通知
 *  6. `delay == 0` 绝不当有效延迟（mihomo 用 0 表示失败）
 *  7. 排序：失败**永不排最前**，实测按延迟升序
 *  8. 组对象与内建项必须被过滤（实测 PROXY.all 里混着 14 个组条目）
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const appRoot = resolve(import.meta.dirname, '..');
const services = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const sandbox = join(tmpdir(), 'ssrvpn-latency-cache-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

/** 暂存一个 .ets 为 .ts，并把无扩展名的相对 import 补成 .ts（Node ESM 要求显式扩展名） */
function stage(fileName) {
  const src = readFileSync(join(services, fileName + '.ets'), 'utf8')
    .replace(/from '(\.\/[A-Za-z0-9_]+)'/g, "from '$1.ts'");
  writeFileSync(join(sandbox, fileName + '.ts'), src, 'utf8');
}

stage('LatencyState');
stage('LatencyController');

const checks = [];
function check(label, ok) {
  checks.push([label, !!ok]);
}

try {
  const { LatencyController } = await import(pathToFileURL(join(sandbox, 'LatencyController.ts')).href);
  const { LatencyState, LatencyPolicy, LatencyRecord, LatencyChannel } =
    await import(pathToFileURL(join(sandbox, 'LatencyState.ts')).href);

  // ---- 1/2/3 兼容入口与五态 ----
  LatencyController.clearAll();
  LatencyController.set('active-a', 31);
  LatencyController.set('stale-b', 92);
  LatencyController.set('active-c', -1);
  LatencyController.set('untested-d', -2);
  check('set(>=1) 记为实测', LatencyController.latencyFor('active-a') === 31);
  check('set(-1) 记为超时', LatencyController.latencyFor('active-c') === -1);
  check('set(-1) 状态是 TIMEOUT', LatencyController.stateFor('active-c') === LatencyState.TIMEOUT);
  check('set(-2) 状态是 UNTESTED（不是超时）',
    LatencyController.stateFor('untested-d') === LatencyState.UNTESTED);
  check('未测节点的 latencyFor 是 null（UI 显示 --）',
    LatencyController.latencyFor('untested-d') === null);
  check('未测节点不产生"超时"文案', LatencyPolicy.stateText(LatencyState.UNTESTED) === '--');
  check('超时文案是「超时」', LatencyPolicy.stateText(LatencyState.TIMEOUT) === '超时');
  check('失败文案是「失败」（不与超时合并）', LatencyPolicy.stateText(LatencyState.FAILED) === '失败');

  // markTesting 不产生数值结论
  LatencyController.markTesting('testing-e');
  check('markTesting → TESTING 状态', LatencyController.stateFor('testing-e') === LatencyState.TESTING);
  check('markTesting 期间 latencyFor 为 null（不显示旧数字）',
    LatencyController.latencyFor('testing-e') === null);

  // ---- 4 过期判定 ----
  const fresh = LatencyRecord.measured('n1', 50, LatencyChannel.CORE, Date.now());
  const old = LatencyRecord.measured('n2', 50, LatencyChannel.CORE, Date.now() - LatencyPolicy.STALE_MS - 1000);
  check('新鲜结果不判旧', LatencyPolicy.isStale(fresh, Date.now()) === false);
  check('超阈值结果判旧（灰显但不删除）', LatencyPolicy.isStale(old, Date.now()) === true);
  check('未测结果不判旧（无时间戳可判）',
    LatencyPolicy.isStale(LatencyRecord.untested('n3'), Date.now()) === false);

  // ---- 5 retainOnly ----
  LatencyController.retainOnly(['active-a', 'active-c', 'untested-d', 'testing-e']);
  check('已消失节点被回收', LatencyController.latencyFor('stale-b') === null);
  check('保留节点数值不变', LatencyController.latencyFor('active-a') === 31);

  // ---- 6 delay==0 不是有效延迟 ----
  check('0ms 不是有效延迟（mihomo 用 0 表示失败）', LatencyPolicy.isValidDelay(0) === false);
  check('负数不是有效延迟', LatencyPolicy.isValidDelay(-1) === false);
  check('1ms 是有效延迟', LatencyPolicy.isValidDelay(1) === true);
  check('65535（mihomo 的"没测过"哨兵）不是有效延迟',
    LatencyPolicy.isValidDelay(65535) === false);

  // ---- 7 分类与排序 ----
  check('200+delay 归为实测',
    LatencyPolicy.classify(200, 88, false) === LatencyState.MEASURED);
  check('200+delay=0 归为失败（不能当 0ms 很快）',
    LatencyPolicy.classify(200, 0, false) === LatencyState.FAILED);
  check('504 归为超时', LatencyPolicy.classify(504, -1, false) === LatencyState.TIMEOUT);
  check('503 归为失败', LatencyPolicy.classify(503, -1, false) === LatencyState.FAILED);
  check('404（节点已不存在）归为失败', LatencyPolicy.classify(404, -1, false) === LatencyState.FAILED);
  check('客户端中止归为已取消（不是节点结论）',
    LatencyPolicy.classify(0, -1, true) === LatencyState.CANCELLED);

  const measured = LatencyRecord.measured('m', 80, LatencyChannel.CORE, Date.now());
  const slow = LatencyRecord.measured('s', 400, LatencyChannel.CORE, Date.now());
  const offline = LatencyRecord.measured('o', 30, LatencyChannel.OFFLINE, Date.now());
  const untested = LatencyRecord.untested('u');
  const timedOut = LatencyRecord.failed('t', LatencyState.TIMEOUT, Date.now());
  const failed = LatencyRecord.failed('f', LatencyState.FAILED, Date.now());
  const order = [failed, timedOut, untested, offline, slow, measured].sort(LatencyPolicy.compare);
  check('排序：实测最快在最前', order[0].name === 'm');
  check('排序：实测慢的排在实测快的之后', order[1].name === 's');
  check('排序：离线粗略排在实测之后', order[2].name === 'o');
  check('排序：未测在失败之前', order.indexOf(untested) < order.indexOf(timedOut));
  check('排序：失败**永不排最前**', order[0].state !== LatencyState.FAILED && order[0].state !== LatencyState.TIMEOUT);
  check('排序：失败在最后', order[order.length - 1].name === 'f');
  check('离线结果带 OFFLINE 状态（UI 显示 ≈ 前缀）', offline.state === LatencyState.OFFLINE);

  // ---- 8 组对象 / 内建项过滤 ----
  check('Selector 组不可作为被测节点', LatencyPolicy.isTestableType('Selector') === false);
  check('URLTest 组不可测', LatencyPolicy.isTestableType('URLTest') === false);
  check('Fallback 组不可测', LatencyPolicy.isTestableType('Fallback') === false);
  check('LoadBalance 组不可测', LatencyPolicy.isTestableType('LoadBalance') === false);
  check('Relay 组不可测', LatencyPolicy.isTestableType('Relay') === false);
  check('Direct 内建项不可测', LatencyPolicy.isTestableType('Direct') === false);
  check('Reject 内建项不可测', LatencyPolicy.isTestableType('Reject') === false);
  check('Shadowsocks 真实节点可测', LatencyPolicy.isTestableType('Shadowsocks') === true);
  check('Hysteria2 真实节点可测', LatencyPolicy.isTestableType('Hysteria2') === true);
  check('Vless 真实节点可测', LatencyPolicy.isTestableType('Vless') === true);
  check('DIRECT 名字是内建项', LatencyPolicy.isBuiltinNode('DIRECT') === true);
  check('REJECT-DROP 名字是内建项', LatencyPolicy.isBuiltinNode('REJECT-DROP') === true);
  check('普通节点名不是内建项', LatencyPolicy.isBuiltinNode('hy2台湾01') === false);
} finally {
  rmSync(sandbox, { recursive: true, force: true });
}

let failedCount = 0;
for (const [label, ok] of checks) {
  if (!ok) {
    failedCount++;
  }
  console.log((ok ? 'PASS ' : 'FAIL ') + label);
}
console.log(`\n${checks.length - failedCount}/${checks.length} passed, ${failedCount} failed`);
if (failedCount > 0) {
  process.exitCode = 1;
}
