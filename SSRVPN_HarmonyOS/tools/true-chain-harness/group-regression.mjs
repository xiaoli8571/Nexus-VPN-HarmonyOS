// 使用 prepare.mjs 从真实 ArkTS 生成的模块验证代理组身份映射与展开语义。
import assert from 'node:assert/strict';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const generated = (name) => pathToFileURL(join(here, 'generated', name)).href;
const { SubscriptionService } = await import(generated('SubscriptionService.ts'));
const { SubscriptionParser } = await import(generated('SubscriptionParser.ts'));
const { ProxyGroup } = await import(generated('ProxyGroup.ts'));
const { ProxyNode } = await import(generated('ProxyNode.ts'));
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

console.log('group regression: PASS parser=3 lifecycle=PASS members=10 expanded=2');
