// delay_bundled.mjs — 对本机 bundled 内核 API 做逐节点延迟测试
const BASE = 'http://127.0.0.1:19091';
const SECRET = 'probe-secret';
const H = { Authorization: `Bearer ${SECRET}` };

const list = await (await fetch(`${BASE}/proxies`, { headers: H })).json();
const entries = Object.entries(list.proxies).filter(([, v]) => v.type === 'Vless');
const xhttp = entries.filter(([, v]) => (v.extra || {}).xhttp || JSON.stringify(v) .includes('xhttp'));
console.log(`vless total: ${entries.length}`);
const pick = [];
const xu = entries.find(([, v]) => /香港|HK/i.test(v.name));
if (xu) pick.push({ name: xu[1].name, tag: 'xhttp-HK' });
const r = entries.find(([, v]) => JSON.stringify(v).includes('reality') || JSON.stringify(v).includes('RELAY'));
if (r) pick.push({ name: r[1].name, tag: 'reality?' });
for (const p of pick) console.log('pick:', p.tag, p.name);
for (const p of pick) {
  const url = `${BASE}/proxies/${encodeURIComponent(p.name)}/delay?timeout=8000&url=${encodeURIComponent('http://www.gstatic.com/generate_204')}`;
  try {
    const resp = await fetch(url, { headers: H, signal: AbortSignal.timeout(15000) });
    const body = await resp.text();
    console.log(`${resp.status === 200 ? 'OK  ' : 'FAIL'} [${p.tag}] ${p.name} => ${resp.status} ${body.substring(0, 150)}`);
  } catch (e) {
    console.log(`FAIL [${p.tag}] ${p.name} => ${e.message}`);
  }
}
