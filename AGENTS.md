## 会话记忆（recall MCP）

### 会话开始时
开始任何非平凡任务前，先 `retrieve_memory` 查一次（用自然语言描述你正要干的事），
看看有没有既有的坑、决定和上下文。第一次没查到就换个说法再查一次。

### 会话结束时 —— 必须写一条总结，这不是可选项
在给出本次会话的最终答复之前，你必须调用 `store_memory` 写一条会话总结。
不要等用户提醒，也不要因为"这次没干什么"就跳过。

- **key**：`session.<YYYY-MM-DD>.<主题-kebab-case>`，例如 `session.2026-09-11.recall-deploy`
- **memory_type**：`episodic`
- **importance**：`0.5`–`0.7`（总结是索引，不是核心事实）
- **tags**：`["session-summary"]`，再加 1–2 个主题/项目标签
- **namespace**：当前项目名（见命名空间约定）
- **content 必须回答这四个问题**，写 3–8 行：
  1. 这次做了什么 —— 具体到文件、命令、接口
  2. 定了哪些决定，**以及为什么**
  3. 踩了什么坑，下次怎么绕开
  4. 还有什么没做完 / 下一步

如果会话中途上下文被压缩（compaction），也要先写一条总结再继续。

### 反例 —— 不要这样做
不要把原始对话逐条塞进记忆库。那样会产生大量近似条目，检索时互相稀释，
等于没有记忆；而且机械转存经常连编码都保不住（中文变乱码）。
总结必须是**你消化过的结论**，不是**抄下来的原文**。

### 除此之外什么时候还要存
任务中遇到非显而易见的东西时，随时存单条，不必等会话结束：
bug 根因、文档没写的 API 行为、架构决定及其理由、用户明确说过的"别这么干"、
跨文件约束、环境特有的坑。
**永远不要存**：API key、token、密码、私钥、cookie；读代码/git log 就能得到的东西；
一次性任务状态。

## Recall 命名空间约定

- 本项目的代码、构建、产品和基础设施事实使用 `SSRVPN-HarmonyOS`。
- 跨项目通用偏好和事实使用 `global`。
- Agent 自身配置、skill、MCP 和行为笔记使用 `hermes`。
- 复盘、教训和发布记录使用 `retro`。
- 可复用调研结论和选型对比使用 `research`。
- Recall 记忆库自身的运维经验使用 `recall`。
- `namespace` 是检索过滤器，不是权限边界；写入时不得省略。

## 打包与发布 Skill（Nexus 专属）

涉及「打包 HAP/APP、签名、推 GitHub、发 Release」时，先读对应 skill 再动手：

- 打包：`C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\skills\nexus-pack\SKILL.md`（版本号规则、构建命令、签名流程，含签名密钥）
- 推送：`C:\Users\xiaoli\Downloads\Agent-WorkerSpaces\skills\nexus-push\SKILL.md`（git 白名单提交、token 推 neworigin、GitHub Release 与附件上传，含令牌）
- **主远程是 `neworigin`（xiaoli8571/Nexus-VPN-HarmonyOS）**；origin（SSRVPN_Harmony）已冻结，不要推。
- 两个 SKILL.md 含密钥，在仓库外、永不提交；不要把密钥写进任何被 git 跟踪的文件。
