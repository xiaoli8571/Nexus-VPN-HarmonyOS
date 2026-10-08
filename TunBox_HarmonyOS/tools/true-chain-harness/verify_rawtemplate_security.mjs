// verify_rawtemplate_security.mjs — 确认 rawTemplate 不含 name/凭据
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const here = dirname(fileURLToPath(import.meta.url));
const G = (n) => pathToFileURL(join(here, 'generated', n)).href;
const { YamlMerger } = await import(G('YamlMerger.ts'));
const { SubscriptionService } = await import(G('SubscriptionService.ts'));
const body = readFileSync(process.argv[2], 'utf8');
const merged = YamlMerger.merge([body], 'probe', '');
const nodes = SubscriptionService['mergedToNodes'](merged, 'probe-sub');
let leak = 0; let withTpl = 0;
for (const n of nodes) {
  if (n.rawTemplate && n.rawTemplate.length > 0) {
    withTpl++;
    if (/\buuid\b/i.test(n.rawTemplate) || /\bpassword\b/i.test(n.rawTemplate)
      || /\bname\b/i.test(n.rawTemplate) || /protocol-param/i.test(n.rawTemplate)
      || /obfs-password/i.test(n.rawTemplate)) {
      leak++;
      console.log('LEAK in:', n.name, '=>', n.rawTemplate.substring(0, 120));
    }
  }
}
console.log(`nodes=${nodes.length} withTemplate=${withTpl} credentialLeaks=${leak}`);
// 模拟持久化: fromNode 里 rawTemplate 是否落盘、rawYaml 是否仍空
const { ProxyNodeJson } = await import(G('SubscriptionService.ts'));
const j = ProxyNodeJson.fromNode(nodes[0]);
console.log('sample persisted: rawTemplate.len=' + (j.rawTemplate || '').length
  + ' rawYaml="' + j.rawYaml + '" rawUri.len=' + (j.rawUri || '').length);
