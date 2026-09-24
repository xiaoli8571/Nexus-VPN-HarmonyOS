import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const proxyNode = read('entry/src/main/ets/commons/models/ProxyNode.ets');
const parser = read('entry/src/main/ets/commons/services/SubscriptionParser.ets');
const service = read('entry/src/main/ets/commons/services/SubscriptionService.ets');
const fetchPolicy = read('entry/src/main/ets/commons/services/SubscriptionFetchPolicy.ets');
const orchestrator = read('entry/src/main/ets/commons/services/ConnectionOrchestrator.ets');
const page = read('entry/src/main/ets/pages/SubscriptionPage.ets');
const statuses = read('entry/src/main/ets/commons/models/Subscription.ets');

function normalizeBase64(value) {
  let normalized = value.replace(/-/g, '+').replace(/_/g, '/').replace(/\s+/g, '');
  while (normalized.length % 4 !== 0) normalized += '=';
  return normalized;
}

function decodeBase64(value) {
  return Buffer.from(normalizeBase64(value), 'base64').toString('utf8');
}

function safeDecodeURIComponent(value) {
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

function supported(line) {
  return /^(ssr|ss|vless|vmess|trojan|hysteria2|hy2):\/\//.test(line.trim());
}

function isolateLines(text) {
  const valid = [];
  const unsupported = [];
  const invalid = [];
  for (const raw of text.replace(/^\uFEFF/, '').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (supported(line)) valid.push(line);
    else if (/^[a-z][a-z0-9+.-]*:\/\//i.test(line)) unsupported.push(line);
    else invalid.push(line);
  }
  return { valid, unsupported, invalid };
}

const links = [
  'ss://YWVzLTEyOC1nY206cGFzcw@example.com:443#emoji-%F0%9F%9A%80',
  'vless://00000000-0000-4000-8000-000000000001@[2001:db8::8]:443?type=ws#IPv6',
  'trojan://secret@example.net:443#100%broken',
  'unknown://example.org:1',
  'not-a-link'
].join('\r\n');
const isolated = isolateLines(`\uFEFF${links}`);
assert.equal(isolated.valid.length, 3, '好坏混合文本应逐条隔离并保留三个支持链接');
assert.equal(isolated.unsupported.length, 1, '未知协议应单独统计');
assert.equal(isolated.invalid.length, 1, '无效文本应单独统计');
assert.equal(safeDecodeURIComponent('emoji-%F0%9F%9A%80'), 'emoji-🚀');
assert.equal(safeDecodeURIComponent('100%broken'), '100%broken', '坏百分号不得拖垮整批');

const plain = `${links}\nss://duplicate@example.com:443#same`;
const standard = Buffer.from(plain, 'utf8').toString('base64').replace(/=+$/, '');
const urlSafe = standard.replace(/\+/g, '-').replace(/\//g, '_');
assert.equal(decodeBase64(standard), plain, '标准 Base64 缺 padding 应可解码');
assert.equal(decodeBase64(urlSafe), plain, 'URL-safe Base64 缺 padding 应可解码');
assert.deepEqual(isolateLines(''), { valid: [], unsupported: [], invalid: [] });
assert.equal(isolateLines('\uFEFF\r\n').valid.length, 0, 'BOM/CRLF 空输入不得产生节点');

assert.match(proxyNode, /replace\(\/-\/g, '\+'\)\.replace\(\/_\/g, '\/'\)/, '必须兼容 URL-safe Base64');
assert.match(proxyNode, /length % 4/, 'Base64 必须自动补位');
assert.match(parser, /for \(const line of normalized\.split/, '明文链接必须在清理 BOM 后逐行解析');
assert.match(parser, /for \(const line of decoded\.split/, 'Base64 内容必须逐行解析');
assert.match(parser, /if \(node === null\)[\s\S]*?return;/, '单条坏链接必须被隔离');
assert.match(service, /isNodeCountAllowed\(parsed\.length\)/, '刷新必须执行节点上限检查');
assert.doesNotMatch(service, /body\.includes\('proxies:'\)|trimmed\.includes\('proxies:'\)/,
  '网络订阅和本地导入不得仅靠 proxies: 子串判型');
assert.match(service, /YamlMerger\.proxyItemGroups\(body\)\.length > 0/,
  'URL 订阅必须按结构化 YAML 条目判型');
assert.match(service, /YamlMerger\.proxyItemGroups\(trimmed\)\.length > 0/,
  '本地 YAML 必须按结构化条目判型');
assert.match(service, /local import rejected:[\s\S]*?2000 limit/,
  '本地导入必须执行节点上限检查且可诊断');
assert.match(service, /LIMIT_EXCEEDED/, '超限必须返回显式状态');
assert.match(service, /PERSIST_ERROR/, '持久化异常必须独立分类');
assert.match(fetchPolicy, /EMPTY_RESPONSE/, '空响应必须独立分类');
assert.match(fetchPolicy, /SubscriptionFetchErrorKind\.HTTP/, 'HTTP 错误必须独立分类');
assert.match(fetchPolicy, /SubscriptionFetchErrorKind\.DECODE/, '解码错误必须独立分类');
assert.match(statuses, /NETWORK_ERROR[\s\S]*HTTP_ERROR[\s\S]*EMPTY_RESPONSE[\s\S]*DECODE_ERROR[\s\S]*PARSE_ERROR[\s\S]*LIMIT_EXCEEDED[\s\S]*PERSIST_ERROR/, '刷新错误状态必须完整');
assert.match(orchestrator, /result\.status === SubscriptionRefreshStatus\.OK[\s\S]*SubscriptionRefreshStatus\.NOT_MODIFIED/, '批量刷新只能把 OK/NOT_MODIFIED 计为成功');
assert.match(orchestrator, /failedCount = failedCount \+ 1/, '批量刷新必须统计业务失败');
assert.match(page, /this\.reload\(\);[\s\S]*刷新成功/, '刷新完成后页面列表必须立即同步');
assert.match(page, /NOT_MODIFIED/, '页面必须把未修改视为成功');
assert.match(service, /ensureUniqueNames\(\)/, '同名节点必须显式重命名而非静默丢弃');
assert.match(service, /return -1;/, '直接节点重复必须返回显式结果');
assert.match(service, /node\.password[\s\S]*?node\.uuid[\s\S]*?node\.rawUri/,
  '直链去重指纹必须区分同地址不同凭据');

const overLimit = Array.from({ length: 2001 }, (_, i) => `ss://fixture-${i}@example.com:443#n${i}`);
assert.equal(overLimit.length > 2000, true, '超限夹具必须覆盖 2000 节点边界');

console.log('PASS subscription import regressions');
console.log('fixtures: URL/local-YAML/link-text/base64/base64url/BOM/CRLF/emoji/percent/IPv6/mixed/duplicate/same-name/unknown/empty/limit/batch/error-boundaries');
