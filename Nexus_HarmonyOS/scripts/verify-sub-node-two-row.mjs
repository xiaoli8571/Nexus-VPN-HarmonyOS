/**
 * 订阅页节点行「两行化」改造自检（结构断言）。
 *
 * 需求：订阅页展开后的节点行，原来「名称 + 协议徽标 + 延迟」三者并在一行，窄屏下
 * 名称被截断、协议被 layoutWeight(1) 压成残字。改为两行：
 *   第一行 = 节点名称 + 延迟
 *   第二行 = 协议（独占一行）
 *
 * 本脚本不做完整 ArkTS 解析（无 DevEco SDK），只对源码做结构断言 + 括号平衡，
 * 与仓库既有 verify-*.mjs 的「文本断言」风格一致。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const file = path.join(here, '..', 'entry', 'src', 'main', 'ets', 'pages', 'SubscriptionPage.ets');
const src = fs.readFileSync(file, 'utf8');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fails.push(name + (extra ? ` (${extra})` : '')); console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`); }
}

console.log('\n订阅页节点行两行化改造自检');

// 注：括号配平由 verify-sub-brace-balance.mjs 的逐字符状态机负责
// （朴素计数会把 ArkUI 链式属性与正则字面量里的 (){} 误计入，原文件也数不对）。

// ── 1. 两行结构存在且顺序正确 ──
const nameRowIdx = src.indexOf('// 第一行：节点名称 + 延迟');
const protoIdx = src.indexOf('// 第二行：协议（独占一行，名称下方）');
ok('第一行注释存在', nameRowIdx > 0);
ok('第二行注释存在', protoIdx > 0);
ok('协议行在名称行之后', nameRowIdx > 0 && protoIdx > nameRowIdx);

// ── 3. 名称拿满宽度，延迟不参与挤压 ──
ok('名称 layoutWeight(1)', /Text\(node\.name\)[\s\S]{0,250}?layoutWeight\(1\)/.test(src));
ok('协议行 maxLines(1)', /第二行：协议[\s\S]{0,500}?maxLines\(1\)/.test(src));
ok('协议行 width(100%)', /第二行：协议[\s\S]{0,500}?width\('100%'\)/.test(src));

// ── 4. 旧「三件套一行」已拆除（协议不再是名称 Text 的兄弟节点）──
ok('协议不再与名称同一 Row',
  !/Text\(node\.name\)[\s\S]{0,400}?Text\(this\.protoOf\(node\)\)/.test(src));

// ── 5. 协议来源切到 NodeProtocolPolicy（与 NodeSelectionPage 同口径）──
const codeOnly = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
ok('protoOf 复用 NodeProtocolPolicy', /NodeProtocolPolicy\.fromNode\(node\)\.display\(\)/.test(src));
ok('import NodeProtocolPolicy',
  /import \{ NodeProtocolPolicy \} from '\.\.\/commons\/services\/NodeSortPersistence';/.test(src));
// 只查代码：slice(0,8) 在注释里作为「旧实现说明」合法存在
ok('代码中无 slice(0, 8) 硬截断', !/toUpperCase\(\)\.slice\(0, 8\)/.test(codeOnly));

// ── 6. Column 容器拿满剩余宽度 ──
// 不用「注释后 N 字符内出现」的窗口断言：距离随注释长度漂移，很脆。
// 改为截取 Column 块（从「两行信息列」注释到 ForEach 行尾 .onClick）再判。
const colIdx = src.indexOf('// ── 两行信息列 ──');
ok('两行信息列注释存在', colIdx > 0);
const colBlock = colIdx > 0
  ? src.slice(colIdx, src.indexOf('.onClick(() => this.selectNode(node))', colIdx))
  : '';
ok('Column 块可截取', colBlock.length > 0 && colBlock.length < 4000, `len=${colBlock.length}`);
ok('Column layoutWeight(1)', /\.layoutWeight\(1\)/.test(colBlock));
ok('Column alignItems(Start)', /alignItems\(HorizontalAlign\.Start\)/.test(colBlock));
ok('Column 以 Column({ space: 3 }) 开头', /Column\(\{ space: 3 \}\)/.test(colBlock));

// ── 7. 选中态/点击行为未受影响 ──
ok('选中点击仍绑 selectNode', /\.onClick\(\(\) => this\.selectNode\(node\)\)/.test(src));
ok('延迟仍走 NexusPing', /NexusPing\.text\(this\.pingOf\(node\)\)/.test(src));

console.log(`\n自检结果：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（名称 + 延迟在第一行，协议独占第二行）');
