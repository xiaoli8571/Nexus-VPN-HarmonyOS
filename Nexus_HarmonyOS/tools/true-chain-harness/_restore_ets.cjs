// 一次性修复脚本：从 generated/SubscriptionService.ts 反向还原被 PowerShell 误转码的 .ets
const fs = require('fs');
const path = require('path');
const root = __dirname;
const gen = fs.readFileSync(path.join(root, 'tools/true-chain-harness/generated/SubscriptionService.ts'), 'utf8');
// 去掉 harness 头行
const body = gen.replace(/^\/\/ \[harness\][^\n]*\n/, '');

const DIRECT = {
  "'./ProxyNode.ts'": "'../models/ProxyNode'",
  "'./ProxyGroup.ts'": "'../models/ProxyGroup'",
  "'./Subscription.ts'": "'../models/Subscription'",
  "'./AppSettings.ts'": "'../models/AppSettings'",
  "'./SubscriptionParser.ts'": "'./SubscriptionParser'",
  "'./YamlMerger.ts'": "'./YamlMerger'",
  "'./ClashConfigGenerator.ts'": "'./ClashConfigGenerator'",
  "'./ProxyProviderParser.ts'": "'./ProxyProviderParser'",
  "'./ConcurrentRefresh.ts'": "'./ConcurrentRefresh'",
};

const lines = body.split('\n');
const out = [];
let stubCount = 0;
for (let raw of lines) {
  let line = raw;
  const m = line.match(/^(import\s+(?:type\s+)?(?:[\w$]+\s*,\s*)?)?\{([^}]*)\}(\s*from\s*)'\.\/stubs\.ts';(.*)$/);
  let lineIsStubImport = false;
  if (m) {
    // 单个 stubs.ts 导入还原
    lineIsStubImport = true;
  }
  if (lineIsStubImport || /from '\.\/stubs\.ts'/.test(line)) {
    const text = line;
    let spec = null;
    if (/\bpreferences\b/.test(text)) spec = '@kit.ArkData';
    else if (/\basset\b/.test(text)) spec = '@kit.AssetStoreKit';
    else if (/\butil\b/.test(text)) spec = '@kit.ArkTS';
    else if (/SubscriptionFetchPolicy|SubscriptionFetchError|SubscriptionFetchResult/.test(text)) spec = './SubscriptionFetchPolicy';
    else if (/RawSubscriptionStore|RawProviderStates|RawProviderStatus|RawProviderEntry/.test(text)) spec = './RawSubscriptionStore';
    else if (/CredentialStore|setCredentialLogger|loadMigrationFlag/.test(text)) spec = './CredentialStore';
    else if (/AppLogger|baseNodeName/.test(text)) spec = '../utils/AppLogger';
    if (spec !== null) {
      line = line.replace(/'\.\/stubs\.ts'/g, `'${spec}'`);
      stubCount++;
    }
  }
  for (const [k, v] of Object.entries(DIRECT)) {
    if (line.includes(k)) line = line.split(k).join(v);
  }
  out.push(line);
}
let text = out.join('\n');
// ProxyGroupJson 具名导入被 harness 移除，还原（prepare.mjs 的行为）
text = text.replace("import { ProxyGroup } from '../models/ProxyGroup';",
  "import { ProxyGroup, ProxyGroupJson } from '../models/ProxyGroup';");

// 校验：所有 import 不再有 .ts / stubs
const badImports = text.split('\n').filter(l => l.startsWith('import')).filter(l => /\.ts'|stubs/.test(l));
if (badImports.length > 0) {
  console.error('UNRESOLVED:', badImports);
  process.exit(2);
}
// 校验：没有 U+FFFD 与典型 GBK 乱码残留
if (/\uFFFD/.test(text)) { console.error('has replacement char'); process.exit(2); }
console.log('stub imports restored:', stubCount);
fs.writeFileSync(path.join(root, 'entry/src/main/ets/commons/services/SubscriptionService.ets'), text, 'utf8');
console.log('OK bytes:', Buffer.byteLength(text));
