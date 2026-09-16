// 使用 prepare.mjs 从真实 ArkTS 生成的模块验证代理组身份映射与展开语义。
import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const generated = (name) => pathToFileURL(join(here, 'generated', name)).href;
const { SubscriptionService, DIRECT_GROUP_ID } = await import(generated('SubscriptionService.ts'));
const { SubscriptionParser } = await import(generated('SubscriptionParser.ts'));
const { ProxyGroup } = await import(generated('ProxyGroup.ts'));
const { ProxyNode } = await import(generated('ProxyNode.ts'));
const { AppSettings } = await import(generated('AppSettings.ts'));
const { ClashConfigGenerator } = await import(generated('ClashConfigGenerator.ts'));
const { harnessPrefs } = await import(generated('stubs.ts'));

function node(id, subscriptionId, name, originalName) {
  const value = new ProxyNode();
  value.id = id;
  value.subscriptionId = subscriptionId;
  value.name = name;
  value.originalName = originalName;
  value.server = 'example.invalid';
  value.port = 443;
  value.proxyType = 'trojan';
  // generate() 会丢弃缺凭据的节点；expandProxyGroup 不读凭据，此处统一补齐。
  value.password = 'REDACTED';
  return value;
}

function group(subscriptionId, name, members) {
  const value = new ProxyGroup();
  value.subscriptionId = subscriptionId;
  value.name = name;
  value.groupType = 'select';
  value.members = members.slice();
  return value;
}

function ids(nodes) {
  return nodes.map((value) => value.id);
}

const svc = new SubscriptionService();
svc.nodes = [
  node('a1', 'sub-a', '机场-A', 'A'),
  node('a2', 'sub-a', '机场-A (2)', 'A'),
  node('b1', 'sub-a', '机场-B', 'B'),
  node('other', 'sub-b', '机场-A', 'A')
];
svc.proxyGroups = [
  group('sub-a', '基础', ['A', 'A', 'B', 'DIRECT', 'REJECT', 'GLOBAL', '不存在']),
  group('sub-a', '嵌套', ['基础', 'A']),
  group('sub-a', '循环甲', ['循环乙', 'B']),
  group('sub-a', '循环乙', ['循环甲', 'A']),
  group('sub-b', '基础', ['A'])
];

assert.deepEqual(ids(svc.expandProxyGroup(svc.proxyGroups[0])), ['a1', 'a2', 'b1']);
assert.deepEqual(ids(svc.expandProxyGroup(svc.proxyGroups[1])), ['a1', 'a2', 'b1']);
assert.deepEqual(ids(svc.expandProxyGroup(svc.proxyGroups[2])), ['a1', 'a2', 'b1']);
assert.deepEqual(ids(svc.expandProxyGroup(svc.proxyGroups[4])), ['other']);

// JSON 持久化与恢复必须保留 originalName。
const persistedJson = SubscriptionService['nodesToJson'](svc.nodes);
const persistedRoundTrip = JSON.parse(JSON.stringify(persistedJson));
const restored = new SubscriptionService();
restored.nodes = SubscriptionService.mapNodes(persistedRoundTrip);
restored.proxyGroups = svc.proxyGroups.map((value) => ProxyGroup.fromJson(ProxyGroup.toJson(value)));
assert.deepEqual(ids(restored.expandProxyGroup(restored.proxyGroups[0])), ['a1', 'a2', 'b1']);

// 旧数据缺少 originalName 时，只允许剥离历史唯一名后缀。
const legacyJson = [{ ...persistedJson[0], originalName: undefined, name: '旧显示名 (2)' }];
const legacy = SubscriptionService.mapNodes(legacyJson);
assert.equal(legacy.length, 1);
assert.equal(legacy[0].originalName, '旧显示名');

// 回退必须唯一且受控：歧义、任意前缀/子串、跨订阅都不能猜测匹配。
const guarded = new SubscriptionService();
guarded.nodes = [
  node('u1', 'sub-a', '订阅前缀-唯一名', '唯一名'),
  node('d1', 'sub-a', '重复名 (2)', '重复名 (2)'),
  node('d2', 'sub-a', '重复名 (3)', '重复名 (3)'),
  node('x1', 'sub-b', '唯一名', '唯一名')
];
guarded.proxyGroups = [
  group('sub-a', '精确', ['唯一名']),
  group('sub-a', '后缀回退歧义', ['重复名']),
  group('sub-a', '禁止订阅前缀猜测', ['订阅前缀']),
  group('sub-a', '保留字与缺失', ['DIRECT', 'REJECT', 'GLOBAL', '缺失成员'])
];
assert.deepEqual(ids(guarded.expandProxyGroup(guarded.proxyGroups[0])), ['u1']);
assert.deepEqual(ids(guarded.expandProxyGroup(guarded.proxyGroups[1])), []);
assert.deepEqual(ids(guarded.expandProxyGroup(guarded.proxyGroups[2])), []);
assert.deepEqual(ids(guarded.expandProxyGroup(guarded.proxyGroups[3])), []);

assert.equal(restored.groupsOf('sub-without-groups').length, 0);

// 真实 SubscriptionParser 源码：覆盖 block sequence、flow sequence、嵌套组及保留字。
// fixture 全部使用 example.invalid 与 REDACTED，不包含任何真机凭据或节点名称。
const structuredYaml = `
proxies:
  - name: Alpha
    type: trojan
    server: alpha.example.invalid
    port: 443
    password: REDACTED
  - name: Beta
    type: trojan
    server: beta.example.invalid
    port: 443
    password: REDACTED
proxy-groups:
  - name: Block
    type: select
    proxies:
      - Alpha
      - Beta
      - DIRECT
      - REJECT
      - GLOBAL
  - { name: Flow, type: select, proxies: [Alpha, Beta, DIRECT] }
  - name: Nested
    type: select
    proxies:
      - Block
      - GLOBAL
`;
const parsedStructured = SubscriptionParser.parseDetailed(structuredYaml, 'fixture-sub');
assert.equal(parsedStructured.nodes.length, 2);
assert.equal(parsedStructured.groups.length, 3);
assert.deepEqual(parsedStructured.groups.map((value) => value.members.length), [5, 3, 2]);
assert.ok(parsedStructured.groups.every((value) => value.members.length > 0));

// 真实启动生命周期：旧 preferences 没有 proxy_groups_json，仅有 nodes 与 yaml_cache。
// init 必须在首次页面读取前重建、持久化并可展开为同订阅节点。
harnessPrefs.clear();
const lifecycleNodes = SubscriptionService['nodesToJson'](parsedStructured.nodes);
const lifecycleSubs = [{
  id: 'fixture-sub', name: '脱敏订阅', url: 'https://subscription.example.invalid/redacted',
  headerName: '', headerValue: '', lastFetchedAt: 0, lastRefreshResult: '',
  nodeCount: parsedStructured.nodes.length, enabled: true, sortOrder: 0
}];
harnessPrefs.set('subscriptions_json', JSON.stringify(lifecycleSubs));
harnessPrefs.set('nodes_json', JSON.stringify(lifecycleNodes));
harnessPrefs.set('yaml_cache_fixture-sub', structuredYaml);
const lifecycle = new SubscriptionService();
await lifecycle.init({ cacheDir: 'harness-cache' });
const firstReadGroups = lifecycle.groupsOf('fixture-sub');
assert.equal(firstReadGroups.length, 3);
assert.ok(firstReadGroups.every((value) => value.members.length > 0));
assert.equal(lifecycle.expandProxyGroup(firstReadGroups[0]).length, 2);
assert.equal(lifecycle.expandProxyGroup(firstReadGroups[2]).length, 2);
assert.ok(harnessPrefs.has('proxy_groups_json'));
const persistedGroups = JSON.parse(harnessPrefs.get('proxy_groups_json'));
assert.equal(persistedGroups.length, 3);
assert.ok(persistedGroups.every((value) => value.members.length > 0));

// 第二次启动从已持久化分组恢复，结果保持幂等。
const lifecycleRestarted = new SubscriptionService();
await lifecycleRestarted.init({ cacheDir: 'harness-cache' });
assert.equal(lifecycleRestarted.groupsOf('fixture-sub').length, 3);
assert.equal(lifecycleRestarted.expandProxyGroup(lifecycleRestarted.groupsOf('fixture-sub')[0]).length, 2);

// 配置生成计划：支持 Clash 风格组、原始节点名映射、空组/冲突组过滤及选择持久化。
const configNodes = [
  node('cfg-a1', 'sub-a', 'Alpha', 'A'),
  node('cfg-a2', 'sub-a', 'Alpha (2)', 'A'),
  node('cfg-b', 'sub-a', 'Beta', 'B')
];
const configGroups = [
  group('sub-a', '基础策略', ['A', 'B', 'DIRECT', '不存在']),
  group('sub-a', '嵌套策略', ['基础策略']),
  group('sub-a', '空策略', ['不存在']),
  group('sub-a', 'PROXY', ['A']),
  group('sub-a', 'Alpha', ['B'])
];
configGroups[1].groupType = 'url-test';
// 纯循环（无节点出口）必须整组丢弃；带真实出口的循环保留，但成员引用
// 只指向更早落地的组（回边被断开），保证内核不会遇到循环引用。
configGroups.push(
  group('sub-a', '循环甲', ['循环乙']),
  group('sub-a', '循环乙', ['循环甲']),
  group('sub-a', '出口循环甲', ['出口循环乙']),
  group('sub-a', '出口循环乙', ['出口循环甲', 'A'])
);
const plannedGroups = ClashConfigGenerator.planProxyGroups(configGroups, configNodes);
assert.deepEqual(plannedGroups.map((value) => value.name),
  ['基础策略', '嵌套策略', '出口循环甲', '出口循环乙']);
assert.deepEqual(plannedGroups[0].members, ['Alpha', 'Alpha (2)', 'Beta']);
assert.deepEqual(plannedGroups[1].members, ['基础策略']);
assert.deepEqual(plannedGroups[2].members, ['出口循环乙']);
assert.deepEqual(plannedGroups[3].members, ['Alpha', 'Alpha (2)']);

const selectionKey = ClashConfigGenerator.proxyGroupKey(plannedGroups[0]);
// 用字符串拼接构造 JSON：键是含 NUL 分隔符的订阅稳定键，JSON.stringify 负责加引号和转义。
const selectionJson = '{' + JSON.stringify(selectionKey) + ':"Beta","ignored":42}';
const parsedSelections = ClashConfigGenerator.parseProxyGroupSelections(selectionJson);
assert.equal(parsedSelections.get(selectionKey), 'Beta');
assert.equal(parsedSelections.has('ignored'), false);
assert.equal(ClashConfigGenerator.parseProxyGroupSelections('{broken').size, 0);

const settings = new AppSettings();
settings.proxyGroupSelections = '{' + JSON.stringify(selectionKey) + ':"Beta"}';
const generatedYaml = ClashConfigGenerator.generate(configNodes[0], configNodes, settings,
  7890, 9090, 'test-secret', false, false, {}, false, configGroups);
assert.ok(generatedYaml.includes('  - name: "基础策略"'));
assert.ok(generatedYaml.includes('  - name: "嵌套策略"'));
assert.equal(generatedYaml.includes('  - name: "空策略"'), false);
assert.equal(generatedYaml.includes('  - name: "循环甲"'), false);
assert.equal(generatedYaml.includes('  - name: "PROXY"'), true);
const baseGroupStart = generatedYaml.indexOf('  - name: "基础策略"');
const nestedGroupStart = generatedYaml.indexOf('  - name: "嵌套策略"');
const baseGroupYaml = generatedYaml.slice(baseGroupStart, nestedGroupStart);
assert.ok(baseGroupYaml.indexOf('      - "Beta"') < baseGroupYaml.indexOf('      - "Alpha"'));

// AppSettings 序列化往返：proxyGroupSelections 必须原样保留。
const settingsRoundTrip = AppSettings.fromJson(settings.toJson());
assert.equal(settingsRoundTrip.proxyGroupSelections, settings.proxyGroupSelections);

// 直接节点虚拟分组：计数随节点增删同步（0 → 1），UI 据此隐藏/显示 direct 分组。
const directSvc = new SubscriptionService();
directSvc.nodes = [];
directSvc.subscriptions = [{
  id: DIRECT_GROUP_ID, name: '直接节点', url: '', headerName: '', headerValue: '',
  lastFetchedAt: 0, lastRefreshResult: '', nodeCount: 0, enabled: true, sortOrder: 0
}];
assert.equal(directSvc.syncDirectGroup(), 0);
directSvc.nodes = [node('d1', DIRECT_GROUP_ID, '直连-A', '直连-A')];
assert.equal(directSvc.syncDirectGroup(), 1);
assert.equal(directSvc.subscriptions[0].nodeCount, 1);

console.log('group regression: PASS parser=3 lifecycle=PASS members=10 expanded=2 config-groups=PASS direct=PASS');
