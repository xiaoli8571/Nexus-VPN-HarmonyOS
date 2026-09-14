// tools/true-chain-harness/prepare.mjs
// 把**真实 ArkTS 源码**转成 Node 可执行的 .ts，仅重写 import 目标 + 注入系统能力 stub，
// 解析/合并/映射逻辑一行不改。与 tools/true-parser-harness/prepare.mjs 同一思路，
// 但覆盖整条链路：ProxyNode → YamlMerger → SubscriptionParser → SubscriptionService
// → ClashConfigGenerator。
//
// 运行: node tools/true-chain-harness/prepare.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const ets = join(repo, 'entry/src/main/ets');
const outDir = join(here, 'generated');
mkdirSync(outDir, { recursive: true });

// 每个真实源文件 → 输出名 + 模块说明符重写表
const FILES = [
  { src: 'commons/models/ProxyNode.ets', out: 'ProxyNode.ts', map: { '@kit.ArkTS': './stubs.ts' } },
  { src: 'commons/models/ProxyGroup.ets', out: 'ProxyGroup.ts', map: {} },
  {
    src: 'commons/services/YamlMerger.ets', out: 'YamlMerger.ts',
    map: { '@kit.ArkTS': './stubs.ts' },
  },
  {
    src: 'commons/services/SubscriptionParser.ets', out: 'SubscriptionParser.ts', map: {
      '../models/ProxyNode': './ProxyNode.ts',
      '../models/ProxyGroup': './ProxyGroup.ts',
      './YamlMerger': './YamlMerger.ts',
      '../utils/AppLogger': './stubs.ts',
    },
  },
  {
    src: 'commons/models/Subscription.ets', out: 'Subscription.ts', map: {
      '../services/SubscriptionService': './stubs.ts',
    },
  },
  {
    src: 'commons/services/NodeSortPersistence.ets', out: 'NodeSortPersistence.ts', map: {
      '../models/ProxyNode': './ProxyNode.ts',
      './ClashApiService': './stubs.ts',
    },
  },
  {
    src: 'commons/models/AppSettings.ets', out: 'AppSettings.ts', map: {
      '../services/NodeSortPersistence': './NodeSortPersistence.ts',
    },
  },
  {
    src: 'commons/services/SubscriptionService.ets', out: 'SubscriptionService.ts', map: {
      '@kit.ArkData': './stubs.ts',
      '@kit.AssetStoreKit': './stubs.ts',
      '@kit.ArkTS': './stubs.ts',
      '../models/Subscription': './Subscription.ts',
      '../models/ProxyNode': './ProxyNode.ts',
      '../models/ProxyGroup': './ProxyGroup.ts',
      '../models/AppSettings': './AppSettings.ts',
      './SubscriptionParser': './SubscriptionParser.ts',
      './SubscriptionFetchPolicy': './stubs.ts',
      './YamlMerger': './YamlMerger.ts',
      './ClashConfigGenerator': './ClashConfigGenerator.ts',
      './ProxyProviderParser': './ProxyProviderParser.ts',
      './RawSubscriptionStore': './stubs.ts',
      './CredentialStore': './stubs.ts',
      '../utils/AppLogger': './stubs.ts',
      './ConcurrentRefresh': './ConcurrentRefresh.ts',
    },
  },
  {
    src: 'commons/services/ProxyProviderParser.ets', out: 'ProxyProviderParser.ts', map: {
      '../utils/AppLogger': './stubs.ts',
      './YamlMerger': './YamlMerger.ts',
    },
  },
  {
    src: 'commons/services/ConcurrentRefresh.ets', out: 'ConcurrentRefresh.ts', map: {},
  },
  {
    src: 'commons/services/ClashConfigGenerator.ets', out: 'ClashConfigGenerator.ts', map: {
      '../models/ProxyNode': './ProxyNode.ts',
      '../models/AppSettings': './AppSettings.ts',
      './YamlMerger': './YamlMerger.ts',
      '../utils/AppLogger': './stubs.ts',
      './RawSubscriptionStore': './stubs.ts',
    },
  },
];

// 匹配 import ... from 'spec'（含多行命名导入）与 import spec from 'spec'
const IMPORT_RE = /import\s+(?:type\s+)?(?:([A-Za-z_$][\w$]*)\s*,\s*)?(?:\{([^}]*)\}|\*\s+as\s+[A-Za-z_$][\w$]*|([A-Za-z_$][\w$]*))?\s*from\s*'([^']+)'/g;

const REPORT = [];
for (const f of FILES) {
  const srcPath = join(ets, f.src);
  const orig = readFileSync(srcPath, 'utf8');
  const unresolved = [];
  const stripped = [];
  const text = orig.replace(IMPORT_RE, (m, def1, named, def2, spec) => {
    const target = f.map[spec];
    if (target === undefined) {
      unresolved.push(spec);
      return `/* [harness-UNRESOLVED] ${m} */`;
    }
    if (target === './stubs.ts') {
      stripped.push(spec);
    }
    // 只改模块说明符，保留导入形式
    return m.replace(`'${spec}'`, `'${target}'`);
  });
  if (unresolved.length > 0) {
    console.error(`[prepare] FAIL ${f.src}: unresolved imports -> ${unresolved.join(', ')}`);
    process.exit(2);
  }
  // Node 的 transform-types 会擦除 interface，但不会自动擦除普通具名导入。
  // ProxyGroupJson 仅用于类型标注，生成 harness 时移除该运行时导入项。
  const runnableText = text.replace(
    "import { ProxyGroup, ProxyGroupJson } from './ProxyGroup.ts';",
    "import { ProxyGroup } from './ProxyGroup.ts';"
  );
  const header = `// [harness] generated from entry/src/main/ets/${f.src} — 仅 import 目标被重写\n`;
  writeFileSync(join(outDir, f.out), header + runnableText, 'utf8');
  const changed = text.split('\n').filter((l, i) => l !== orig.split('\n')[i]).length;
  REPORT.push({ src: f.src, out: f.out, lines: orig.split('\n').length, rewrittenImportLines: changed, stubbed: stripped.join(',') || '-' });
}
for (const r of REPORT) {
  console.log(`[prepare] ${r.src} -> generated/${r.out} lines=${r.lines} rewrittenImportLines=${r.rewrittenImportLines} stubSources=${r.stubbed}`);
}
// 手写的测试替身（系统能力/网络/持久化边界）复制到 generated/，使重写后的相对导入可解析
const stubSrc = readFileSync(join(here, 'stubs.ts'), 'utf8');
writeFileSync(join(outDir, 'stubs.ts'), stubSrc, 'utf8');
console.log('[prepare] stubs.ts -> generated/stubs.ts (hand-written test double, no parsing logic)');
