// probe_phone_core.mjs — 直连手机测速内核：列组、抓 /logs、逐节点 delay
const BASE = 'http://127.0.0.1:19090';
const SECRET = process.argv[2];
const H = { Authorization: `Bearer ${SECRET}` };

const list = await (await fetch(`${BASE}/proxies`, { headers: H })).json();
// 挑测试目标：2 个 vless（xhttp/其他）、1 个中转 http 成员、1 个 hy2
const targets = [];
for (const [name, v] of Object.entries(list.proxies)) {
  if (v.type === 'Vless' && /Cloudflare/i.test(name) && targets.length < 2) {
    targets.push({ name, tag: 'vless-xhttp' });
  }
}
for (const [name, v] of Object.entries(list.proxies)) {
  if (v.type === 'Vless' && /TW|台湾/i.test(name) && targets.length < 3) {
    targets.push({ name, tag: 'vless-other' });
  }
}
for (const [name, v] of Object.entries(list.proxies)) {
  if (v.type === 'Http' && targets.length < 4) {
    targets.push({ name, tag: 'relay-http' });
  }
}
for (const [name, v] of Object.entries(list.proxies)) {
  if (v.type === 'Hysteria2' && targets.length < 5) {
    targets.push({ name, tag: 'hy2' });
  }
}
// 开日志流
const logs = [];
let wsOpen = false;
try {
  const ws = new WebSocket(`ws://127.0.0.1:19090/logs?token=${encodeURIComponent(SECRET)}`);
  ws.onopen = () => { wsOpen = true; };
  ws.onmessage = (e) => { logs.push(String(e.data)); };
  ws.onerror = (e) => { logs.push('WS_ERROR ' + (e && e.message ? e.message : 'unknown')); };
  await new Promise((r) => setTimeout(r, 500));
} catch (e) {
  console.log('ws setup failed:', e.message);
}
console.log('ws open:', wsOpen);
console.log('=== delay tests ===');
for (const t of targets) {
  const url = `${BASE}/proxies/${encodeURIComponent(t.name)}/delay?timeout=8000&url=${encodeURIComponent('http://www.gstatic.com/generate_204')}`;
  const started = Date.now();
  try {
    const r = await fetch(url, { headers: H, signal: AbortSignal.timeout(15000) });
    const body = await r.text();
    console.log(`${r.status} (+${Date.now() - started}ms) [${t.tag}] ${t.name} => ${body.substring(0, 140)}`);
  } catch (e) {
    console.log(`ERR (+${Date.now() - started}ms) [${t.tag}] ${t.name} => ${e.message}`);
  }
}
await new Promise((r) => setTimeout(r, 800));
console.log('=== core logs ===');
for (const l of logs.slice(0, 50)) console.log(l.substring(0, 240));
if (logs.length === 0) console.log('(no core logs captured)');
