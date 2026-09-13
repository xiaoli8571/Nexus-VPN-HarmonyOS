// tools/true-parser-harness/prepare.mjs
// 把真实 ArkTS 源码 entry/src/main/ets/commons/services/YamlMerger.ets 转成
// 可在 Node 直接运行的 .ts：仅替换 import 语句与 util 系统能力，解析逻辑一字不改。
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

const STUB = `// ==== BEGIN harness stub (注入, 非源码内容) ====
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

let text = readFileSync(srcPath, 'utf8');
const importRe = /^\s*import\s+[^;]*?from\s*['"](@[^'"]+|[^'"]*\.ets)['"];?\s*$/gm;
let stripped = 0;
text = text.replace(importRe, (m) => {
  stripped++;
  return `// [harness-stripped] ${m.trim()}`;
});
if (!text.includes('const util = {')) {
  text = STUB + text;
}
writeFileSync(outPath, text, 'utf8');
console.log(`[prepare] src=${srcPath}`);
console.log(`[prepare] out=${outPath} stripped-imports=${stripped} bytes=${Buffer.byteLength(text)}`);
