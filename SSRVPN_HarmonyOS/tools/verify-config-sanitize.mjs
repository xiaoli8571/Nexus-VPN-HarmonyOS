#!/usr/bin/env node
/**
 * node tools/verify-config-sanitize.mjs (Node 24+)
 * 背景（用户真机 2026-09-18）：mihomo yaml.v3 对 C0 控制符(除\t\n\r)、0x7F-0x84、
 * 0x86-0x9F 报 "control characters are not allowed"，整份配置拒载 → 内核启动失败。
 * EXEC: 真实 sanitizeControlChars / friendlyVpnStartError 源码执行。
 * SOURCE: 三个净化出口 + 友好错误映射的接线断言。
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const read = p => readFileSync(resolve(root, p), 'utf8');
let passed = 0; let failed = 0;
const check = async (name, fn) => {
  try { await fn(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.log('FAIL ' + name + ' -> ' + e.message); }
};

const gen = read('entry/src/main/ets/commons/services/ClashConfigGenerator.ets');
const pol = read('entry/src/main/ets/commons/services/VpnRecoveryPolicy.ets');
const ext = read('entry/src/main/ets/vpnability/VpnExtensionAbility.ets');

const grab = (source, startMark, label, endMark = '\n  }') => {
  const start = source.indexOf(startMark);
  assert.ok(start >= 0, 'extract ' + label);
  const end = source.indexOf(endMark, start);
  assert.ok(end > start, 'close of ' + label);
  return source.slice(start, end + endMark.length);
};

// EXEC sanitizeControlChars
const sanitizeSrc = stripTypeScriptTypes(
  'const ClashConfigGenerator = { ' + grab(gen, 'static sanitizeControlChars(value: string): string {', 'sanitize').replace(/^static /, '') + ' };',
  { mode: 'strip' });
const sanitizeMod = { exports: {} };
new Function('exports', sanitizeSrc + '\nexports.sanitize = ClashConfigGenerator.sanitizeControlChars;')(sanitizeMod.exports);
const sanitize = sanitizeMod.exports.sanitize;

// EXEC friendlyVpnStartError
const friendlySrc = stripTypeScriptTypes(
  grab(pol, 'export function friendlyVpnStartError', 'friendly', '\n}').replace(/^export /, ''),
  { mode: 'strip' });
const friendlyMod = { exports: {} };
new Function('exports', friendlySrc + '\nexports.friendly = friendlyVpnStartError;')(friendlyMod.exports);
const friendly = friendlyMod.exports.friendly;

const FORBIDDEN = [];
for (let c = 0; c <= 0x1f; c++) if (c !== 0x09 && c !== 0x0a && c !== 0x0d) FORBIDDEN.push(c);
for (let c = 0x7f; c <= 0x84; c++) FORBIDDEN.push(c);
for (let c = 0x86; c <= 0x9f; c++) FORBIDDEN.push(c);

await check(`EXEC sanitize removes all ${FORBIDDEN.length} yaml-illegal codepoints`, () => {
  for (const code of FORBIDDEN) {
    const ch = String.fromCharCode(code);
    const out = sanitize('a' + ch + 'b');
    assert.ok(!out.includes(ch), 'leaked 0x' + code.toString(16));
    assert.equal(out.length, 3);
  }
});
await check('EXEC sanitize preserves legal yaml text incl. cjk/emoji/newlines', () => {
  const keep = '香港节点 01 🚀 path:/a?ed=2048\nkey: "v"';
  assert.equal(sanitize(keep), keep);
});
await check('EXEC sanitize maps tab/CR to space (never raw)', () => {
  const out = sanitize('x\ty\rz');
  assert.equal(out, 'x y z');
});
await check('EXEC friendly maps create() conflict codes', () => {
  assert.match(friendly(2203002, 'x'), /另一个 VPN/);
  assert.match(friendly(2203001, 'x'), /拒绝了/);
  assert.match(friendly(2200002, 'x'), /网络服务/);
  assert.match(friendly(2200001, 'x'), /参数/);
  assert.equal(friendly(-1, 'boom'), 'VPN 扩展启动异常: boom');
});

await check('SOURCE generator final return is sanitized (last-resort gate)', () => {
  assert.match(gen, /return ClashConfigGenerator\.sanitizeControlChars\(lines\.join\('\\n'\)/);
});
await check('SOURCE both verbatim embed sites sanitized (wsExtras raw + rawTemplate)', () => {
  assert.match(gen, /out\.push\(\[sub, ClashConfigGenerator\.sanitizeControlChars\(value\)\]\)/);
  assert.match(gen, /rawParts: string\[\] = \[`name: \$\{q\(n\.name\)\}`, ClashConfigGenerator\.sanitizeControlChars\(n\.rawTemplate\)\]/);
});
await check('SOURCE extension uses friendly mapping with code extraction', () => {
  assert.ok(ext.includes('friendlyVpnStartError(code, msg)'), 'friendly call');
  assert.ok(ext.includes('typeof err.code'), 'code extraction');
});

// ── 2026-09-18 真机三报错修复的回归断言 ────────────────────────────────
await check('EXEC friendly maps kernel parse failures & empty/[object Object] text', () => {
  assert.match(friendly(-1, 'parse config :proxy "12": has unset fields:password'), /凭据|刷新订阅/);
  assert.match(friendly(-1, 'parse config: yaml: control characters are not allowed'), /控制字符|刷新订阅/);
  assert.match(friendly(-1, ''), /无详细信息/);
  assert.match(friendly(-1, '[object Object]'), /无详细信息/);
  assert.equal(friendly(-1, 'boom'), 'VPN 扩展启动异常: boom');
});

await check('SOURCE ensureConfigMtu rewrites via fresh TRUNC fd (no NUL-hole read-modify-write)', () => {
  const fn = grab(ext, 'private ensureConfigMtu(): void {', 'ensureConfigMtu');
  assert.ok(!fn.includes('truncateSync'), 'shared-fd truncate+write is the bug (POSIX keeps offset)');
  assert.match(fn, /fs\.OpenMode\.READ_WRITE \| fs\.OpenMode\.CREATE \| fs\.OpenMode\.TRUNC/, 'fresh trunc fd rewrite');
});

await check('SOURCE provider raw subscription sanitized before persisting', () => {
  const raw = read('entry/src/main/ets/commons/services/RawSubscriptionStore.ets');
  assert.match(raw, /writePrivate\(path, RawSubscriptionStore\.stripControlChars\(content\)\)/);
  // 与生成器规则逐字一致（同一 keep-map）
  const copy = grab(raw, 'private static stripControlChars(value: string): string {', 'stripCopy');
  const genBody = grab(gen, 'static sanitizeControlChars(value: string): string {', 'sanitize');
  const norm = s => s.replace(/stripControlChars|sanitizeControlChars/g, 'FN').replace(/\s+/g, ' ');
  assert.ok(norm(copy).includes(norm(genBody).slice(norm(genBody).indexOf('{'))), 'rule drift between copies');
});

await check('SOURCE dropReasonFor gates relay protocols that require credentials', () => {
  assert.match(gen, /proxyType === 'tuic'[\s\S]{0,120}MISSING_CREDENTIAL/);
  assert.match(gen, /proxyType === 'hysteria'[\s\S]{0,220}MISSING_CREDENTIAL/);
  assert.match(gen, /proxyType === 'anytls'[\s\S]{0,80}MISSING_CREDENTIAL/);
});

await check('SOURCE no user-facing String(e) ternaries remain ([object Object] class)', () => {
  for (const p of [
    'entry/src/main/ets/vpnability/VpnExtensionAbility.ets',
    'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets',
    'entry/src/main/ets/commons/services/VpnQuickStart.ets']) {
    assert.ok(!read(p).includes('instanceof Error ? e.message : String(e)'), p);
  }
  const logger = read('entry/src/main/ets/commons/utils/AppLogger.ets');
  assert.match(logger, /static errText\(e: Object\): string/);
});

console.log(`\nConfig-sanitize verification: ${passed} passed, ${failed} failed (EXEC real functions; no device).`);
if (failed > 0) process.exitCode = 1;
