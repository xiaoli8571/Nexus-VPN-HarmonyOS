// 协议注册表 + 动态分组 + 用户可见摘要 回归（真实 ArkTS 生成模块，无重写逻辑）。
// 前置: node tools/true-chain-harness/prepare.mjs
// 运行: node --experimental-transform-types tools/true-chain-harness/protocol-regression.mjs
import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const generated = (name) => pathToFileURL(join(here, 'generated', name)).href;
const { SubscriptionParser } = await import(generated('SubscriptionParser.ts'));
const { SubscriptionService } = await import(generated('SubscriptionService.ts'));
const { ProxyNode } = await import(generated('ProxyNode.ts'));
const { ClashConfigGenerator } = await import(generated('ClashConfigGenerator.ts'));
const { ProxyDropReason } = await import(generated('ClashConfigGenerator.ts'));
const { SubscriptionImportDiagnostics } = await import(generated('Subscription.ts'));

// ── 1) scheme 注册表：hy2/tuic/anytls/hysteria 链接可解析，不再因名单被丢 ──
assert.equal(ProxyNode.hasUriCodec('tuic'), true);
assert.equal(ProxyNode.hasUriCodec('anytls'), true);
assert.equal(ProxyNode.hasUriCodec('hysteria'), true);
assert.equal(ProxyNode.hasUriCodec('hy2'), true);
assert.equal(ProxyNode.hasUriCodec('unknownproto'), false);

const links = [
  'tuic://2DD1E417-8A1D-4B7F-9E32-DEAD12345678:secretpw@relay.example.invalid:8443'
    + '?sni=relay.example.invalid&alpn=h3&congestion_control=bbr&udp_relay_mode=native'
    + '&allow_insecure=1&reduce_rtt=true#TUIC-节点',
  'anytls://anytls-pass@edge.example.invalid:443?sni=edge.example.invalid'
    + '&insecure=1&alpn=h2,h3#AnyTLS-节点',
  'hysteria://hy1.example.invalid:3670?auth=hy-auth-str&peer=hy1.example.invalid'
    + '&insecure=1&upmbps=30&downmbps=200&alpn=h3#Hysteria1-节点',
  'hysteria2://hy2pass@hy2.example.invalid:443?sni=hy2.example.invalid&insecure=1#HY2-节点'
];
const subText = links.join('\n') + '\n';
const parsed = SubscriptionParser.parseDetailed(subText, 'proto-sub');
assert.equal(parsed.nodes.length, 4, `expect 4 nodes, got ${parsed.nodes.length}`);
const byType = new Map(parsed.nodes.map((n) => [n.proxyType, n]));

// tuic: uuid/password/sni/alpn 进结构化槽位，congestion-control 等进 extraOpts
const tuic = byType.get('tuic');
assert.equal(tuic.uuid, '2DD1E417-8A1D-4B7F-9E32-DEAD12345678');
assert.equal(tuic.password, 'secretpw');
assert.equal(tuic.servername, 'relay.example.invalid');
assert.equal(tuic.alpnList, 'h3');
assert.equal(tuic.skipCertVerify, true);
assert.ok(tuic.extraOpts.includes('congestion-controller'));
assert.ok(tuic.extraOpts.includes('udp-relay-mode'));
assert.equal(ClashConfigGenerator.dropReasonFor(tuic), ProxyDropReason.NONE);
const tuicLine = ClashConfigGenerator.proxyYamlLine(tuic);
assert.ok(tuicLine.includes('type: tuic'), tuicLine);
assert.ok(tuicLine.includes('congestion-controller'), tuicLine);
assert.ok(tuicLine.includes('bbr'), tuicLine);
assert.ok(tuicLine.includes('udp-relay-mode'), tuicLine);

// anytls: password/sni/insecure/alpn
const anytls = byType.get('anytls');
assert.equal(anytls.password, 'anytls-pass');
assert.equal(anytls.servername, 'edge.example.invalid');
assert.equal(anytls.skipCertVerify, true);
assert.equal(ClashConfigGenerator.dropReasonFor(anytls), ProxyDropReason.NONE);
const anytlsLine = ClashConfigGenerator.proxyYamlLine(anytls);
assert.ok(anytlsLine.includes('type: anytls'), anytlsLine);
assert.ok(anytlsLine.includes('password: "anytls-pass"'), anytlsLine);

// hysteria v1: auth 进 password，up/down 通过 extraOpts 回写（生成端仅对 hy2 用结构化 up/down）
const hy1 = byType.get('hysteria');
assert.equal(hy1.password, 'hy-auth-str');
assert.equal(hy1.servername, 'hy1.example.invalid');
assert.equal(hy1.hyUp, '30');
assert.equal(hy1.hyDown, '200');
assert.equal(ClashConfigGenerator.dropReasonFor(hy1), ProxyDropReason.NONE);
const hy1Line = ClashConfigGenerator.proxyYamlLine(hy1);
assert.ok(hy1Line.includes('type: hysteria'), hy1Line);
assert.ok(hy1Line.includes('auth_str'), hy1Line);
assert.ok(hy1Line.includes('hy-auth-str'), hy1Line);
assert.ok(hy1Line.includes('up: 30'), hy1Line);
assert.ok(hy1Line.includes('down: 200'), hy1Line);

// hy2 原有能力不回归
const hy2 = byType.get('hysteria2');
assert.equal(hy2.password, 'hy2pass');
assert.equal(ClashConfigGenerator.dropReasonFor(hy2), ProxyDropReason.NONE);

// ── 2) 未识别 scheme：计 unsupported 诊断，绝不静默消失 ──
const mixed = 'juicity://whatever@x.example.invalid:443?sni=x#X\n' + links[0];
const mixedParsed = SubscriptionParser.parseDetailed(mixed, 'proto-sub-2');
assert.equal(mixedParsed.nodes.length, 1);
assert.equal(mixedParsed.diagnostics.unsupportedCount, 1);
assert.ok(mixedParsed.diagnostics.unsupportedTypes.includes('juicity'));

// ── 3) YAML 侧通用透传：hysteria YAML 节点的 auth_str（下划线键）不被丢 ──
const hyYaml = `
proxies:
  - name: HY-YAML
    type: hysteria
    server: y.example.invalid
    port: 3670
    auth_str: yaml-auth
    protocol: udp
    up: 30
    down: 200
    sni: y.example.invalid
`;
const hyFromYaml = SubscriptionParser.parseDetailed(hyYaml, 'proto-sub-3');
assert.equal(hyFromYaml.nodes.length, 1, 'hysteria YAML node must import');
const hyYamlNode = hyFromYaml.nodes[0];
assert.equal(hyYamlNode.proxyType, 'hysteria');
assert.equal(ClashConfigGenerator.dropReasonFor(hyYamlNode), ProxyDropReason.NONE);
const hyYamlLine = ClashConfigGenerator.proxyYamlLine(hyYamlNode);
assert.ok(hyYamlLine.includes('auth_str'), hyYamlLine);
assert.ok(hyYamlLine.includes('yaml-auth'), hyYamlLine);
assert.ok(hyYamlLine.includes('protocol'), hyYamlLine);

// ── 4) 用户可见摘要：不再出现 输入/配置丢弃/双轨/持久化失败 等内部账本 ──
const d = new SubscriptionImportDiagnostics();
d.inputCount = 21;
d.addedCount = 21;
d.configDroppedCount = 3;
d.persistFailedCount = 0;
d.rawProviderEnabled = true;
d.rawProviderWritten = 1;
const userText = d.summary();
assert.ok(!userText.includes('输入'), userText);
assert.ok(!userText.includes('配置丢弃'), userText);
assert.ok(!userText.includes('双轨'), userText);
assert.ok(userText.includes('成功 21'), userText);
// 完整账本仍可通过 debugSummary 取到（仅日志用）
assert.ok(d.debugSummary().includes('双轨'), 'debugSummary keeps the ledger for logs');

// ── 5) 服务层组 API 形状（与 NodeSelectionPage 调用一致） ──
const { ProxyGroup } = await import(generated('ProxyGroup.ts'));
const svc = new SubscriptionService();
assert.deepEqual(svc.groupsOf('none'), []);
const emptyGroup = new ProxyGroup();
emptyGroup.subscriptionId = 'none';
emptyGroup.name = '空组';
assert.deepEqual(svc.expandProxyGroup(emptyGroup), []);

// ── 6) proxy-groups 缩进兼容：4 空格与 Tab 缩进的序列项必须解析出组（吹雪云类模板）──
const fourIndent = [
  'proxies:',
  '    - name: "🚀 节点"',
  '      type: trojan',
  '      server: p1.example.invalid',
  '      port: 443',
  '      password: REDACTED',
  'proxy-groups:',
  '    - name: "⛔️ 漏网"',
  '      type: select',
  '      proxies:',
  '          - 🚀 节点',
  '          - DIRECT'
].join('\n');
const tabIndent = [
  'proxies:',
  '\t- name: T1',
  '\t  type: trojan',
  '\t  server: t1.example.invalid',
  '\t  port: 443',
  '\t  password: REDACTED',
  'proxy-groups:',
  '\t- name: T组',
  '\t  type: select',
  '\t  proxies:',
  '\t\t- T1',
  '\t\t- DIRECT'
].join('\n');
for (const [label, body] of [['four', fourIndent], ['tab', tabIndent]]) {
  const shaped = SubscriptionParser.parseDetailed(body, 'indent-' + label);
  assert.equal(shaped.nodes.length, 1, `${label}: node must import`);
  assert.equal(shaped.groups.length, 1, `${label}: group must parse`);
  assert.deepEqual(shaped.groups[0].members.slice(0, 1), [label === 'four' ? '🚀 节点' : 'T1'],
    `${label}: member must parse`);
  SubscriptionParser.materializeDynamicGroups(shaped.groups, shaped.nodes);
  assert.equal(shaped.groups[0].members.length, 2, `${label}: materialize keeps declared members`);
}

console.log('protocol regression: PASS codecs=4 unsupported-isolated yaml-passthrough summary-clean indent-tolerant');
