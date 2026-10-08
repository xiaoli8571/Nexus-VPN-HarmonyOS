// tools/true-chain-harness/run_raw.mjs — 对 _audit/input/raw/*.yaml 逐个跑真实链路并汇总
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { analyzeBody } from './chain.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const raw = join(here, '..', '..', '..', '_audit', 'input', 'raw');
const files = readdirSync(raw);
const keys = ['bytes', 'rawEntries', 'groups', 'parseOk', 'parseThrow', 'parseNull', 'parseThrowSamples',
  'skippedTypes', 'merged', 'dupByFingerprint', 'mergeSkippedUnsupported', 'mergedToNodes',
  'droppedByServerPort', 'persistedRecords', 'restoredAfterReload', 'droppedOnReload',
  'configKeptNodes', 'droppedAtConfigGen', 'configDropReasons', 'serviceStatus', 'serviceNodeCount', 'serviceNodes'];
for (const f of files) {
  const body = readFileSync(join(raw, f), 'utf8');
  const entry = /(^|\n)proxies:/.test(body) ? 'url' : 'links';
  const r = await analyzeBody(body, { entry, name: f.replace('.yaml', ''), id: 'raw-sub' });
  console.log(`\n===== ${f} (entry=${entry}) =====`);
  for (const k of keys) { if (k in r) console.log(`  ${k.padEnd(22)} ${JSON.stringify(r[k])}`); }
}
