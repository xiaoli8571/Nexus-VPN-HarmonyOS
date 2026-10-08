// tools/true-parser-harness/corpus_runner.mjs
// 用**真实源码**（YamlMerger.ets → YamlMerger.ts，见 prepare.mjs）执行脱敏语料库，
// 逐条断言：可导入节点数、结构化字段、extraOpts、去重语义、无效/跳过/限额统计、
// dialer-proxy 依赖诊断、toYaml 往返一致性，并打印每条用例的条目级解析结果（OK/THROW）。
//
// 运行:
//   node tools/true-parser-harness/prepare.mjs
//   node --experimental-strip-types tools/true-parser-harness/corpus_runner.mjs [--quiet]
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { corpus } from './fixtures/corpus.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const { YamlMerger } = await import(pathToFileURL(join(here, 'YamlMerger.ts')).href);
const quiet = process.argv.includes('--quiet');

const sourcesOf = (c) => (Array.isArray(c.yamls) ? c.yamls : [c.yaml]);
const extrasOf = (p) => {
  const map = new Map();
  for (const pair of YamlMerger.parseExtraOpts(p.extraOpts)) {
    map.set(String(pair[0]), String(pair[1]));
  }
  return map;
};

let pass = 0;
let fail = 0;
const coverageTags = new Set();

for (const c of corpus) {
  for (const t of c.tags) coverageTags.add(t);
  const problems = [];
  const notes = [];

  // 1) 条目级：真实 parseProxyItem 逐条 OK/THROW（失败条目不吞掉其它条目）
  const groups = YamlMerger.proxyItemGroups(c.yaml);
  let itemOk = 0;
  let itemThrow = 0;
  for (const g of groups) {
    try {
      if (YamlMerger.parseProxyItem(g) === null) {
        itemThrow = itemThrow + 1;
      } else {
        itemOk = itemOk + 1;
      }
    } catch (e) {
      itemThrow = itemThrow + 1;
      if (!quiet) {
        notes.push(`item THROW ${e && e.message ? e.message : String(e)}`);
      }
    }
  }

  // 2) 全流程 merge（含跨订阅去重 + 唯一名分配 + 限额）
  YamlMerger.resetSkipStats();
  let merged = [];
  let globalError = '';
  try {
    merged = YamlMerger.merge(sourcesOf(c), `corpus:${c.id}`, '');
  } catch (e) {
    globalError = `${e && e.constructor ? e.constructor.name : typeof e}`
      + `: ${e && e.message ? e.message : String(e)}`;
    if (c.expectGlobalError === undefined) {
      problems.push(`merge 抛出 ${globalError}`);
    }
  }

  // 2b) 全局限额用例：只断言「抛出 YamlMergeError + 文案」，其余依赖 merged 的断言跳过
  if (c.expectGlobalError !== undefined) {
    const want = c.expectGlobalError;
    if (globalError.length === 0) {
      problems.push(`期望全局限额抛错「${want}」，但合并成功返回 ${merged.length} 条`);
    } else if (!globalError.startsWith('YamlMergeError')) {
      problems.push(`全局限额必须抛 YamlMergeError，实际 ${globalError}`);
    } else if (!globalError.includes(want)) {
      problems.push(`全局限额错误文案不含「${want}」：${globalError}`);
    }
    const okLimit = problems.length === 0;
    if (okLimit) {
      pass = pass + 1;
    } else {
      fail = fail + 1;
    }
    console.log(`${okLimit ? '[PASS]' : '[FAIL]'} ${c.id.padEnd(38)} global-limit=${globalError || '未抛出'}`
      + ` tags=${c.tags.join(',')}`);
    if (c.notes) {
      console.log(`       note=${c.notes}`);
    }
    for (const p of problems) {
      console.log(`       !! ${p}`);
    }
    continue;
  }

  if (merged.length !== c.expectNodes) {
    problems.push(`可导入节点数 ${merged.length} != 期望 ${c.expectNodes}`);
  }
  for (const [i, field, want] of c.fields || []) {
    const node = merged[i];
    if (node === undefined) {
      problems.push(`字段检查失败: 缺少第 ${i} 个节点`);
    } else if (node[field] !== want) {
      problems.push(`第 ${i} 个节点 ${field}=${JSON.stringify(node[field])} != ${JSON.stringify(want)}`);
    }
  }
  for (const spec of c.extras || []) {
    const node = merged[spec.i];
    if (node === undefined) {
      problems.push(`extraOpts 检查失败: 缺少第 ${spec.i} 个节点`);
      continue;
    }
    const map = extrasOf(node);
    if (!map.has(spec.key)) {
      problems.push(`第 ${spec.i} 个节点缺少 extraOpts 键 ${spec.key}（现有: ${[...map.keys()].join('/') || '-'}）`);
    } else if (spec.has !== undefined && !map.get(spec.key).includes(spec.has)) {
      problems.push(`第 ${spec.i} 个节点 extraOpts.${spec.key}=${JSON.stringify(map.get(spec.key))} 不含 ${JSON.stringify(spec.has)}`);
    }
  }
  for (const [i, key] of c.extrasAbsent || []) {
    const node = merged[i];
    if (node !== undefined && extrasOf(node).has(key)) {
      problems.push(`第 ${i} 个节点出现了不应存在的 extraOpts 键 ${key}`);
    }
  }
  const names = merged.map((n) => n.name);
  if (new Set(names).size !== names.length) {
    problems.push(`产生了重名节点: ${names.join(' | ')}`);
  }
  for (const n of merged) {
    if (n.name.length === 0 || n.server.length === 0 || !(n.port > 0 && n.port <= 65535)) {
      problems.push(`节点缺少必需字段: name=${JSON.stringify(n.name)} server=${JSON.stringify(n.server)} port=${n.port}`);
    }
  }
  if (c.invalidCount !== undefined && YamlMerger.lastInvalidCount !== c.invalidCount) {
    problems.push(`lastInvalidCount=${YamlMerger.lastInvalidCount} != 期望 ${c.invalidCount}`
      + `（reasons: ${YamlMerger.lastInvalidReasons.join(' / ') || '-'}）`);
  }
  for (const want of c.reasons || []) {
    if (!YamlMerger.lastInvalidReasons.some((r) => r.includes(want))) {
      problems.push(`lastInvalidReasons 缺少原因「${want}」（现有: ${YamlMerger.lastInvalidReasons.join(' / ') || '-'}）`);
    }
  }
  if (c.skippedCount !== undefined && YamlMerger.lastSkippedCount !== c.skippedCount) {
    problems.push(`lastSkippedCount=${YamlMerger.lastSkippedCount} != 期望 ${c.skippedCount}`);
  }
  const limitSkipped = YamlMerger.lastLimitSkippedCount === undefined ? 0 : YamlMerger.lastLimitSkippedCount;
  const limitReasons = YamlMerger.lastLimitSkippedReasons === undefined ? [] : YamlMerger.lastLimitSkippedReasons;
  const dialerMissing = YamlMerger.lastDialerProxyMissing === undefined ? 0 : YamlMerger.lastDialerProxyMissing;
  const dialerBroken = YamlMerger.lastDialerProxyBroken === undefined ? 0 : YamlMerger.lastDialerProxyBroken;
  const dialerReasons = YamlMerger.lastDialerProxyReasons === undefined ? [] : YamlMerger.lastDialerProxyReasons;
  if (c.limitSkippedCount !== undefined && limitSkipped !== c.limitSkippedCount) {
    problems.push(`lastLimitSkippedCount=${limitSkipped} != 期望 ${c.limitSkippedCount}`
      + `（reasons: ${limitReasons.join(' / ') || '-'}）`);
  }
  if (c.dialerMissing !== undefined && dialerMissing !== c.dialerMissing) {
    problems.push(`lastDialerProxyMissing=${dialerMissing} != 期望 ${c.dialerMissing}`
      + `（reasons: ${dialerReasons.join(' / ') || '-'}）`);
  }
  if (c.dialerBroken !== undefined && dialerBroken !== c.dialerBroken) {
    problems.push(`lastDialerProxyBroken=${dialerBroken} != 期望 ${c.dialerBroken}`);
  }
  const invalidCount = YamlMerger.lastInvalidCount;
  const skippedCount = YamlMerger.lastSkippedCount;
  const limitCount = limitSkipped;
  const reasons = YamlMerger.lastInvalidReasons.join('/') || '-';

  // 3) 序列化往返：toYaml → re-merge 必须还是同样可导入条数（不丢字段）
  let roundtrip = '-';
  if (merged.length > 0) {
    try {
      const roundtripNodes = YamlMerger.merge([YamlMerger.toYaml(merged)], `corpus:${c.id}`, '');
      roundtrip = String(roundtripNodes.length);
      if (roundtripNodes.length !== merged.length) {
        problems.push(`toYaml 往返丢节点: ${merged.length} -> ${roundtripNodes.length}`);
      }
    } catch (e) {
      roundtrip = 'THROW';
      problems.push(`toYaml 往返抛出: ${e && e.message ? e.message : String(e)}`);
    }
  }

  const ok = problems.length === 0;
  if (ok) {
    pass = pass + 1;
  } else {
    fail = fail + 1;
  }
  const line = `${ok ? '[PASS]' : '[FAIL]'} ${c.id.padEnd(38)} nodes=${merged.length}/${c.expectNodes}`
    + ` items=ok${itemOk}/throw${itemThrow} invalid=${invalidCount} skipped=${skippedCount} limit=${limitCount}`
    + ` roundtrip=${roundtrip} tags=${c.tags.join(',')}`;
  console.log(line);
  if (invalidCount > 0 || skippedCount > 0 || limitCount > 0) {
    console.log(`       invalid-reasons=${reasons}`);
  }
  if (dialerReasons.length > 0) {
    console.log(`       dialer-proxy: missing=${dialerMissing} broken=${dialerBroken}`
      + ` reasons=${dialerReasons.join(' / ')}`);
  }
  if (c.notes) {
    console.log(`       note=${c.notes}`);
  }
  for (const n of notes) {
    console.log(`       ${n}`);
  }
  for (const p of problems) {
    console.log(`       !! ${p}`);
  }
}

console.log(`\n[corpus] 用例 ${corpus.length} 条: PASS=${pass} FAIL=${fail}`);
console.log(`[corpus] 覆盖标签 ${coverageTags.size} 类: ${[...coverageTags].sort().join(', ')}`);
if (fail > 0) {
  console.log('[corpus] 存在失败用例');
  process.exit(1);
}
console.log('[corpus] 全部通过');
