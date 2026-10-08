# true-parser-harness —— 用**真实 ArkTS 源码**复现订阅解析缺陷

此前 `tools/verify_yaml_*.mjs` 都是**重新实现**解析逻辑（parseCore 等），无法证明
`YamlMerger.ets` 本身的真实行为。本 harness 直接执行真实源码。

## 用法

```powershell
# 1) 把真实 .ets 转成可在 Node 运行的 .ts（只剥离 import + 注入最小 util stub，逻辑一行不改）
node tools/true-parser-harness/prepare.mjs                       # 默认取工作区 .ets
node tools/true-parser-harness/prepare.mjs tools/true-parser-harness/YamlMerger.head.ets  # 指定版本对比

# 2) 运行（Node >= 22 的类型剥离）
node --experimental-strip-types tools/true-parser-harness/harness.mjs <yaml路径> <期望节点数>
```

`harness.mjs` 会打印：22 个条目逐条结果（OK / THROW+异常类型与消息 / NULL）、
真实 `merge` 可导入节点数、指纹冲突组、名称唯一性、`mergedToNodes` 门槛、
结构化槽位抽查、`toYaml` 往返，并在数量不符时 exit 1。

## 结论（样本 send_1789219702272_1_自建.yaml）

| 版本 | 结果 | 证据文件 |
| --- | --- | --- |
| 修复前（HEAD 4b46e8c） | 2 个（anytls-v6、wawo tuic）—— **与真机一致** | `evidence-before-fix.txt` |
| 修复后 | 21 个（22 条中 `直连 direct` 无 server，合法丢弃） | `evidence-after-fix.txt` |

根因见 `.ets` 中 `STRUCTURED_TYPES` 注释：`isRelayType()` 对任意合法小写 type 都返回
true，`relayMode` 因此对有结构化槽位的 vless/vmess/ss/ssr/trojan/hysteria2 也生效，
uuid/password 等被塞进 extraOpts → 必需字段校验把整条节点丢弃。

`YamlMerger.head.ets` = `git show HEAD:…/YamlMerger.ets` 的快照，仅用于复现修复前行为。
