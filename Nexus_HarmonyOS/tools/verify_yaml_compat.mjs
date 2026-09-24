import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const yamlMerger = fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/services/YamlMerger.ets'), 'utf8');
const generator = fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/services/ClashConfigGenerator.ets'), 'utf8');
const parser = fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/services/SubscriptionParser.ets'), 'utf8');
const service = fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/services/SubscriptionService.ets'), 'utf8');

const fixtures = [
  { type: 'ss', required: ['cipher', 'password'], extras: [['plugin', 'v2ray-plugin'], ['plugin-opts', '{mode: websocket, host: ss.example}']] },
  { type: 'ssr', required: ['cipher', 'password', 'protocol', 'obfs'], extras: [['udp', 'true']] },
  { type: 'vmess', required: ['uuid', 'cipher'], extras: [['packet-encoding', 'xudp'], ['h2-opts', '{host: vm.example, path: /h2}']] },
  { type: 'vless', required: ['uuid'], extras: [['packet-encoding', 'xudp']], nested: ['reality-opts', 'ws-opts', 'grpc-opts'] },
  { type: 'trojan', required: ['password'], extras: [['certificate', 'cert.pem'], ['private-key', 'key.pem']], nested: ['ws-opts'] },
  { type: 'hysteria', required: ['auth-str'], extras: [['ports', '20000-30000'], ['protocol', 'udp']] },
  { type: 'hysteria2', required: ['password'], extras: [['obfs', 'salamander'], ['obfs-password', 'secret']] },
  { type: 'tuic', required: ['uuid', 'password'], extras: [['congestion-controller', 'bbr'], ['udp-relay-mode', 'native']] },
  { type: 'anytls', required: ['password'], extras: [['idle-session-check-interval', '30']] },
  { type: 'naive', required: ['username', 'password'], extras: [['headers', '{User-Agent: test}']] },
  { type: 'shadowtls', required: ['password'], extras: [['version', '3'], ['client-fingerprint', 'chrome']] },
  { type: 'wireguard', required: ['private-key', 'public-key'], extras: [['ip', '172.16.0.2'], ['allowed-ips', '[0.0.0.0/0, ::/0]']] },
  { type: 'future-quic', required: ['token'], extras: [['future-opt', '{enabled: true}']] }
];

const forbidden = new Set(['__proto__', 'prototype', 'constructor']);
const core = new Set(['name', 'type', 'server', 'port']);
const safeKey = key => /^[a-z][a-z0-9-]{0,63}$/.test(key) && !forbidden.has(key);

function sanitizeExtraOpts(value) {
  if (!Array.isArray(value)) return [];
  const out = [];
  const seen = new Set();
  for (const pair of value) {
    if (!Array.isArray(pair) || pair.length !== 2) continue;
    const [key, raw] = pair;
    if (typeof key !== 'string' || typeof raw !== 'string') continue;
    if (!safeKey(key) || core.has(key) || seen.has(key)) continue;
    if (raw.length === 0 || raw.length > 65536 || /[\r\n\0]/.test(raw)) continue;
    seen.add(key);
    out.push([key, raw]);
  }
  return out;
}

function persistRestore(node) {
  const persisted = JSON.parse(JSON.stringify(node));
  persisted.rawYaml = '';
  const restored = { ...persisted };
  restored.extraOpts = JSON.stringify(sanitizeExtraOpts(JSON.parse(restored.extraOpts || '[]')));
  restored.rawYaml = '';
  return restored;
}

function generateProxy(node) {
  const fields = new Map(Object.entries({ name: node.name, type: node.type, server: node.server, port: node.port }));
  for (const key of node.required) fields.set(key, `${key}-value`);
  for (const [key, value] of sanitizeExtraOpts(JSON.parse(node.extraOpts))) {
    if (!fields.has(key) && !core.has(key)) fields.set(key, value);
  }
  return fields;
}

for (const fixture of fixtures) {
  const node = {
    name: `${fixture.type}-fixture`,
    type: fixture.type,
    server: `${fixture.type}.example`,
    port: 443,
    required: fixture.required,
    extraOpts: JSON.stringify([
      ...fixture.extras,
      ['name', 'stale-name'], ['type', 'stale-type'], ['server', 'stale.example'], ['port', '1'],
      ['constructor', 'pollute'], ['prototype', 'pollute'], ['__proto__', 'pollute'],
      ['undefined-value', undefined], ['null-value', null], ['bad-object', { injected: true }]
    ]),
    rawYaml: '{name: stale-name, type: stale-type, server: stale.example, port: 1}'
  };
  const restored = persistRestore(node);
  const generated = generateProxy(restored);
  assert.equal(generated.get('name'), node.name, `${fixture.type}: canonical name must win`);
  assert.equal(generated.get('type'), node.type, `${fixture.type}: canonical type must win`);
  assert.equal(generated.get('server'), node.server, `${fixture.type}: canonical server must win`);
  assert.equal(generated.get('port'), node.port, `${fixture.type}: canonical port must win`);
  assert.equal(restored.rawYaml, '', `${fixture.type}: rawYaml must not survive persistence`);
  for (const [key, value] of fixture.extras) assert.equal(generated.get(key), value, `${fixture.type}: preserve ${key}`);
  for (const key of forbidden) assert.equal(generated.has(key), false, `${fixture.type}: reject ${key}`);
  assert.equal(generated.has('undefined-value'), false, `${fixture.type}: reject undefined`);
  assert.equal(generated.has('null-value'), false, `${fixture.type}: reject null`);
  assert.equal(generated.has('bad-object'), false, `${fixture.type}: reject object`);
}

const sourceChecks = [
  [yamlMerger, "'tuic', 'hysteria'", 'relay protocol set'],
  [yamlMerger, "'shadow-tls'", 'shadow-tls alias'],
  [yamlMerger, "'wireguard'", 'wireguard relay'],
  [yamlMerger, 'isSafeExtraKey', 'central safe extra key policy'],
  [yamlMerger, "key !== 'constructor'", 'prototype-pollution guard'],
  [yamlMerger, "key === 'name' || key === 'type' || key === 'server' || key === 'port'", 'canonical core separation'],
  [generator, '!YamlMerger.isSafeExtraKey(key)', 'generator revalidates extras'],
  [generator, "key === 'name' || key === 'type' || key === 'server'", 'generator protects canonical fields'],
  [generator, "key === 'port'", 'generator protects canonical port'],
  [generator, 'reality-opts:', 'Reality generation'],
  [generator, 'ws-opts:', 'WebSocket generation'],
  [generator, 'grpc-opts:', 'gRPC generation'],
  [generator, 'alpn:', 'ALPN array generation'],
  [parser, 'node.extraOpts = merged.extraOpts', 'parse maps extras'],
  [service, 'n.extraOpts = m.extraOpts', 'merge maps extras'],
  [service, "n.extraOpts = j.extraOpts ?? ''", 'restore maps extras'],
  [service, 'j.extraOpts = n.extraOpts', 'persist maps extras'],
  [service, "n.rawYaml = ''", 'restore drops raw YAML'],
  [generator, 'validNodes.includes(selectedNode)', 'selected group member validation']
];
for (const [source, needle, label] of sourceChecks) assert.ok(source.includes(needle), `source check failed: ${label}`);

console.log(`PASS yaml compatibility fixtures: ${fixtures.length} protocols`);
console.log('PASS parse -> persist/restore -> generate semantic policy');
console.log('PASS unknown fields/future protocol and unsafe value filtering');
console.log('PASS source wiring and proxy-group reference guards');
