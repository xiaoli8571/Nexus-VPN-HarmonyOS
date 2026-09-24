// append_groups.mjs — 把订阅原始 proxy-groups 段拼到探针配置后（UTF-8 安全）
import { readFileSync, writeFileSync } from 'node:fs';
const [cfgPath, subPath] = process.argv.slice(2);
const sub = readFileSync(subPath, 'utf8');
let cfg = readFileSync(cfgPath, 'utf8');
if (!cfg.endsWith('\n')) cfg += '\n';
const i = sub.indexOf('proxy-groups:');
let j = sub.indexOf('\nrules:', i);
if (j < 0) j = sub.length;
cfg += sub.substring(i, j) + '\n';
writeFileSync(cfgPath, cfg);
console.log('groups appended, config bytes:', Buffer.byteLength(cfg));
