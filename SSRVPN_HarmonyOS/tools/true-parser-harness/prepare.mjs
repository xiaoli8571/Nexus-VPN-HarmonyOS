// tools/true-parser-harness/prepare.mjs
// 把真实 ArkTS 源码转成可在 Node 直接运行的 .ts（仅替换 import 语句与系统能力 stub，
// 解析逻辑一字不改）：
//   1) entry/src/main/ets/commons/services/YamlMerger.ets        -> tools/true-parser-harness/YamlMerger.ts
//   2) entry/src/main/ets/commons/services/ProxyProviderParser.ets -> tools/true-parser-harness/ProxyProviderParser.ts
//      （后者 import 的真实 YamlMerger 被改指到同目录的 YamlMerger.ts，因此 provider 解析
//        走的仍是真实 YamlMerger 源码）
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
// argv[2] 可指向任意版本的 YamlMerger.ets（例如 `git show HEAD:... > YamlMerger.head.ets`），
// 用于对比修复前后同一份真实源码的行为。
const srcPath = process.argv[2]
  ? process.argv[2]
  : join(repo, 'entry/src/main/ets/commons/services/YamlMerger.ets');
const outPath = join(here, 'YamlMerger.ts');
const providerSrc = join(repo, 'entry/src/main/ets/commons/services/ProxyProviderParser.ets');
const providerOut = join(here, 'ProxyProviderParser.ts');

const UTIL_STUB = `// ==== BEGIN harness stub (注入, 非源码内容) ====
// 最小 stub: @kit.ArkTS 的 util.TextEncoder -> Buffer 实现 (UTF-8 字节数一致)
const util = {
  TextEncoder: {
    create(_enc: string) {
      return {
        encodeInto(s: string): Uint8Array {
          return new Uint8Array(Buffer.from(s, 'utf8'));
        },
      };
    },
  },
  generateRandomUUID(): string {
    return globalThis.crypto.randomUUID();
  },
};
// ==== END harness stub ====
`;

const LOGGER_STUB = `// ==== BEGIN harness stub (注入, 非源码内容) ====
// 最小 AppLogger stub: 只吞日志, 不改变任何解析行为
const AppLogger = {
  info(_tag: string, _message: string): void {},
  warn(_tag: string, _message: string): void {},
  error(_tag: string, _message: string): void {},
};
// ==== END harness stub ====
`;

/** 剥离 ArkTS 侧 import（@kit.* 与 *.ets）：这些模块在 Node 里不存在，靠 stub 顶上 */
function stripArkImports(text) {
  const re = /^\s*import\s+[^;]*?from\s*['"](@[^'"]+|[^'"]*\.ets)['"];?\s*$/gm;
  let stripped = 0;
  const out = text.replace(re, (m) => {
    stripped++;
    return `// [harness-stripped] ${m.trim()}`;
  });
  return { out, stripped };
}

// 1) YamlMerger.ets -> YamlMerger.ts
{
  let text = readFileSync(srcPath, 'utf8');
  const { out, stripped } = stripArkImports(text);
  text = out;
  if (!text.includes('const util = {')) {
    text = UTIL_STUB + text;
  }
  writeFileSync(outPath, text, 'utf8');
  console.log(`[prepare] src=${srcPath}`);
  console.log(`[prepare] out=${outPath} stripped-imports=${stripped} bytes=${Buffer.byteLength(text)}`);
}

// 2) ProxyProviderParser.ets -> ProxyProviderParser.ts
{
  let text = readFileSync(providerSrc, 'utf8');
  // 真实 YamlMerger 源码 -> 同目录已生成的 YamlMerger.ts（provider 解析链与 App 完全一致）
  text = text.replace(/from\s*'\.\/YamlMerger'/g, "from './YamlMerger.ts'");
  const { out, stripped } = stripArkImports(text);
  text = out;
  if (!text.includes('const AppLogger = {')) {
    text = LOGGER_STUB + text;
  }
  writeFileSync(providerOut, text, 'utf8');
  console.log(`[prepare] src=${providerSrc}`);
  console.log(`[prepare] out=${providerOut} stripped-imports=${stripped} bytes=${Buffer.byteLength(text)}`);
}
