// tools/true-parser-harness/harness.mjs
// 用**真实 ArkTS 源码**（YamlMerger.ets -> YamlMerger.ts, 见 prepare.mjs）在 Node 中
// 复现「样本 22 条 proxy 只解析出 2 个节点」，逐条输出结果并断言最终节点数。
//
// 运行: node tools/true-parser-harness/prepare.mjs && node --experimental-strip-types tools/true-parser-harness/harness.mjs [yaml路径] [期望节点数]
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const { YamlMerger, MergedProxy } = await import(pathToFileURL(join(here, 'YamlMerger.ts')).href);

const samplePath = process.argv[2]
  || 'C:/Users/xiaoli/Downloads/Telegram Desktop/send_1789219702272_1_自建.yaml';
const expected = process.argv[3] !== undefined ? Number(process.argv[3]) : 21;

const raw = readFileSync(samplePath, 'utf8');

// 1) 取 `proxies:` 到下一个顶层键之间的原始内容（与 App 传入 merge 的语义一致）
function rawProxiesSection(text) {
  const lines = text.split('\n');
  const out = [];
  let inSec = false;
  for (let line of lines) {
    if (line.startsWith('\uFEFF')) line = line.substring(1);
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      const t = line.trim();
      if (t.startsWith('proxies:')) { inSec = true; out.push(line); continue; }
      if (inSec && t.length > 0 && !t.startsWith('#')) break;
    }
    if (inSec) out.push(line);
  }
  return out.join('\n');
}

const section = rawProxiesSection(raw);
console.log(`[input] sample=${samplePath}`);
console.log(`[input] proxies-section chars=${section.length} lines=${section.split('\n').length}`);

const groups = YamlMerger.proxyItemGroups(section);
console.log(`[input] proxyItemGroups() => ${groups.length} 条\n`);

// 2) 逐条走真实 parseProxyItem
const rows = [];
for (let i = 0; i < groups.length; i++) {
  const g = groups[i];
  const head = g[0].replace(/^\s*-\s*/, '').substring(0, 60);
  let status = '';
  let detail = '';
  let parsed = null;
  try {
    parsed = YamlMerger.parseProxyItem(g);
    if (parsed === null) { status = 'NULL'; detail = '返回 null'; }
    else {
      status = 'OK';
      detail = `type=${parsed.type} name=${parsed.name} server=${parsed.server} port=${parsed.port}`
        + ` extras=${YamlMerger.parseExtraOpts(parsed.extraOpts).length}项`;
    }
  } catch (e) {
    const kind = e && e.constructor ? e.constructor.name : typeof e;
    status = 'THROW';
    detail = `[${kind}] ${e && e.message ? e.message : String(e)}`;
  }
  rows.push({ i: i + 1, status, detail, parsed });
  console.log(`#${String(i + 1).padStart(2)} ${status.padEnd(5)} ${detail}`);
  void head;
}

const okCount = rows.filter((r) => r.status === 'OK').length;
console.log(`\n[parseProxyItem] OK=${okCount} THROW=${rows.filter((r) => r.status === 'THROW').length}`
  + ` NULL=${rows.filter((r) => r.status === 'NULL').length}`);

// 3) 走真实 merge 全流程（含指纹去重 + 名称分配 + 限额）
YamlMerger.resetSkipStats();
const merged = YamlMerger.merge([section], '本地:样本', '');
console.log(`[merge] 可导入节点数 = ${merged.length}`
  + ` (lastSkipped=${YamlMerger.lastSkippedCount} types=${YamlMerger.lastSkippedTypes || '-'})`);
for (const m of merged) {
  console.log(`   - ${m.name} | type=${m.type} | ${m.server}:${m.port}`);
}

// 4) 指纹唯一性（排查 identityFingerprint 冲突导致的去重）
const fps = new Map();
for (const m of merged) {
  const fp = YamlMerger.identityFingerprint(m);
  fps.set(fp, (fps.get(fp) || 0) + 1);
}
const dupFp = [...fps.values()].filter((v) => v > 1).length;
console.log(`[merge] 指纹冲突组 = ${dupFp}（0 = 无因指纹被误判重复的节点）`);
const names = merged.map((m) => m.name);
const distinct = new Set(names).size;
console.log(`[merge] 名称唯一性 = ${distinct}/${names.length}（uniqueProxyName 只会改名, 不会丢节点）`);

// 5) mergedToNodes 等价门槛: server 非空且 port>0（SubscriptionService.mergedToNodes L536）
const importable = merged.filter((m) => m.server.length > 0 && m.port > 0).length;
console.log(`[mergedToNodes] server/port 有效 = ${importable}`);

// 6) 结构化槽位抽查: 修复前这些字段全部为空(uuid/password/... 被塞进 extraOpts)
const probe = merged.filter((m) => ['vless', 'hysteria2', 'anytls', 'tuic'].includes(m.type));
for (const m of probe.slice(0, 4).concat(probe.slice(-2))) {
  console.log(`[fields] ${m.name} type=${m.type} uuid=${m.uuid ? '有' : '-'}`
    + ` password=${m.password ? '有' : '-'} servername=${m.servername || '-'}`
    + ` wsPath=${m.wsPath || '-'} wsHost=${m.wsHost || '-'}`
    + ` realityPk=${m.realityPublicKey ? '有' : '-'} flow=${m.flow || '-'}`
    + ` alpn=${m.alpnList || '-'} up=${m.hyUp || '-'} extraKeys=`
    + `${YamlMerger.parseExtraOpts(m.extraOpts).map((p) => p[0]).join('/') || '-'}`);
}

// 7) yaml_cache 往返: merge -> toYaml -> 重新 merge 必须仍是同样可导入条数
const cached = YamlMerger.toYaml(merged);
const remixed = YamlMerger.merge([cached], '本地:样本', '');
console.log(`[roundtrip] toYaml(${merged.length}) -> re-merge = ${remixed.length}`);

console.log(`\n[ASSERT] merge 结果 ${merged.length} vs 期望 ${expected} => `
  + `${merged.length === expected ? 'PASS' : 'FAIL'}`);
if (merged.length !== expected || remixed.length !== expected) {
  console.log('[ASSERT] 失败: 真实源码解析产出与期望不一致');
  process.exit(1);
}
void MergedProxy;
