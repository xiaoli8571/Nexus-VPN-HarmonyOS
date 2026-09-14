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
const { RawSubscriptionStore } = await import(generated('stubs.ts'));

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

// ── 7) type: direct 出站（mihomo 合法节点，无 server/port）不再被当缺字段丢弃 ──
const directYaml = `
proxies:
  - name: 直连
    type: direct
  - name: P1
    type: trojan
    server: p1.example.invalid
    port: 443
    password: REDACTED
`;
const dp = SubscriptionParser.parseDetailed(directYaml, 'direct-sub');
assert.equal(dp.nodes.length, 2, 'direct + trojan both import');
const directNode = dp.nodes.find((n) => n.proxyType === 'direct');
assert.ok(directNode, 'direct node imported');
assert.equal(ClashConfigGenerator.dropReasonFor(directNode), ProxyDropReason.NONE);
const directLine = ClashConfigGenerator.proxyYamlLine(directNode);
assert.ok(directLine.includes('type: direct'), directLine);
assert.ok(!directLine.includes('server:'), directLine);
// direct 节点跨重启恢复不丢（server 空 + port 0 校验豁免）
const directSvc = new SubscriptionService();
directSvc.nodes = SubscriptionService['mapNodes'](
  JSON.parse(JSON.stringify(SubscriptionService['nodesToJson'](dp.nodes))));
assert.equal(directSvc.nodes.length, 2, 'direct node survives restore round-trip');

// ── 8) 本地 YAML 的 proxy-providers 拉取（对齐 mihomo include-all 语义）──
const fakeProviderBody = `
proxies:
  - {name: "🇯🇵 Provider节点A", type: trojan, server: a.example.invalid, port: 443, password: REDACTED}
  - {name: "🇯🇵 Provider节点B", type: trojan, server: b.example.invalid, port: 443, password: REDACTED}
`;
const localWithProvider = `
proxies:
  - {name: 本地节点, type: trojan, server: l.example.invalid, port: 443, password: REDACTED}
proxy-providers:
  良心云:
    type: http
    url: "https://provider.example.invalid/sub"
    interval: 300
proxy-groups:
  - name: 全部节点
    type: select
    include-all: true
`;
const { harnessPrefs } = await import(generated('stubs.ts'));
const gSave = globalThis.__HARNESS_BODY__;
globalThis.__HARNESS_BODY__ = fakeProviderBody;
try {
  harnessPrefs.clear();
  const provSvc = new SubscriptionService();
  await provSvc.init({ cacheDir: 'harness-cache-provider' });
  const imported = await provSvc.addLocalYaml('自建.yaml', localWithProvider);
  assert.equal(imported, 3, `1 static + 2 provider nodes, got ${imported}`);
  const localSub = provSvc.subscriptions.find((s) => s.url.startsWith('local://') && s.id !== 'direct');
  const allGroups = provSvc.groupsOf(localSub.id);
  assert.equal(allGroups.length, 1);
  const expandedNames = provSvc.expandProxyGroup(allGroups[0]).map((n) => n.originalName);
  assert.ok(expandedNames.some((n) => n.includes('Provider节点A')), JSON.stringify(expandedNames));
  assert.ok(expandedNames.some((n) => n.includes('本地节点')), JSON.stringify(expandedNames));

  // 本地订阅「刷新」= 从落盘原文重解析 + 重拉 providers（provider 失败后的重试入口）
  RawSubscriptionStore.raws.set(localSub.id, localWithProvider);
  globalThis.__HARNESS_BODY__ = fakeProviderBody.replace(/节点A/g, '节点C')
    .replace('a.example.invalid', 'c.example.invalid')
    + '\n  - {name: "🇯🇵 Provider节点D", type: trojan, server: d.example.invalid, port: 443, password: REDACTED}';
  const refreshed = await provSvc.refreshSubscription(localSub.id);
  assert.equal(refreshed.status, 'ok', refreshed.message);
  assert.equal(provSvc.nodesOf(localSub.id).length, 4, '1 static + 3 provider after refresh');
  const refreshedGroups = provSvc.groupsOf(localSub.id);
  const refreshedNames = provSvc.expandProxyGroup(refreshedGroups[0]).map((n) => n.originalName);
  assert.ok(refreshedNames.some((n) => n.includes('Provider节点C')), JSON.stringify(refreshedNames));
  assert.ok(refreshedNames.some((n) => n.includes('Provider节点D')), JSON.stringify(refreshedNames));
} finally {
  if (gSave === undefined) {
    delete globalThis.__HARNESS_BODY__;
  } else {
    globalThis.__HARNESS_BODY__ = gSave;
  }
}

// ── 9) groupMembersOf：直接成员视图（默认代理 → 嵌套国家组 + 直连节点，不拍平）──
const nestedYaml = `
proxies:
  - {name: "🇭🇰 HK-A", type: trojan, server: ha.example.invalid, port: 443, password: REDACTED}
  - {name: "🇭🇰 HK-B", type: trojan, server: hb.example.invalid, port: 443, password: REDACTED}
  - {name: 直连, type: direct}
proxy-groups:
  - name: 香港节点
    type: select
    proxies: ["🇭🇰 HK-A", "🇭🇰 HK-B"]
  - name: 默认代理
    type: select
    proxies: [香港节点, 直连]
`;
const nestedParsed = SubscriptionParser.parseDetailed(nestedYaml, 'nested-sub');
SubscriptionParser.materializeDynamicGroups(nestedParsed.groups, nestedParsed.nodes);
const nestedSvc = new SubscriptionService();
nestedSvc.nodes = nestedParsed.nodes;
nestedSvc.proxyGroups = nestedParsed.groups;
const defaultGroup = nestedParsed.groups.find((value) => value.name === '默认代理');
assert.ok(defaultGroup);
const members = nestedSvc.groupMembersOf(defaultGroup);
assert.equal(members.groups.length, 1, JSON.stringify(members.groups.map((x) => x.name)));
assert.equal(members.groups[0].name, '香港节点');
assert.equal(members.nodes.length, 1);
assert.equal(members.nodes[0].proxyType, 'direct');
// 展平口径保持可用（计数标签用）
assert.equal(nestedSvc.expandProxyGroup(defaultGroup).length, 3);

// ── 10) provider 段的 health-check 子块不得覆盖 provider 自己的 url（真机案例）──
const { ProxyProviderParser } = await import(generated('ProxyProviderParser.ts'));
const providerHealthYaml = `
proxy-providers:
  良心云:
    url: "https://provider.example.invalid/sub"
    type: http
    interval: 86400
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
    proxy: 直连
proxies:
  - {name: 本地节点, type: trojan, server: l.example.invalid, port: 443, password: REDACTED}
`;
const heEntries = ProxyProviderParser.parse(providerHealthYaml);
assert.equal(heEntries.length, 1);
assert.equal(heEntries[0].url, 'https://provider.example.invalid/sub',
  'health-check url must not override provider url');
assert.equal(heEntries[0].isFetchable(), true);

// ── 11) (?i) 作用域对齐 regexp2：mid-pattern 的 (?i) 只影响其后，US 不误命中 EUserv ──
const scopeYaml = `
proxies:
  - {name: "🇺🇸 RN argo1", type: trojan, server: us.example.invalid, port: 443, password: REDACTED}
  - {name: "🇩🇪 EUserv reality", type: trojan, server: de.example.invalid, port: 443, password: REDACTED}
  - {name: "United States 01", type: trojan, server: us2.example.invalid, port: 443, password: REDACTED}
proxy-groups:
  - name: 美国节点
    type: select
    include-all: true
    filter: "(?=.*(美|US|🇺🇸|(?i)States|America))^((?!(港|台|韩|新|日)).)*$"
`;
const scopeParsed = SubscriptionParser.parseDetailed(scopeYaml, 'scope-sub');
SubscriptionParser.materializeDynamicGroups(scopeParsed.groups, scopeParsed.nodes);
const usGroup = scopeParsed.groups.find((value) => value.name === '美国节点');
assert.ok(usGroup, '美国节点 group parsed');
const usMembers = usGroup.members;
assert.ok(!usMembers.some((n) => n.includes('EUserv')), JSON.stringify(usMembers));
assert.ok(usMembers.some((n) => n.includes('RN argo1')), JSON.stringify(usMembers));
assert.ok(usMembers.some((n) => n.includes('United States')), JSON.stringify(usMembers));

console.log('protocol regression: PASS codecs=4 unsupported-isolated yaml-passthrough summary-clean'
  + ' indent-tolerant direct-outbound provider-fetch local-refresh nested-members health-check-url'
  + ' inline-ignore-case-scope');
