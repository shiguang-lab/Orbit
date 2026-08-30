# OmniRoute Fork 二开与上游自动同步方案（本地驱动版）

> 记录日期：2026-08-29。
> 关联文档：`FORK_TODO_CN.md`（二开变更、合并规则与回归台账，其中每次追上游后的核对与聚焦回归由本方案自动化）、
> `OMNIROUTE_DEPLOYMENT_CN.md`（源码构建与 NAS 部署，`release.sh` 按其 §4.4 的 `runner-base` 目标构建）。
> 配套工件：`fork-sync-kit/`（复制进 fork 仓库即可使用，清单见 §5）。

## 0. 结论（TL;DR）

1. **治理结构先行**：趁当前与上游分叉≈0（仅 2 项待落地的补丁，见 FORK_TODO_CN.md），
   一次性建立"local/ 本地代码区 + 薄钩子 + `[OMNI]` 标记 + 补丁清单 + 变更/回归台账"五件套（约 0.5 天）。
   此后无论二开规模多大，"我们改了什么"永远是一个 `git diff vendor/<版本> main` 能精确回答的问题。
2. **同步自动化全部定义在本地**：本地编排器 `sync.sh` 完成 检测上游 release → 合并 →
   AI 分诊冲突（机械冲突自动解，语义冲突留给人）→ 门禁检查 → 确认接受 → 打 `synced` 标签 →
   推送到 fork 自己的远端（origin）→ 本地构建镜像推 `model.publib.cn` → NAS 更新。
   上游虽托管在 GitHub，但**不依赖任何 GitHub 工作流**，fork 远端可以是任意 Git 服务（内网 GitLab 等）。
3. **分级合并**：patch 全自动（`AUTO_ACCEPT_PATCH`，演练后打开）、minor 交互确认、major 人工专项。
   AI 只允许解"整文件所有冲突块均可机械合并"的文件——这是 AI 自动化的安全边界；
   无 CI 平台的情况下，二开聚焦回归与 `sync.conf` 里的 `TEST_CMD` 共同构成质量闸门。
4. **安全修复走快车道**（`sync.sh --to <tag>` 即时摘取）；**普适改动持续回流上游**
   （每回流一个，本地补丁永久少一个）。

## 1. 现状与目标

### 1.1 现状（2026-08-29）

- 上游官方仓库：`https://github.com/diegosouzapw/OmniRoute.git`，tag 规则 `release/vX.Y.Z`；
  Fork 核对基线 `release/v3.8.51`（commit `7c04e75e`）。
- 部署形态：本地构建镜像 → 推 `model.publib.cn` → NAS（UGREEN）compose 拉取更新，
  现有实例 `local/omniroute-qodercli:3.8.50-qodercli-1.1.34-r1`。
- 已知二开 2 项（nara 模型发现接线、kimi-web refreshToken 表单项），当前均有管理 API workaround。
- 二开规模即将扩大："很多地方需要改"，且无旁挂能力——改动必然落在 fork 仓库内。

### 1.2 目标

1. 二开可以大改，但与上游的差异**永远可清点、可审计**（一个 grep + 一个 git diff）。
2. 上游新版本合入从"人工项目"降级为"本机一条命令 / 定时自动"，全程不出本机。
3. 常驻人力 ≤ 半个轮值；绝不连跳两个上游版本，杜绝"分叉深到无法合并"的死局。

### 1.3 边界

本方案不覆盖"上游停更/治理性硬分叉"场景；若上游方向与产品目标根本冲突，属于另立的立项决策。

## 2. 总体架构（全部本地）

```
上游仓库（GitHub，仅作为 fetch 源）
      │  本地 launchd 每周一 10:00 ／ 手动执行 sync.sh（可 --to 指定版本）
      ▼
[sync.sh 本地编排器]
  1. 最新 tag 已有 synced/ 标签？ ── 是 → 结束（无新版本）
  2. 分级 patch/minor/major（major 与无基线首同步 → 人工专项，止步）
  3. 加载 FORK_TODO_CN.md 当前有效变更及其上游合并规则
  4. 分叉纪律自检：相对 vendor/<last> 改过但无 [OMNI] 标记的文件 → 拒绝自动接受
  5. 在 main 上 git merge --no-ff（基线 sha 记入 .fork-sync/state，随时 --abort 回滚）
  6. AI 变更简报（changelog × 本地触碰文件交集 × 二开变更台账）
  7. 有冲突 → AI 分诊：机械冲突自动解；语义冲突保留标记（文件级全有全无）
  8. 门禁：check_local_patches.sh（补丁丢失=阻塞）
           + run_fork_regressions.sh（每项二开聚焦回归，清单不一致或失败=阻塞）
           + TEST_CMD 全局构建/测试（必须配置，见 §3.5）
  9. 决策：patch+无冲突+测试绿+AUTO_ACCEPT_PATCH → 自动接受；
           否则交互确认（TTY）/ 写报告待人工（--continue 接受，--abort 放弃）
      │ 接受
      ▼
打 synced/<ver> 标签 → 推送 origin（main + synced/vendor 标签，PUSH_AFTER_ACCEPT）
      → [release.sh] docker build（runner-base）
      → 推 model.publib.cn →（可选 --nas）ssh 更新 NAS .env + compose pull
      → 健康检查 → macOS 通知 / webhook 通知
```

同步前的 origin 预检：本地 main 落后 origin/main → 拒绝同步（先 `git pull --ff-only`），
杜绝在过期基线上合并；当前不在 main 分支 → 拒绝同步。

## 3. 第一部分：Fork 治理结构（一次性，约 0.5 天）

### 3.1 分支与标签模型

| 名称 | 类型 | 说明 |
|---|---|---|
| `upstream` | remote | 上游官方仓库，只读 |
| `origin` | remote | **fork 自己的远端**（内网 GitLab / 任意 Git 服务）；接受同步后自动推送 main 与 synced/vendor 标签，`--status` 显示与 origin/main 的领先/落后 |
| `main` | 分支 | 二开主分支，一切自有逻辑的落点；同步直接在 main 上进行（本地无 PR 环节） |
| `vendor/<ver>` | tag | 采纳某上游版本时打在其原始 commit 上；`git diff vendor/<ver> main` 即完整二开差异 |
| `synced/<ver>` | tag | 已接受的上游版本（打在 merge commit 上）；`sync.sh` 以此判断"有没有新版本" |
| `.fork-sync/` | 目录 | 编排器状态（state）与每次同步的报告（reports/），建议加入 `.gitignore` |

红线：`main` 相对最新 `vendor/*` 的 diff 就是全部二开；`synced/*` 落后上游 2 个 minor →
处理人必须安排专项合入。

### 3.2 local/ 本地代码区与"薄钩子"规范

四条规则：

1. **自有逻辑全部写进 `local/`**（上游不存在的顶层目录，纯加法，零冲突）。
   也可再细分：`local/api/`、`local/components/`、`local/lib/` 等。
2. **必须改上游文件时，把上游文件改成"薄钩子"**：只保留对 local 模块的一两行调用，
   真正的实现写在 `local/`。上游升级时冲突只会打在固定的钩子行上，解冲突变成机械动作。
3. **纯加法的小修复可以留在原处**（如往集合里加一项、registry 加字段），但必须带标记：
   `// [OMNI] <补丁id> <一句话说明>`。
4. **禁止在钩子/标记之外改动上游文件语义**。`sync.sh` 每次合并前自检：相对上个
   `vendor/*` 被改过但无 `[OMNI]` 标记的文件会被点名，并拒绝自动接受（人工确认才放行）。

示例一（加法修复，nara 模型发现接线，来自 FORK_TODO_CN.md）：

```ts
// src/app/api/providers/[id]/models/discovery/providerSets.ts（上游文件）
const NAMED_OPENAI_STYLE_PROVIDERS = new Set([
  "venice",
  "nanogpt",
  // [OMNI] nara-model-set：内置 nara 走 OpenAI 兼容实时发现（上游漏收，同类 #3976）
  "nara",
]);
```

示例二（薄钩子，kimi-web refreshToken 表单项）：

```tsx
// src/components/**/AddApiKeyModal.tsx（上游文件，diff 只有两行）
import { KimiRefreshTokenField } from "@/local/components/KimiRefreshTokenField";
// …原表单结构不动，在 kimi-web 分支表单区插入：
<KimiRefreshTokenField />{/* [OMNI] kimi-web-refresh-ui */}
```

输入框、校验、payload 透传（`connectionProviderSpecificData.ts` 的接入）全部实现在
`local/components/KimiRefreshTokenField.tsx` 及其辅助模块里。

### 3.3 补丁清单与自动核对（PATCHES.tsv + check_local_patches.sh）

`fork-sync-kit/PATCHES.tsv` 是全部本地补丁的登记表（已预填 FORK_TODO_CN.md 的两项修复）：

- 每行 6 列：`id / 说明 / 文件路径 / 本地锚点(egrep) / 上游已修复判定(egrep，空=无法判定) / upstreamable`。
- `check_local_patches.sh` 在每次 `sync.sh` 合入后自动执行，替代 FORK_TODO_CN.md 的人工核对步骤：
  - **丢失**：工作区该文件缺锚点 → 补丁没重放成功，**阻塞接受**（exit 1）；
  - **可删**：上游已含同判定特征 → 提示"上游已原生修复"，删除动作在本次同步内人工确认执行。

### 3.4 二开变更台账与聚焦回归（FORK_TODO_CN.md + REGRESSIONS.tsv）

`FORK_TODO_CN.md` 是全部 fork 专属行为的长期台账。新增功能、行为变更、问题修复以及
发布/部署行为变更，必须在实现的同一个 commit/PR 中登记：稳定 ID、验收标准、影响范围、
`PATCHES.tsv` ID、上游合并规则、自动回归命令、真实环境检查和最近通过基线。

`fork-sync-kit/REGRESSIONS.tsv` 是台账中聚焦回归命令的可执行镜像；每行 3 列：
`ID / 说明 / 命令`。`run_fork_regressions.sh` 在每次同步接受前执行以下强制检查：

1. `FORK_TODO_CN.md`“当前有效变更索引”的 ID 与 `REGRESSIONS.tsv` 必须一一对应；漏登记或
   多余命令均阻塞，防止只改代码、不补台账，或移除功能后留下失效测试。
2. 全部聚焦回归逐项执行并写入本次同步报告；任一失败即阻塞接受和发布。
3. 聚焦回归只保护 fork 专属行为，不能替代全局 `TEST_CMD`。两层都绿才允许接受。
4. 若上游提供等价实现，先按台账验收标准验证上游版本，再删除本地补丁并把条目标为
   “已由上游替代”；保留历史记录，避免后续版本重复引入。

### 3.5 本地质量门禁与分叉度 KPI

没有 CI 平台，门禁全部内置在 `sync.sh` 接受之前：

1. **二开聚焦回归**（§3.4）——台账和清单必须一致，逐项测试必须通过。
2. **`TEST_CMD` 本地验证**（sync.conf 配置，如 `npm ci && npm run build && npm test -- --run`）——
   失败即阻塞，这是自动化的最后一道闸门，**必须配置**。
3. **标记纪律自检**（§3.2 第 4 条）。
4. **补丁核对**（§3.3）。
5. **分叉度 KPI**（`divergence_report.sh`，写入每次同步报告）：
   触碰的上游文件数、相对 `vendor/*` 的 diff 行数、`[OMNI]` 补丁数。
   阈值告警：**触碰上游文件 > 40 或补丁数 > 15** → 触发架构评审
   （该区域需要造缝，或加大回流力度），防止分叉静默膨胀。

## 4. 第二部分：本地同步编排（sync.sh）

### 4.1 触发与节奏

- **定时**：launchd 每周一 10:00 跑一次 `sync.sh`（`com.omniroute.fork-sync.plist`，
  安装见 §5.3）；非交互模式下它只做"检测+合并评估+报告+通知"，是否接受由分级决定（§4.2）。
- **手动**：`sync.sh`（交互确认）／`sync.sh --to <tag>`（指定版本，安全快车道）。
- 合入节奏跟随上游 release：**绝不连跳两个版本是红线**；落后 2 个 minor 未跟 → 安排专项。

### 4.2 分级合并策略

| 上游版本 | 冲突情况 | 处理方式 |
|---|---|---|
| patch（与上次 synced 同 major.minor） | 无冲突（或 AI 已全解） | 二开聚焦回归 + TEST_CMD 绿 → **自动接受并发布**（`AUTO_ACCEPT_PATCH=true`，演练期保持 false） |
| patch | 有语义冲突 | 停下待人工（`--continue` / `--abort`） |
| minor | 任意 | 交互确认（TTY）或写报告待人工；AI 出完整分析 |
| major / 无 synced 基线的首同步 | — | **人工专项**：`sync.sh` 只做评估出报告，不自动合入 |

人工接管的三种入口：`--continue`（冲突解决完/决定接受）、`--yes`（跳过交互确认）、`--abort`（回滚到合并前）。

### 4.3 AI 的介入点与安全边界

四个介入点：

1. **冲突分诊**（`ai_conflict_triage.mjs` triage 模式，§4.3.1）。
2. **上游变更简报**（changelog 模式）：`synced/<last>..<target>` 的上游 commit 列表 +
   本地触碰文件清单 → "上游改了什么 × 对我们的钩子/补丁有什么影响 × 建议关注点"。
3. **补丁清单判定辅助**：check_local_patches.sh 的 grep 判定给出硬信号，报告里补充解释与删除建议。
4. **回流上游**：为 §7 的 issue/PR 起草文案与复现说明。

AI 网关在 sync.conf 配置（OpenAI 兼容，默认 `AI_API_BASE` 指向 bigmodel）；不配 `AI_API_KEY`
时流程照常，只是冲突全部留人工、简报退化为原始清单。

#### 4.3.1 AI 冲突分诊规则（写死在脚本 prompt 与代码里）

- 按文件提取冲突块（含上下文），LLM 逐块给出 `verdict(auto/manual) / strategy(ours|theirs|merged) / 理由 / 置信度`。
- **文件级全有全无**：该文件所有冲突块都判 auto 且可执行，才改写落盘并 `git add`；
  任何一块 manual → 整文件保留冲突标记，进人工。
- **钩子保护清单**：PATCHES.tsv 登记过的文件一律 manual，不由 AI 碰。
- **本地侧优先**：ours 侧改动默认视为二开逻辑（通常带 `[OMNI]` 标记），
  除非与上游修复明显重复，不得丢弃。
- 置信度 < 0.9 视同 manual；单冲突块超过 200 行、文件超过 2000 行直接 manual。
- AI 解过的文件在报告中逐块可追溯（理由 + 置信度）；未接受前随时 `--abort` 整体回滚。

### 4.4 与构建发布的衔接（release.sh，全部本地）

sync 接受（打 `synced/<ver>` 标签并推送 origin）后自动调用 `release.sh <版本号>`：

1. `docker build --target runner-base`（即部署文档 §4.4 的构建目标），本地打镜像 tag
   `{OMNI_REGISTRY}/{OMNI_IMAGE_PATH}:{版本}-{OMNI_IMAGE_TAG_SUFFIX}`
   （例：`model.publib.cn/local/omniroute-qodercli:3.8.52-qodercli-1.1.34-r1`）；
2. `--push` 推送 registry（`sync.sh` 默认带 push；也可先用 `--no-build` 跳过、手动跑 release 验证）；
3. NAS 更新：配置了 `NAS_SSH_HOST` 时 ssh 修改 `.env` 的 `OMNIROUTE_IMAGE` 并
   `compose pull && up -d` + 健康检查；未配置则打印手工步骤（UGREEN SSH 限制见 `deploy/nas/AGENT_DEPLOY.md`）；
4. 通知：macOS 系统通知 + 可选 webhook（`SYNC_WEBHOOK_URL`，企业微信/钉钉机器人格式）。

## 5. 第三部分：fork-sync-kit 落地指引

### 5.1 文件清单

| 文件 | 作用 |
|---|---|
| `sync.sh` | 本地同步编排器：检测→合并→AI 分诊→门禁→决策→打标签→调 release.sh（含 --status/--abort/--continue/--yes/--to/--no-build） |
| `release.sh` | 本地构建镜像 → 推 model.publib.cn →（可选）NAS 更新与健康检查 |
| `sync.conf.example` | 全部配置：上游地址/分级策略/NODE_BIN/TEST_CMD/AI 网关/镜像与 NAS/通知 |
| `ai_conflict_triage.mjs` | AI 冲突分诊（triage）+ 上游变更简报（changelog），零依赖 Node ≥18 |
| `check_local_patches.sh` | 补丁清单自动核对（丢失阻塞 / 可删提示） |
| `run_fork_regressions.sh` | 校验二开台账与回归清单一一对应，并执行全部聚焦回归 |
| `divergence_report.sh` | 分叉度 KPI 报告 |
| `PATCHES.tsv` | 本地补丁登记表（已预填两项已知修复；登记文件同时进入 AI 保护清单） |
| `REGRESSIONS.tsv` | 二开有效变更 ID 与可执行聚焦回归命令 |
| `com.omniroute.fork-sync.plist` | launchd 每周定时模板 |

### 5.2 接入步骤（约 1 天）

1. 把 kit 复制进 fork 仓库根目录的 `fork-sync-kit/`，
   `cp sync.conf.example sync.conf` 并填齐（§10）：上游地址已预填官方仓库，补 `AI_API_KEY`、
   `TEST_CMD`、镜像三件套（按现有 `3.8.50-qodercli-1.1.34-r1` 命名规则）。
   fork 仓库从自己的远端 origin 克隆；若历史 synced/vendor 标签还只在旧机器上，
   先 `git push origin --tags` 补齐。
2. 落地 §3 治理结构：建 `local/` 目录、把 FORK_TODO_CN.md 两项修复按"加法 + 标记"实现进代码、
   修正 PATCHES.tsv 的文件路径与锚点、更新登记状态、`.gitignore` 加 `.fork-sync/`。
3. **打首次基线标签**（一次性；没有 synced 基线时任何同步都会被判 major 而止步）：
   ```bash
   git tag synced/release/v3.8.51
   git tag vendor/release/v3.8.51 refs/tags/release/v3.8.51
   ```
   随后首跑演练：`sync.sh --status` → 对一个已同步版本跑 `sync.sh --to release/v3.8.51 --yes --no-build`
   （应秒回"已同步过"）→ 对真实新 patch 版本跑完整流程，检查报告质量。
4. 演练 2~3 个版本无误判后，把 `AUTO_ACCEPT_PATCH` 改 `true`。
5. 挂定时（§5.3）。

### 5.3 本地定时（launchd / cron）

launchd（推荐，Mac 不开机则顺延不补跑）：

```bash
# 把 plist 内 /path/to/your/fork 换成 fork 仓库实际路径
cp fork-sync-kit/com.omniroute.fork-sync.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.omniroute.fork-sync.plist
launchctl start com.omniroute.fork-sync   # 手动试跑一次
tail -f /tmp/omniroute-fork-sync.log
```

crontab 等价方案：`0 10 * * 1 cd /path/to/your/fork && fork-sync-kit/sync.sh >> .fork-sync/cron.log 2>&1`。
Linux 机器同理（去掉 osascript 通知即可，脚本已容错）。

### 5.4 常用操作速查

| 场景 | 命令 |
|---|---|
| 看当前状态 | `sync.sh --status` |
| 常规同步（交互） | `sync.sh` |
| 指定版本（安全快车道） | `sync.sh --to release/v3.8.53` |
| 冲突解决完继续 | `sync.sh --continue --yes` |
| 放弃本次同步 | `sync.sh --abort` |
| 只想合入不构建 | `sync.sh --yes --no-build` |
| 手动重新发布镜像 | `release.sh 3.8.52 --push --nas` |

## 6. 安全公告快车道

- 订阅上游 release 与 security advisory 通知（GitHub Watch / 邮件任一）。
- 安全修复**不等周一节奏**：`sync.sh --to <tag> --yes` 即时走同一条流水线（patch 级全自动路径）。
- 即使长期策略降级为"只摘安全修复"（Tengine 模式），本机制同样适用——只改触发习惯，不改工具。

## 7. 上游回流

- PATCHES.tsv 的 `upstreamable` 列管理状态机：`是 → 已提 → 已合 / 被拒`。
- 每个"是"都应有对应的上游 issue/PR（AI 起草文案，人工提交）；
  被上游合并后，核对脚本自动判"可删"，在下次同步时移除本地补丁。
- 首个候选：nara 模型发现的一行修复（与上游 #3976 / 2026-06-19 sweep 完全同类）；
  kimi-web refreshToken 表单项属普适功能缺失，同样值得提。
- 回流是唯一能永久降低分叉度的手段，与是否走 fork 无关。

## 8. 里程碑、人力与验收标准

| 里程碑 | 内容 | 工时 | 验收标准 |
|---|---|---|---|
| M0 治理结构 | local/ 目录、标记规范、PATCHES.tsv、两项修复落地 | 0.5 天 | `git diff vendor/release/v3.8.51 main` 与补丁清单一一对应；核对脚本全绿 |
| M1 本地编排器 | sync.sh 端到端（AI 未接时冲突全留人工）、TEST_CMD 配置 | 1 天 | 真实版本端到端：检测→合并→报告→接受→synced 标签→release.sh 出镜像 |
| M2 AI 分诊接入 | triage + changelog 接入，prompt 调优 | 1~2 天 | 2~3 个真实 patch 版本零语义误判；报告逐块可追溯 |
| M3 全自动 patch | `AUTO_ACCEPT_PATCH=true` + launchd 挂载 | 0.5 天 | 一个 patch 版本从 release 到 NAS 更新零人工 |

常态运行成本：定时自动运行；minor 人审约 0.5~2 小时/次；major 专项另计；每月看一次 KPI。

## 9. 风险与对策

| 风险 | 对策 |
|---|---|
| AI 误判语义冲突 | 文件级全有全无；置信度阈值 0.9；钩子文件禁碰；TEST_CMD 门禁；patch 级才自动接受；报告逐块可追溯；`--abort` 一键回滚 |
| 无 CI 平台，质量闸门缺失 | `TEST_CMD`（构建+测试）作为强制门禁写进 sync.conf；未配置时编排器显式告警 |
| 自动接受事故 | AUTO_ACCEPT_PATCH 默认 false，演练后开；每次同步报告落盘 `.fork-sync/reports/`；回滚 = `git reset` 到 vendor 基线或 revert synced tag |
| 上游重写钩子文件 | 分诊报告显式列出 → 升级人工专项；分叉度 KPI 提前暴露触碰面积增长 |
| origin 推送失败 | 本地接受不受影响，脚本提示手动 `git push origin main --tags` 补推并通知；预检保证不会基于过期 origin/main 合并 |
| 长期落后分叉加深 | launchd 每周兜底；落后 2 个 minor 即转专项工单；红线"绝不连跳两个版本" |
| 凭据安全 | AI key、registry 凭据只存在本地 sync.conf / docker login（sync.conf 不要提交进 git） |

## 10. 需要确认/填写的参数（sync.conf）

| # | 参数 | 说明 |
|---|---|---|
| 1 | `UPSTREAM_URL` / `UPSTREAM_TAG_PREFIX` | 已预填官方仓库与 `release/v` 前缀，确认即可 |
| 2 | `PUSH_AFTER_ACCEPT` | 接受后自动推送 main 与 synced/vendor 标签到 origin（默认 true；临时跳过用 `--no-push`） |
| 3 | `NODE_BIN` | Node 22+ 可执行文件；供二开聚焦回归使用，默认 `node` |
| 4 | `TEST_CMD` | 全局构建+测试命令（与二开聚焦回归共同构成质量闸门，**必须配置**） |
| 5 | `AI_API_BASE` / `AI_API_KEY` / `AI_MODEL` | OpenAI 兼容网关；不配则冲突全留人工 |
| 6 | `OMNI_REGISTRY` / `OMNI_IMAGE_PATH` / `OMNI_IMAGE_TAG_SUFFIX` | 按现有镜像命名规则确认（`model.publib.cn/local/omniroute-qodercli:{ver}-qodercli-…`） |
| 7 | `NAS_SSH_HOST` / `NAS_DIR` / `NAS_HEALTH_URL` | NAS 自动更新；不配则 release.sh 打印手工步骤 |
| 8 | `AUTO_ACCEPT_PATCH` | 先 false，演练 2~3 个版本后开 |
| 9 | `SYNC_WEBHOOK_URL` | 可选，机器人通知 |
