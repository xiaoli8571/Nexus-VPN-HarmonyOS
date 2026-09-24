// probe_relay.mjs — UTF-8 安全地测中转 http 节点 + 一个 vless + 一个 hy2，并抓内核日志
const BASE = 'http://127.0.0.1:19090';
const SECRET = process.argv[2];
const H = { Authorization: `Bearer ${SECRET}` };
const list = await (await fetch(`${BASE}/proxies`, { headers: H })).json();
const all = Object.entries(list.proxies);
const httpNodes = all.filter(([, v]) => v.type === 'Http');
const vlessNodes = all.filter(([, v]) => v.type === 'Vless');
const hy2Nodes = all.filter(([, v]) => v.type === 'Hysteria2');
console.log(`Http=${httpNodes.length} Vless=${vlessNodes.length} Hy2=${hy2Nodes.length}`);
// 内核日志流
const logs = [];
try {
  const ws = new WebSocket('ws://127.0.0.1:19090/logs?token=' + encodeURIComponent(SECRET));
  ws.onmessage = (e) => logs.push(String(e.data));
  ws.onerror = (e) => logs.push('WS_ERR ' + (e?.message || ''));
  await new Promise((r) => setTimeout(r, 400));
} catch (e) { console.log('ws fail', e.message); }
async function delay(name) {
  const url = `${BASE}/proxies/${encodeURIComponent(name)}/delay?timeout=8000&url=${encodeURIComponent('http://www.gstatic.com/generate_204')}`;
  const t = Date.now();
  try {
    const r = await fetch(url, { headers: H, signal: AbortSignal.timeout(15000) });
    const b = await r.text();
    return `${r.status} +${Date.now() - t}ms ${b.substring(0, 100)}`;
  } catch (e) { return `ERR +${Date.now() - t}ms ${e.message}`; }
}
console.log('--- relay http nodes ---');
for (const [name] of httpNodes.slice(0, 3)) console.log(`${name}: ${await delay(name)}`);
console.log('--- vless nodes ---');
for (const [name] of vlessNodes.slice(0, 3)) console.log(`${name}: ${await delay(name)}`);
console.log('--- hy2 ---');
for (const [name] of hy2Nodes.slice(0, 2)) console.log(`${name}: ${await delay(name)}`);
await new Promise((r) => setTimeout(r, 600));
console.log('--- core logs ---');
for (const l of logs.slice(0, 40)) console.log(l.substring(0, 260));
if (logs.length === 0) console.log('(none)');
