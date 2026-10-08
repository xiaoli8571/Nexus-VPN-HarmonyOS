// delay_probe.mjs — 对本机 mihomo API 做逐节点延迟测试（UTF-8 安全）
const BASE = 'http://127.0.0.1:19091';
const SECRET = 'probe-secret';
const H = { Authorization: `Bearer ${SECRET}` };

const list = await (await fetch(`${BASE}/proxies`, { headers: H })).json();
const entries = Object.entries(list.proxies).filter(([, v]) =>
  ['Vless', 'Shadowsocks', 'Http'].includes(v.type) && !v.name.includes('前置'));
const pick = [];
for (const t of ['Vless', 'Shadowsocks', 'Http']) {
  const c = entries.find(([, v]) => v.type === t && /香港|HK/i.test(v.name))
    || entries.find(([, v]) => v.type === t);
  if (c) pick.push({ name: c[1].name, type: c[1].type });
}
console.log('testing:', pick.map((p) => `${p.type}:${p.name}`).join(' | '));
for (const p of pick) {
  const url = `${BASE}/proxies/${encodeURIComponent(p.name)}/delay?timeout=8000&url=${encodeURIComponent('http://www.gstatic.com/generate_204')}`;
  try {
    const r = await fetch(url, { headers: H, signal: AbortSignal.timeout(15000) });
    const body = await r.text();
    console.log(`${r.status === 200 ? 'OK  ' : 'FAIL'} [${p.type}] ${p.name} => ${r.status} ${body.substring(0, 120)}`);
  } catch (e) {
    console.log(`FAIL [${p.type}] ${p.name} => ${e.message}`);
  }
}
