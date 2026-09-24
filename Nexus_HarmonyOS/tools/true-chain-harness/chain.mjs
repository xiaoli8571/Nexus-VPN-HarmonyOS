// tools/true-chain-harness/chain.mjs
// 用**真实 .ets 源码**（prepare.mjs 生成）跑完整导入链路，输出逐层节点数口径。
//
// 用法:
//   node --experimental-transform-types tools/true-chain-harness/chain.mjs file <body文件> [本地|订阅|链接]
//   node --experimental-transform-types tools/true-chain-harness/chain.mjs device <提取目录>
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const G = (n) => pathToFileURL(join(here, 'generated', n)).href;

const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SubscriptionParser } = await import(G('SubscriptionParser.ts'));
const { SubscriptionService, ProxyNodeJson } = await import(G('SubscriptionService.ts'));
const { ClashConfigGenerator } = await import(G('ClashConfigGenerator.ts'));
const { Subscription } = await import(G('Subscription.ts'));
const { ProxyNode } = await import(G('ProxyNode.ts'));

/** 独立实现（非 YamlMerger）的原始条目计数：proxies 节内最小缩进的 "- " 行数 */
function rawEntryCount(body) {
  const lines = body.split('\n');
  let inSec = false;
  let minIndent = -1;
  const items = [];
  for (const line of lines) {
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      const t = line.trim();
      if (t.startsWith('proxies:')) { inSec = true; continue; }
      if (inSec && t.length > 0 && !t.startsWith('#')) break;
      continue;
    }
    if (!inSec) continue;
    const m = line.match(/^(\s*)-\s/);
    if (!m) continue;
    const indent = m[1].length;
    if (minIndent < 0 || indent < minIndent) minIndent = indent;
    items.push({ indent, line });
  }
  return items.filter((it) => it.indent === minIndent).length;
}

function perItemParse(itemLines) {
  const out = { ok: 0, throw: 0, null: 0, throwMsgs: [], nullHeads: [] };
  for (const g of itemLines) {
    try {
      const p = YamlMerger.parseProxyItem(g);
      if (p === null) { out.null++; out.nullHeads.push(g[0].trim().substring(0, 60)); } else { out.ok++; }
    } catch (e) {
      out.throw++;
      out.throwMsgs.push(`${e?.constructor?.name ?? 'Error'}: ${e?.message ?? String(e)}`);
    }
  }
  return out;
}

/** 计数 map: 只输出名称/类型/数量，绝不输出 uuid/password/uri */
function countBy(arr, keyFn) {
  const m = new Map();
  for (const a of arr) {
    const k = keyFn(a);
    m.set(k, (m.get(k) || 0) + 1);
  }
  return Object.fromEntries([...m.entries()].sort((x, y) => y[1] - x[1]));
}

/**
 * 完整逐层口径。entry: 'url' | 'local' | 'links'
 * store: 可选 preferences 替身（用于 yaml_cache/持久化往返）
 */
export async function analyzeBody(body, opts = {}) {
  const name = opts.name ?? 'audit';
  const id = opts.id ?? 'audit-sub';
  const store = opts.store ?? null;
  const out = { name, bytes: Buffer.byteLength(body), chars: body.length };

  // L1 原始条目（独立计数）
  out.rawEntries = rawEntryCount(body);
  // L2 YamlMerger.proxyItemGroups 条目
  const groups = YamlMerger.proxyItemGroups(body);
  out.groups = groups.length;
  // L3 逐条 parseProxyItem
  YamlMerger.resetSkipStats();
  const per = perItemParse(groups);
  out.parseOk = per.ok;
  out.parseThrow = per.throw;
  out.parseNull = per.null;
  out.parseThrowSamples = [...new Set(per.throwMsgs)].slice(0, 6);
  out.skippedTypes = YamlMerger.lastSkippedTypes;
  // L4 merge（指纹去重/改名/限额）
  YamlMerger.resetSkipStats();
  let merged = [];
  let mergeError = '';
  try {
    merged = YamlMerger.merge([body], name, '');
  } catch (e) {
    mergeError = `${e?.constructor?.name}: ${e?.message}`;
  }
  out.mergeError = mergeError;
  out.merged = merged.length;
  out.mergeSkippedUnsupported = YamlMerger.lastSkippedCount;
  // 真实的「因内容指纹相同被去重」条数（逐条解析后比较指纹）
  const fpsRaw = new Set(); let dup = 0; let parsedOk = 0;
  for (const it of groups) {
    try {
      const p = YamlMerger.parseProxyItem(it);
      if (p !== null) {
        parsedOk++;
        const fp = YamlMerger.identityFingerprint(p);
        if (fpsRaw.has(fp)) { dup++; }
        fpsRaw.add(fp);
      }
    } catch (e) { /* 上面的 parseThrow 已统计 */ }
  }
  out.parsedOkIndependent = parsedOk;
  out.dupByFingerprint = dup;
  out.mergeAccounting = `groups(${groups.length}) = merged(${out.merged}) + invalid/skipped(${out.parseThrow + out.parseNull}) + dupFingerprint(${dup})`;

  // L5 mergedToNodes（真实私有静态方法：server/port 门槛）
  const nodes = SubscriptionService['mergedToNodes'](merged, id);
  out.mergedToNodes = nodes.length;
  out.droppedByServerPort = out.merged - out.mergedToNodes;
  // L6 持久化 → 恢复（nodes_json → mapNodes）
  const json = JSON.parse(JSON.stringify(nodes.map((n) => ProxyNodeJson.fromNode(n))));
  const restored = SubscriptionService.mapNodes(json);
  out.persistedRecords = json.length;
  out.restoredAfterReload = restored.length;
  out.droppedOnReload = json.length - restored.length;
  // L7 去重命名
  const svc = new SubscriptionService();
  svc.nodes = restored;
  const renamed = svc.ensureUniqueNames();
  out.renamed = renamed ? 1 : 0;
  out.afterRename = svc.nodes.length;
  // L8 生成核心配置（真实 proxyYamlLine）
  let kept = 0;
  const dropReasons = [];
  for (const n of restored) {
    const line = ClashConfigGenerator.proxyYamlLine(n);
    if (line.length > 0) { kept++; } else {
      const t = (n.proxyType || n.type || '').toLowerCase();
      let why = 'unknown';
      if (t === 'ss' || t === 'ssr') { if (!n.method || !n.password) why = 'ss/ssr 缺 cipher/password'; }
      if (t === 'vless' || t === 'vmess') { if (!n.uuid) why = '缺 uuid'; }
      if (t === 'trojan' && !n.password) why = 'trojan 缺 password';
      if (t === 'hysteria2' && !n.password) why = 'hysteria2 缺 password';
      if (!n.name || !n.server || n.port <= 0) why = 'name/server/port 非法';
      if ((t === 'ssr' && (!n.protocol || !n.obfs))) why = 'ssr 缺 protocol/obfs';
      dropReasons.push(`${t || '?'}:${why}`);
    }
  }
  out.configKeptNodes = kept;
  out.droppedAtConfigGen = restored.length - kept;
  out.configDropReasons = countBy(dropReasons, (x) => x);

  // L9 真实服务入口（URL 订阅 / 本地 YAML）：store 为替身或 null
  globalThis.__HARNESS_BODY__ = body;
  if (room(opts.entry, ['url', 'local'])) {
    const service = new SubscriptionService();
    service.store = store;
    service.credStore = null;
    if (opts.entry === 'url') {
      const sub = Subscription.newSubscription(id, name, 'https://example.invalid/sub');
      service.subscriptions = [sub];
      const res = await service.refreshSubscription(id);
      out.serviceStatus = res.status;
      out.serviceNodeCount = res.nodeCount;
      out.serviceNodes = service.nodes.length;
      if (store) { out.yamlCacheEntries = YamlMerger.proxyItemGroups(await store.get(`yaml_cache_${id}`, '')).length; }
    } else {
      const before = service.subscriptions.length;
      const count = await service.addLocalYaml(name + '.yaml', body);
      out.serviceLocalReturn = count;
      out.serviceNodes = service.nodes.length;
      out.serviceSubsAdded = service.subscriptions.length - before;
      out.serviceNodeCount = count;
    }
    out.serviceDiagnostics = JSON.stringify(res0(out));
  }
  return out;
}

function room(a, list) { return a !== undefined && list.includes(a); }
function res0() { return {}; }

function printRow(label, value, extra = '') {
  console.log(`${label.padEnd(34)} ${String(value).padStart(6)}   ${extra}`);
}

async function cmdFile(path, entry) {
  const body = readFileSync(path, 'utf8');
  const store = {
    map: new Map(),
    async get(k, d) { return this.map.has(k) ? this.map.get(k) : d; },
    async put(k, v) { this.map.set(k, v); },
    async flush() {},
  };
  const r = await analyzeBody(body, { entry: entry ?? 'local', name: basename(path), id: 'file-sub', store });
  console.log(`== ${path} (${r.bytes} bytes) entry=${entry ?? 'local'} ==`);
  for (const [k, v] of Object.entries(r)) {
    if (k === 'name') continue;
    console.log(`  ${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`);
  }
  return r;
}

/** 设备提取目录：yaml_cache_<id> 与 nodes_json / subscriptions_json 交叉验证 */
async function cmdDevice(dir) {
  const files = readdirSync(dir);
  const rd = (f) => readFileSync(join(dir, f), 'utf8');
  const subs = JSON.parse(rd('subscriptions_json.txt'));
  const nodes = JSON.parse(rd('nodes_json.txt'));
  const bySub = new Map();
  for (const n of nodes) {
    const k = n.subscriptionId;
    if (!bySub.has(k)) bySub.set(k, []);
    bySub.get(k).push(n);
  }
  console.log('sub(id8)          name                     nodeCount  nodes_json  yamlCacheEntries  cacheParseOK  cacheMerged  cacheNodes  configKept');
  const result = [];
  for (const s of subs) {
    const cacheFile = `yaml_cache_${s.id}.txt`;
    let cacheRaw = null;
    if (files.includes(cacheFile)) cacheRaw = rd(cacheFile);
    const cacheGroups = cacheRaw === null ? -1 : YamlMerger.proxyItemGroups(cacheRaw).length;
    let cacheOk = -1; let cacheMerged = -1; let cacheNodes = -1; let cacheKept = -1; let restored = -1; let dropReload = -1;
    if (cacheRaw !== null) {
      const per = perItemParse(YamlMerger.proxyItemGroups(cacheRaw));
      cacheOk = per.ok;
      const merged = YamlMerger.merge([cacheRaw], s.name, '');
      cacheMerged = merged.length;
      const nn = SubscriptionService['mergedToNodes'](merged, s.id);
      cacheNodes = nn.length;
      // 恢复路径（把真实凭据节点序列化 → mapNodes）
      const json = JSON.parse(JSON.stringify(nn.map((n) => ProxyNodeJson.fromNode(n))));
      const rs = SubscriptionService.mapNodes(json);
      restored = rs.length;
      dropReload = json.length - rs.length;
      let kept = 0;
      for (const n of rs) { if (ClashConfigGenerator.proxyYamlLine(n).length > 0) kept++; }
      cacheKept = kept;
      // 把持久化 JSON 的「真实「凭据被封存」形态」也走一遍：password/uuid 清空后 mapNodes 是否仍然保留
      const sealed = json.map((j) => Object.assign({}, j, { password: '', uuid: '', protocolParam: '', obfsParam: '' }));
      const sealedRestored = SubscriptionService.mapNodes(sealed);
      // 封存后 proxyYamlLine 生成配置的存活数（真机重启后的真实情形）
      let sealedKept = 0;
      for (const n of sealedRestored) { if (ClashConfigGenerator.proxyYamlLine(n).length > 0) sealedKept++; }
      result.push({
        id8: s.id.substring(0, 8), name: s.name, nodeCount: s.nodeCount,
        nodesJson: (bySub.get(s.id) || []).length,
        cacheGroups, cacheOk, cacheMerged, cacheNodes, restored, dropReload,
        cacheKept, sealedKept, sealedRestored: sealedRestored.length,
      });
    } else {
      result.push({
        id8: s.id.substring(0, 8), name: s.name, nodeCount: s.nodeCount,
        nodesJson: (bySub.get(s.id) || []).length,
        cacheGroups, cacheOk, cacheMerged, cacheNodes, restored, dropReload,
        cacheKept: -1, sealedKept: -1, sealedRestored: -1,
      });
    }
  }
  for (const r of result) {
    console.log(`${r.id8.padEnd(10)} ${r.name.padEnd(24)} ${String(r.nodeCount).padStart(9)} ${String(r.nodesJson).padStart(11)} ${String(r.cacheGroups).padStart(17)} ${String(r.cacheOk).padStart(13)} ${String(r.cacheMerged).padStart(12)} ${String(r.cacheNodes).padStart(11)} ${String(r.cacheKept).padStart(10)}`);
  }
  console.log(JSON.stringify(result, null, 1));
  // 类型分布
  console.log('nodes_json proxyType 分布: ' + JSON.stringify(countBy(nodes, (n) => n.proxyType || '(空)')));
  console.log('nodes_json 凭据封存情况: password 非空 ' + nodes.filter((n) => n.password).length
    + ' / uuid 非空 ' + nodes.filter((n) => n.uuid).length + ' / 共 ' + nodes.length);
  return result;
}

const [, , cmd, arg1, arg2] = process.argv;
const isMain = process.argv[1] !== undefined
  && import.meta.url === pathToFileURL(process.argv[1]).href;
if (!isMain) {
  // 被 run_raw.mjs 等脚本 import 时只导出函数
} else if (cmd === 'file') {
  await cmdFile(arg1, arg2);
} else if (cmd === 'device') {
  await cmdDevice(arg1);
} else {
  console.log('usage: chain.mjs file <path> [url|local|links] | chain.mjs device <dir>');
  process.exit(2);
}
void ProxyNode;
