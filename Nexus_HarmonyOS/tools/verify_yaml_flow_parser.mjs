import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const mergerPath = path.join(root, 'entry/src/main/ets/commons/services/YamlMerger.ets');
const mergerSource = fs.readFileSync(mergerPath, 'utf8');

function splitTopLevel(content, separator = ',') {
  const out = [];
  let current = '';
  let quote = '';
  let escaped = false;
  let braceDepth = 0;
  let bracketDepth = 0;
  for (let i = 0; i < content.length; i++) {
    const ch = content[i];
    if (quote === '"' && escaped) {
      current += ch;
      escaped = false;
      continue;
    }
    if (quote === '"' && ch === '\\') {
      current += ch;
      escaped = true;
      continue;
    }
    if (quote) {
      current += ch;
      if (ch === quote) {
        if (quote === "'" && content[i + 1] === "'") {
          current += content[++i];
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
    } else if (ch === '{') {
      braceDepth++;
      current += ch;
    } else if (ch === '}') {
      if (braceDepth <= 0) throw new Error('extra closing brace');
      braceDepth--;
      current += ch;
    } else if (ch === '[') {
      bracketDepth++;
      current += ch;
    } else if (ch === ']') {
      if (bracketDepth <= 0) throw new Error('extra closing bracket');
      bracketDepth--;
      current += ch;
    } else if (ch === separator && braceDepth === 0 && bracketDepth === 0) {
      if (current.trim()) out.push(current.trim());
      current = '';
    } else {
      current += ch;
    }
  }
  if (quote || escaped || braceDepth !== 0 || bracketDepth !== 0) throw new Error('unclosed flow collection');
  if (current.trim()) out.push(current.trim());
  return out;
}

function findTopLevelColon(value) {
  let quote = '';
  let escaped = false;
  let braceDepth = 0;
  let bracketDepth = 0;
  for (let i = 0; i < value.length; i++) {
    const ch = value[i];
    if (quote === '"' && escaped) {
      escaped = false;
      continue;
    }
    if (quote === '"' && ch === '\\') {
      escaped = true;
      continue;
    }
    if (quote) {
      if (ch === quote) {
        if (quote === "'" && value[i + 1] === "'") i++;
        else quote = '';
      }
    } else if (ch === '"' || ch === "'") quote = ch;
    else if (ch === '{') braceDepth++;
    else if (ch === '}') braceDepth = Math.max(0, braceDepth - 1);
    else if (ch === '[') bracketDepth++;
    else if (ch === ']') bracketDepth = Math.max(0, bracketDepth - 1);
    else if (ch === ':' && braceDepth === 0 && bracketDepth === 0) return i;
  }
  return -1;
}

function scalar(raw) {
  const value = raw.trim();
  if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
    const inner = value.slice(1, -1);
    return value[0] === "'" ? inner.replace(/''/g, "'") : inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
  if (/^(true|false)$/i.test(value)) return value.toLowerCase() === 'true';
  if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(value)) return Number(value);
  return value.replace(/\s+#.*$/, '').trim();
}

function flowValue(raw) {
  const value = raw.trim();
  if (value.startsWith('{') && value.endsWith('}')) return flowMap(value);
  if (value.startsWith('[') && value.endsWith(']')) return splitTopLevel(value.slice(1, -1)).map(flowValue);
  return scalar(value);
}

function flowMap(text) {
  const value = text.trim();
  if (!value.startsWith('{') || !value.endsWith('}')) throw new Error('invalid flow map');
  const result = Object.create(null);
  for (const pair of splitTopLevel(value.slice(1, -1))) {
    const idx = findTopLevelColon(pair);
    if (idx <= 0) throw new Error('invalid map pair');
    result[String(scalar(pair.slice(0, idx)))] = flowValue(pair.slice(idx + 1));
  }
  return result;
}

function sectionLines(yaml, sectionName) {
  const out = [];
  let inSection = false;
  for (let line of yaml.split('\n')) {
    if (line.startsWith('\uFEFF')) line = line.slice(1);
    if (!line.startsWith(' ') && !line.startsWith('\t')) {
      const trimmed = line.trim();
      if (trimmed.startsWith(`${sectionName}:`)) {
        inSection = true;
        continue;
      }
      if (inSection && trimmed && !trimmed.startsWith('#')) break;
    }
    if (inSection) out.push(line);
  }
  return out;
}

function proxyItems(yaml) {
  const section = sectionLines(yaml, 'proxies');
  const contentLines = section.filter(line => {
    const trimmed = line.trimStart();
    return trimmed.length > 0 && !trimmed.startsWith('#');
  });
  if (!contentLines.length) return [];
  const minIndent = Math.min(...contentLines.map(line => line.length - line.trimStart().length));
  const normalized = section.filter(line => line.trim()).map(line => `  ${line.slice(minIndent)}`);
  const items = [];
  let current = null;
  for (const line of normalized) {
    if (line.startsWith('  - ')) {
      if (current) items.push(current);
      current = [line];
    } else if (current) current.push(line);
  }
  if (current) items.push(current);
  return items;
}

function parseItem(lines) {
  const text = lines.join('\n').trim();
  const body = text.startsWith('- ') ? text.slice(2).trim() : text;
  if (body.startsWith('{')) return flowMap(body);
  const result = Object.create(null);
  for (const line of lines) {
    const t = line.trim().replace(/^-\s+/, '');
    if (!t || t.startsWith('#')) continue;
    const idx = findTopLevelColon(t);
    if (idx > 0) result[String(scalar(t.slice(0, idx)))] = flowValue(t.slice(idx + 1));
  }
  return result;
}

function parseYaml(yaml) {
  return proxyItems(yaml).map(parseItem).filter(node => node.type !== 'direct');
}

const fixtures = [
  `proxies:\n  - {name: "VLESS WS 🚀", type: vless, server: ws.example.test, port: 443, uuid: 00000000-0000-4000-8000-000000000001, tls: true, ws-opts: {path: "/socket,a", headers: {Host: edge.example.test, X-Note: "a,b:c"}}}\nproxy-groups: []`,
  `proxies:\n  - {name: Reality, type: vless, server: reality.example.test, port: 443, uuid: 00000000-0000-4000-8000-000000000002, reality-opts: {public-key: REDACTED, short-id: ''}}`,
  `proxies:\n  - {name: Hy2 IPv6, type: hysteria2, server: 2001:db8:85a3::8a2e:370:7334, port: 443, password: redacted, ports: 20000-30000}`,
  `proxies:\n  - {name: TUIC, type: tuic, server: tuic.example.test, port: 443, uuid: 00000000-0000-4000-8000-000000000003, password: redacted, alpn: [h3, "h2,http/1.1"]}`,
  `proxies:\n  - {name: AnyTLS, type: anytls, server: anytls.example.test, port: 443, password: "long:redacted,value", idle-session-check-interval: 30, brutal-opts: {enabled: true, up: 100 Mbps, down: 200 Mbps}}`,
  `\uFEFFproxies:\r\n  # comment\r\n  - {name: BOM CRLF, type: vless, server: bom.example.test, port: 443, uuid: 00000000-0000-4000-8000-000000000004}\r\nanchors:\r\n  defaults: &defaults {udp: true}`,
  `proxies:\n  - name: Block Style\n    type: vless\n    server: block.example.test\n    port: 443\n    uuid: 00000000-0000-4000-8000-000000000005\n    network: ws`,
];

const parsed = fixtures.map(parseYaml);
assert.equal(parsed[0][0]['ws-opts'].headers.Host, 'edge.example.test');
assert.equal(parsed[0][0]['ws-opts'].headers['X-Note'], 'a,b:c');
assert.equal(parsed[1][0]['reality-opts']['short-id'], '');
assert.equal(parsed[2][0].server, '2001:db8:85a3::8a2e:370:7334');
assert.equal(parsed[2][0].ports, '20000-30000');
assert.deepEqual(parsed[3][0].alpn, ['h3', 'h2,http/1.1']);
assert.equal(parsed[4][0]['idle-session-check-interval'], 30);
assert.equal(parsed[5].length, 1);
assert.equal(parsed[5][0].name, 'BOM CRLF');
assert.equal(parsed[6][0].name, 'Block Style');
assert.throws(() => parseYaml('proxies:\n  - {name: broken, type: vless, server: x, port: 443'), /unclosed|invalid/);

const links = 'ss://YWVzLTI1Ni1nY206cmVkYWN0ZWQ@example.test:443#one\nvmess://REDACTED';
assert.equal(parseYaml(links).length, 0, 'link-list input must remain outside YAML proxy parsing');

for (const needle of ['splitTopLevel(content: string, separator: string)', "braceDepth === 0 && bracketDepth === 0", "line.startsWith('\\uFEFF')", "trimmed.length > 0 && !trimmed.startsWith('#')"]) {
  assert.ok(mergerSource.includes(needle), `YamlMerger source is missing parser safeguard: ${needle}`);
}

console.log(`PASS flow parser regression fixtures: ${fixtures.length}`);
console.log('PASS nested maps/sequences, quotes, emoji, bare IPv6, BOM, CRLF, comments and block style');
console.log('PASS malformed YAML rejection and link-list regression');

// Optional local-only validation against a user-supplied YAML path. Only the
// aggregate importable count is printed, never node names or credentials.
if (process.argv[2]) {
  const localYaml = fs.readFileSync(path.resolve(process.argv[2]), 'utf8');
  const localItems = proxyItems(localYaml);
  const parsedNodes = [];
  let rejectedCount = 0;
  for (const item of localItems) {
    try {
      const node = parseItem(item);
      if (node.type !== 'direct') parsedNodes.push(node);
    } catch {
      // Match YamlMerger.merge behavior: reject only the malformed item.
      rejectedCount++;
    }
  }
  const importable = parsedNodes.filter(node =>
    typeof node.name === 'string' && node.name.length > 0 &&
    typeof node.type === 'string' && node.type.length > 0 &&
    typeof node.server === 'string' && node.server.length > 0 &&
    Number.isInteger(node.port) && node.port > 0 && node.port <= 65535
  );
  console.log(`LOCAL_SAMPLE_ITEM_COUNT=${localItems.length}`);
  console.log(`LOCAL_SAMPLE_PARSED_COUNT=${parsedNodes.length}`);
  console.log(`LOCAL_SAMPLE_IMPORTABLE_COUNT=${importable.length}`);
}
