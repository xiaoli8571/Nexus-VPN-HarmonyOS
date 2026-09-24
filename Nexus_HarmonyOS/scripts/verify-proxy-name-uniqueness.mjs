#!/usr/bin/env node
/**
 * 生成配置的「代理名唯一性」验证 —— mihomo 对重名代理是**致命**的。
 *
 * 依据（mihomo 内核源码 config/config.go:900-907）：
 *     for idx, mapping := range proxiesConfig {
 *         ...
 *         return nil, nil, fmt.Errorf("proxy %s is the duplicate name", proxy.Name())
 *     }
 * 即 `proxies:` 里出现两个同名代理时，mihomo 会**拒绝加载整份配置**（不是跳过其中一个）。
 * 对本应用而言 = 用户连不上，且报错发生在内核侧，App 只看到「配置加载失败」。
 *
 * 为什么这里会重名：SubscriptionParser.dedupName 只在**单个订阅内部**去重
 * （它只看本次 parse 累积的 nodes），而配置是由**所有订阅 + provider** 的节点合并
 * 生成的，跨订阅重名没有任何一层兜底。
 *
 * 本套件直接抽出真源码里的 ensureUniqueProxyNames 运行（与本仓 verify-config-sanitize
 * 抽取 sanitizeControlChars 的做法一致），并断言 generate() 在写 proxies 前调用了它。
 *
 * 跑法：node scripts/verify-proxy-name-uniqueness.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genPath = path.join(root, 'entry/src/main/ets/commons/services/ClashConfigGenerator.ets');
const gen = fs.readFileSync(genPath, 'utf8');

let passed = 0;
let failed = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}\n       期望 ${e}\n       实际 ${a}`); }
}

// ── 从真源码抽出 ensureUniqueProxyNames（连注释一起，保证抽到的是真实现） ──────
function grab(src, startMarker, endMarker) {
  const start = src.indexOf(startMarker);
  if (start < 0) throw new Error(`找不到起点: ${startMarker}`);
  const end = src.indexOf(endMarker, start);
  if (end < 0) throw new Error(`找不到终点: ${endMarker}`);
  return src.slice(start, end);
}
const fnSrc = grab(gen,
  'static ensureUniqueProxyNames(nodes: ProxyNode[]): number {',
  '\n  static proxyYamlLine');
// 抽出来的是 ArkTS 源码，`new Function` 只吃 JS：去掉参数/返回值的类型标注。
const fnJs = fnSrc
  .replace(/^static /, '')
  .replace(/\(nodes: ProxyNode\[\]\): number/, '(nodes)')
  .replace(/: string\[\]/g, '')
  .replace(/const used = new Set<string>\(\)/, 'const used = new Set()');
const harness = `
const AppLogger = { warn() {} };
const TAG = 'x';
const ClashConfigGenerator = {
  ${fnJs}
};
return ClashConfigGenerator.ensureUniqueProxyNames;
`;
let ensureUniqueProxyNames = null;
try {
  ensureUniqueProxyNames = new Function(harness)();
} catch (e) {
  console.log(`\nFAILED to extract ensureUniqueProxyNames: ${e && e.message ? e.message : e}`);
  process.exit(1);
}

const N = (name) => ({ name, originalName: name });

console.log('\n[1] 跨订阅重名必须被改名（否则 mihomo 拒绝整份配置）');
{
  const nodes = [N('香港 01'), N('香港 01'), N('日本 01')];
  const renamed = ensureUniqueProxyNames(nodes);
  eq(nodes.map(n => n.name), ['香港 01', '香港 01 2', '日本 01'],
    '第二个同名节点被改名为 "香港 01 2"（首个保留原名）');
  eq(renamed, 1, '返回实际改名数量 1');
  eq(new Set(nodes.map(n => n.name)).size, 3, '改名后名字全局唯一');
}

console.log('\n[2] 幂等：重复调用不得无限追加序号');
{
  const nodes = [N('A'), N('A'), N('A')];
  ensureUniqueProxyNames(nodes);
  const after1 = nodes.map(n => n.name);
  ensureUniqueProxyNames(nodes);
  const after2 = nodes.map(n => n.name);
  eq(after1, ['A', 'A 2', 'A 3'], '三个同名 → A / A 2 / A 3');
  eq(after2, after1, '第二次调用不再改动（幂等）');
}

console.log('\n[3] 不误伤：本来唯一的名字一个都不动');
{
  const nodes = [N('香港 01'), N('日本 01'), N('美国 01')];
  const renamed = ensureUniqueProxyNames(nodes);
  eq(renamed, 0, '无重名时改名数 0');
  eq(nodes.map(n => n.name), ['香港 01', '日本 01', '美国 01'], '名字保持原样');
}

console.log('\n[4] 边界：空名 / 与既有后缀冲突');
{
  const nodes = [N(''), N('')];
  ensureUniqueProxyNames(nodes);
  eq(new Set(nodes.map(n => n.name)).size, 2, '空名节点也被唯一化');

  // "A" 与 "A 2" 同时存在时，第二个 "A" 不能撞上 "A 2"
  const nodes2 = [N('A'), N('A 2'), N('A')];
  ensureUniqueProxyNames(nodes2);
  eq(new Set(nodes2.map(n => n.name)).size, 3,
    `与既有 "A 2" 冲突时继续往后找: ${JSON.stringify(nodes2.map(n => n.name))}`);
  eq(nodes2[1].name, 'A 2', '既有 "A 2" 不被抢走');
}

console.log('\n[5] originalName 保持不变（proxy-groups 按面板原始名引用仍可解析）');
{
  const nodes = [N('香港 01'), N('香港 01')];
  nodes[0].originalName = 'HK-01';
  nodes[1].originalName = 'HK-01';
  ensureUniqueProxyNames(nodes);
  eq(nodes.map(n => n.originalName), ['HK-01', 'HK-01'],
    'originalName 不动 → planProxyGroups 的 originalToDisplay 仍能把组内原始名映射到显示名');
}

console.log('\n[6] 源码契约：generate() 必须在写 proxies 之前调用唯一化');
{
  const proxiesIdx = gen.indexOf("lines.push('proxies:')");
  const callIdx = gen.indexOf('ClashConfigGenerator.ensureUniqueProxyNames(validNodes)');
  ok(proxiesIdx > 0, '找到 proxies: 输出点');
  ok(callIdx > 0, '找到 ensureUniqueProxyNames 调用点');
  ok(callIdx > proxiesIdx && callIdx < gen.indexOf('proxyYamlLine(n)', callIdx),
    '调用发生在写 proxies 之前、且在写第一条 proxy 行之前');
  // 改名前不能已经 emit 过任何 proxy 行，否则旧名字会先落盘
  const emitIdx = gen.indexOf('lines.push(ClashConfigGenerator.proxyYamlLine(n))');
  ok(callIdx < emitIdx, '唯一化先于任何 proxy 行输出');
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
