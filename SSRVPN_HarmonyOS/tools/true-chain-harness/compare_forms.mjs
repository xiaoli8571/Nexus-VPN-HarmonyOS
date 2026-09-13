// tools/true-chain-harness/compare_forms.mjs
// 1) 同一订阅在「Clash YAML」（app 首选 UA 得到）与「base64 链接列表」（v2rayN/Shadowrocket 用户代理得到）里的节点数对比
// 2) 指纹重复组的原始条目（password/uuid 等敏感值脱敏），判断去重是否误伤
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const audit = join(repo, '..', '_audit');
const G = (n) => pathToFileURL(join(here, 'generated', n)).href;
const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SsrCodec, ProxyNode } = await import(G('ProxyNode.ts'));

const SCHEMES = ['ssr://', 'ss://', 'vless://', 'vmess://', 'trojan://', 'hysteria2://', 'hy2://',
  'tuic://', 'anytls://', 'hysteria://', 'socks5://', 'http://'];

/** 独立计数：链接文本里的节点链接行数（非 YamlMerger） */
function countLinks(text) {
  let body = text.trim();
  if (!/:\/\//.test(body.slice(0, 300))) {
    const cleaned = body.replace(/\s+/g, '');
    if (/^[A-Za-z0-9+/=_-]+$/.test(cleaned)) {
      const dec = SsrCodec.decodeBase64Url(cleaned);
      if (dec.length > 0) body = dec;
    }
  }
  const lines = body.split(/\r?\n/).map((l) => l.trim()).filter((l) => l.length > 0);
  const byScheme = {};
  let total = 0;
  for (const l of lines) {
    const hit = SCHEMES.find((s) => l.toLowerCase().startsWith(s));
    if (hit) { total++; byScheme[hit] = (byScheme[hit] || 0) + 1; }
  }
  const header = lines.filter((l) => !SCHEMES.some((s) => l.toLowerCase().startsWith(s))).slice(0, 3);
  return { total, byScheme, header };
}

const uaDir = join(audit, 'input', 'ua');
const files = readdirSync(uaDir);
const bySub = new Map();
for (const f of files) {
  const [sub, ua] = f.replace(/\.txt$/, '').split('__');
  if (!bySub.has(sub)) bySub.set(sub, []);
  bySub.get(sub).push({ ua, file: join(uaDir, f) });
}
for (const [sub, list] of bySub) {
  console.log(`\n===== ${sub} =====`);
  for (const it of list) {
    const body = readFileSync(it.file, 'utf8');
    const clash = YamlMerger.proxyItemGroups(body).length;
    const links = countLinks(body);
    console.log(`  ${it.ua.padEnd(22)} clash条目=${String(clash).padStart(3)}  链接行=${String(links.total).padStart(3)}  ${JSON.stringify(links.byScheme)}  bytes=${Buffer.byteLength(body)}`);
  }
}

// 指纹重复组原始条目（脱敏）
const maskItem = (lines) => lines.join('\n')
  .replace(/(password|uuid|psk|private-key|public-key|short-id)(\s*:\s*)("[^"]*"|'[^']*'|[^,}\n]+)/g,
    (_m, k, sep, v) => `${k}${sep}"<len=${v.trim().replace(/^["']|["']$/g, '').length}>"`)
  .replace(/(server|sni|servername)(\s*:\s*)("[^"]*"|'[^']*'|[^,}\n]+)/g,
    (_m, k, sep, v) => `${k}${sep}"<masked>"`);
for (const [sub, list] of bySub) {
  const body = readFileSync(list[0].file, 'utf8');
  const groups = YamlMerger.proxyItemGroups(body);
  if (groups.length === 0) continue;
  const byFp = new Map();
  for (const g of groups) {
    let p = null;
    try { p = YamlMerger.parseProxyItem(g); } catch (e) { continue; }
    if (!p) continue;
    const fp = YamlMerger.identityFingerprint(p);
    if (!byFp.has(fp)) byFp.set(fp, []);
    byFp.get(fp).push(g);
  }
  for (const [, items] of byFp) {
    if (items.length < 2) continue;
    console.log(`\n--- ${sub}: 指纹重复组（${items.length} 条，前 2 条原始内容如下，已脱敏） ---`);
    for (const it of items.slice(0, 2)) console.log(maskItem(it));
  }
}
void ProxyNode;
