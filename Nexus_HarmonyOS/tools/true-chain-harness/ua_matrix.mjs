// tools/true-chain-harness/ua_matrix.mjs
// 1) 同一订阅在不同 UA 下返回的条目数是否不同（UA 选择造成的少节点）
// 2) 同一 UA 重复拉取是否返回不同内容（面板轮换）
// 3) 打印指纹重复组的「差异键」（值全部脱敏），用于判断 merge 去重是否误伤
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const audit = join(repo, '..', '_audit');
const { YamlMerger } = await import(pathToFileURL(join(here, 'generated', 'YamlMerger.ts')).href);
const { SubscriptionFetchPolicy } = await import(pathToFileURL(join(here, 'generated', 'SubscriptionFetchPolicy.ts')).href)
  .catch(() => ({ SubscriptionFetchPolicy: null }));

const subsPath = join(audit, 'device', 'extracted', 'subscriptions_json.txt');
const subs = JSON.parse(readFileSync(subsPath, 'utf8')).filter((s) => !s.url.startsWith('local://'));
// UA 链直接从真实源码 SubscriptionFetchPolicy.ets 里抽出（AppInfo.version() 以占位版本号替换）
const policySrc = readFileSync(join(repo, 'entry/src/main/ets/commons/services/SubscriptionFetchPolicy.ets'), 'utf8');
const uaMatch = policySrc.match(/export const UA_CHAIN: string\[\] = \[([\s\S]*?)\];/);
const uaExpr = uaMatch[1].replace(/AppInfo\.version\(\)/g, "'0.0.0'");
const UA_CHAIN = Function(`return [${uaExpr}];`)();
void SubscriptionFetchPolicy;
console.log('App UA 链:', JSON.stringify(UA_CHAIN));

const mask = (v) => (v.length <= 6 ? v : `${v.slice(0, 2)}…${v.slice(-2)}`);

async function fetchWith(url, ua) {
  const res = await fetch(url, { headers: { 'User-Agent': ua, Accept: '*/*' } });
  const body = await res.text();
  return { status: res.status, body };
}

function fingerprintGroups(body) {
  const groups = YamlMerger.proxyItemGroups(body);
  const byFp = new Map();
  for (const g of groups) {
    let p = null;
    try { p = YamlMerger.parseProxyItem(g); } catch (e) { continue; }
    if (!p) continue;
    const fp = YamlMerger.identityFingerprint(p);
    if (!byFp.has(fp)) byFp.set(fp, []);
    byFp.get(fp).push(g);
  }
  return { groups, byFp };
}

/** 逐行抽取 key: value 对（仅审计差异键，值脱敏） */
function keyValues(itemLines) {
  const out = new Map();
  const text = itemLines.join(' ');
  const re = /([A-Za-z][A-Za-z0-9_-]*)\s*:\s*(?:"([^"]*)"|'([^']*)'|\{([^}]*)\}|\[([^\]]*)\]|([^,}\]]+))/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const key = m[1];
    const val = (m[2] ?? m[3] ?? m[4] ?? m[5] ?? m[6] ?? '').trim();
    if (!out.has(key)) out.set(key, val);
  }
  return out;
}

mkdirSync(join(audit, 'input', 'ua'), { recursive: true });
for (const s of subs) {
  const safe = s.name.replace(/[^\w\u4e00-\u9fa5.-]/g, '_');
  console.log(`\n===== ${s.name} =====`);
  const counts = [];
  for (const ua of UA_CHAIN) {
    try {
      const r = await fetchWith(s.url, ua);
      const g = YamlMerger.proxyItemGroups(r.body);
      const byKind = g.length > 0 ? 'clash-yaml' : (/^[A-Za-z0-9+/=_\-\s]+$/.test(r.body.trim().slice(0, 300)) ? 'base64' : 'other');
      counts.push(`${ua}=${r.status}/${g.length}(${byKind})`);
      writeFileSync(join(audit, 'input', 'ua', `${safe}__${ua.replace(/[^\w.-]/g, '_')}.txt`), r.body, 'utf8');
    } catch (e) {
      counts.push(`${ua}=ERR`);
    }
  }
  console.log('  UA 矩阵: ' + counts.join('  '));
  // 同 UA 重复
  const again = await fetchWith(s.url, UA_CHAIN[0]);
  const g1 = YamlMerger.proxyItemGroups(readFileSync(join(audit, 'input', 'ua', `${safe}__${UA_CHAIN[0].replace(/[^\w.-]/g, '_')}.txt`), 'utf8')).length;
  const g2 = YamlMerger.proxyItemGroups(again.body).length;
  console.log(`  同 UA 再拉一次: ${g1} -> ${g2} ${g1 === g2 ? '(稳定)' : '(内容变动)'}`);
  // 指纹重复组差异
  const { groups, byFp } = fingerprintGroups(again.body);
  let dupGroups = 0; const diffs = [];
  for (const [, items] of byFp) {
    if (items.length < 2) continue;
    dupGroups++;
    const kvA = keyValues(items[0]);
    const kvB = keyValues(items[1]);
    const keys = new Set([...kvA.keys(), ...kvB.keys()]);
    const different = [];
    for (const k of keys) {
      const a = kvA.get(k) ?? '(缺失)';
      const b = kvB.get(k) ?? '(缺失)';
      if (a !== b) different.push(`${k}:${mask(a)}|${mask(b)}`);
    }
    diffs.push({ count: items.length, names: items.map((it) => keyValues(it).get('name') ?? '?'), differentKeys: different });
  }
  console.log(`  条目 ${groups.length}，指纹重复组 ${dupGroups}`);
  for (const d of diffs) {
    console.log(`   组 x${d.count} 名称=${JSON.stringify(d.names)} 差异键=[${d.differentKeys.join(', ') || '无(整条内容完全一致)'}]`);
  }
}
