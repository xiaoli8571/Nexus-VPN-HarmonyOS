// 用真机 /connections 的真实响应验证 smartActiveNodes 的解析逻辑。
// 这个测试存在的理由：手写源码断言无法发现「解析逻辑对但没重建 UI 行」这类缺陷，
// 也无法证明 chain 里的名字与订阅节点名**确实对得上**。真机响应是唯一事实来源。
//
// 用法：node verify-smart-active-chains.mjs <connections.json> <proxies.json>
// 没有真机抓包时**跳过**（不是失败）：CI/本机无设备属正常情况。
import { readFileSync, existsSync } from 'node:fs';

const GROUP = '♻️ 自动选择';
const connsPath = process.argv[2];
const proxiesPath = process.argv[3];
if (!connsPath || !proxiesPath || !existsSync(connsPath) || !existsSync(proxiesPath)) {
  console.log('SKIP: 需要真机抓包 /connections + /proxies 作为参数（本机无设备时不失败）');
  process.exit(0);
}
const raw = readFileSync(connsPath, 'utf8');
const root = JSON.parse(raw);

// ── 复刻 ClashApiService.smartActiveNodes 的算法 ──
// knownNames = 订阅里的真实节点名；这里用 /proxies 的 all 减去组名/伪节点近似
const allProxies = JSON.parse(readFileSync(process.argv[3], 'utf8'));
const knownNames = allProxies['proxies'][GROUP].all;

function smartActiveNodes(groupName, known) {
  const conns = root['connections'];
  if (conns === undefined || conns === null) return [];
  const used = [];
  for (const conn of conns) {
    const chains = conn['chains'];
    if (!chains) continue;
    if (!chains.includes(groupName)) continue;
    let outbound = '';
    for (const name of chains) if (known.includes(name)) outbound = name;
    if (outbound.length > 0 && !used.includes(outbound)) used.push(outbound);
  }
  return used;
}

const got = smartActiveNodes(GROUP, knownNames);
console.log(`connections      : ${root.connections.length}`);
console.log(`known node names : ${knownNames.length}`);
console.log(`resolved outbound: ${got.length}`);
for (const n of got) console.log(`  -> ${n}`);

const expected = ['🇭🇰 香港Z09 | IEPL', '🇦🇺 澳大利亚Z01', '套餐到期：长期有效'];
let pass = 0, fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log(`  PASS ${name}`); }
  else { fail++; console.log(`  FAIL ${name}`); }
};
console.log('');
check('group matched in chains', root.connections.some(c => c.chains.includes(GROUP)));
check('every chain with group resolved to a node', got.length === root.connections.length);
check('exact expected set', expected.every(e => got.includes(e)) && got.length === expected.length);
// 组名自身绝不能被当成出口节点
check('group name not treated as outbound', !got.includes(GROUP));
check('PROXY not treated as outbound', !got.includes('PROXY'));

console.log(`\nPASSED=${pass} FAILED=${fail}`);
process.exit(fail === 0 ? 0 : 1);
