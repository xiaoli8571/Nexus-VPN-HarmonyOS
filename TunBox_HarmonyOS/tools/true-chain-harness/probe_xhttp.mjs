// probe_xhttp.mjs — 诊断脚本：真实链路(生成TS)跑订阅 → 输出最终代理行统计 + 可运行配置
// 用法: node --experimental-transform-types probe_xhttp.mjs <body文件> <输出config文件>
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const G = (n) => pathToFileURL(join(here, 'generated', n)).href;
const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SubscriptionService, ProxyNodeJson } = await import(G('SubscriptionService.ts'));
const { ClashConfigGenerator } = await import(G('ClashConfigGenerator.ts'));

const bodyPath = process.argv[2];
const outPath = process.argv[3] ?? join(here, 'probe_config.yaml');
const body = readFileSync(bodyPath, 'utf8');

const merged = YamlMerger.merge([body], 'probe', '');
const nodes = SubscriptionService['mergedToNodes'](merged, 'probe-sub');
const json = JSON.parse(JSON.stringify(nodes.map((n) => ProxyNodeJson.fromNode(n))));
const restored = SubscriptionService.mapNodes(json);

const lines = [];
const names = [];
let xhttpWith = 0; let xhttpWithout = 0; let realityCount = 0; let dropped = 0;
for (const n of restored) {
  const line = ClashConfigGenerator.proxyYamlLine(n);
  if (line.length === 0) { dropped++; continue; }
  lines.push(line);
  const m = line.match(/name: "((?:[^"\\]|\\.)*)"/);
  if (m) names.push(m[1]);
  if (n.proxyType === 'vless' && n.network === 'xhttp') {
    if (line.includes('xhttp-opts')) { xhttpWith++; } else { xhttpWithout++; }
  }
  if (n.realityPublicKey.length > 0 || n.realityShortId.length > 0) { realityCount++; }
}
const redact = (l) => l
  .replace(/(uuid|password): "(?:[^"\\]|\\.)*"/g, '$1: "***"')
  .replace(/public-key: "(?:[^"\\]|\\.)*"/g, 'public-key: "***"');
console.log(`restored=${restored.length} kept=${lines.length} dropped=${dropped}`);
console.log(`vless-xhttp: with-opts=${xhttpWith} without-opts=${xhttpWithout} | reality=${realityCount}`);
for (const l of lines.filter((x) => x.includes('xhttp-opts')).slice(0, 2)) {
  console.log('SAMPLE:', redact(l).substring(0, 600));
}
const byType = {};
for (const l of lines) {
  const t = (l.match(/type: ([a-z0-9-]+)/) || [])[1] || '?';
  byType[t] = (byType[t] || 0) + 1;
}
console.log('config type distribution:', JSON.stringify(byType));

const groupList = names.map((n) => `"${n}"`).join(', ');
const config = `mixed-port: 17891
external-controller: 127.0.0.1:19091
secret: "probe-secret"
mode: global
log-level: info
unified-delay: true
tcp-concurrent: true
proxies:
${lines.join('\n')}
`;
writeFileSync(outPath, config);
console.log(`config written: ${outPath} (proxies=${lines.length}, names=${names.length})`);
