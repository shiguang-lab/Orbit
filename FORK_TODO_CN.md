# OmniRoute 二开变更、修复与回归台账

> 记录日期：2026-08-29。
> 核对基线：`release/v3.8.51`（commit `7c04e75e54f288cfbdca11175ddfab5ab20fe252`），
> 部署实例为本地构建 `local/omniroute-qodercli:3.8.50-qodercli-1.1.34-r1`（model.publib.cn）。
> 两个问题均已在该部署实例上实测复现/验证；截至记录日，上游 main 分支均未修复。

本文件是 fork 专属行为的长期台账，不只是待办列表。所有二开新增功能、行为变更、问题修复、
发布或部署行为变更，都必须在实现的同一个 commit/PR 中登记；上游同步时按本文件逐项决定
保留、改写、删除或改用上游实现，并执行对应回归。

## 强制维护规则

1. 每项变更使用稳定 ID，并标明类型（新增功能/行为变更/问题修复/发布运维）、状态
   （有效/已由上游替代/已停用）、验收行为、影响文件或 `[OMNI]` 补丁 ID。
2. 每项有效变更必须写明上游同步时的合并规则、自动回归测试文件和可直接执行的命令；
   无法自动化的外部服务或真实环境验证必须写明操作与期望结果。
3. 改到上游文件时，同时登记 `fork-sync-kit/PATCHES.tsv`；台账描述功能和回归契约，
   `PATCHES.tsv` 描述文件锚点和上游修复判定，两者不能互相替代。
4. 接受上游同步前，逐项检查上游是否覆盖或冲突，执行本文件的聚焦回归，再执行全局
   `TEST_CMD`。任一有效项没有明确合并结论、缺少回归记录或测试失败，禁止接受和发布。
5. 上游原生实现同一能力后，先用本项验收行为验证上游实现，再删除本地补丁并把状态改为
   “已由上游替代”；历史条目保留，不能直接删除。
6. 每次同步完成后更新“最近通过基线/结果”。仅文档、注释或格式变化且不影响运行行为时，
   可不新增条目。

新增条目至少包含：`ID`、`类型/状态`、`行为与验收标准`、`影响范围/PATCHES ID`、
`上游合并规则`、`自动回归命令`、`真实环境检查（如需）`、`最近通过基线/结果`。

## 当前有效变更索引

| ID | 类型/状态 | 行为与验收标准 | 影响范围 / PATCHES ID |
|---|---|---|---|
| `FORK-FIX-NARA-MODELS` | 问题修复 / 有效 | 内置 `nara` 的 Import Models 请求实时 `/v1/models`；网络失败时仍回退本地目录并记录诊断日志 | `nara-model-set`、`nara-registry-models-url`、`models-route-fallback-log`；详见问题 1 |
| `FORK-FEAT-KIMI-REFRESH-UI` | 新增功能+问题修复 / 有效 | kimi-web 新建和编辑连接均可录入 `refreshToken`，保存到 `providerSpecificData`，令既有自动刷新链路可用 | `kimi-web-refresh-ui`；详见问题 2 |
| `FORK-OPS-SYNC-KIT` | 发布运维 / 有效 | `fork-sync-kit/` 保留补丁核对、上游同步、构建发布和 NAS 更新能力 | fork 专属目录 `fork-sync-kit/` |
| `FORK-OPS-GHCR-PUBLISH` | 发布运维 / 有效 | GitHub Actions 从本 fork 构建并发布 `ghcr.io/shiguang-lab/orbit` 的 amd64/arm64 镜像，且不受上游已发布分支锁阻断 | `.github/workflows/docker-publish.yml`、`lock-released-branch.yml` 及构建辅助文件 |

## 上游同步合并与回归矩阵

| ID | 上游同步合并规则 | 聚焦自动回归 | 真实环境检查 | 最近通过基线/结果 |
|---|---|---|---|---|
| `FORK-FIX-NARA-MODELS` | 上游触碰任一 PATCHES 文件时人工合并；若上游已原生支持 nara，优先删除重复补丁，但必须保留实时发现与失败回退行为 | `"$NODE_BIN" --import tsx/esm --import ./open-sse/utils/setupPolyfill.ts --test tests/unit/provider-sweep-live-discovery.test.ts` | Dashboard 对内置 nara 执行 Import Models，期望 `source: "api"`；断网时应为 `local_catalog` 且有诊断日志 | `release/v3.8.51` (`e399576b5`)，2026-08-30：22/22 通过 |
| `FORK-FEAT-KIMI-REFRESH-UI` | 上游若增加等价字段，人工整合为单一实现；不得丢失新建、编辑、持久化和轮换 refresh token 的能力 | `"$NODE_BIN" --import tsx/esm --test tests/unit/web-session-credentials.test.ts` | 新建和编辑 kimi-web 后重新打开连接，refresh token 能用于 `/api/providers/[id]/refresh-token` | `release/v3.8.51` (`e399576b5`)，2026-08-30：4/4 通过 |
| `FORK-OPS-SYNC-KIT` | `fork-sync-kit/` 为 fork 专属目录，默认保留 ours；仅在上游出现等价方案时专项迁移 | `bash -n fork-sync-kit/check_local_patches.sh fork-sync-kit/divergence_report.sh fork-sync-kit/release.sh fork-sync-kit/run_fork_regressions.sh fork-sync-kit/sync.sh && "$NODE_BIN" --check fork-sync-kit/ai_conflict_triage.mjs` | 用已同步版本执行 `sync.sh --to <release> --yes --no-build`，期望识别“已同步过”且不产生发布 | `release/v3.8.51` (`e399576b5`)，2026-08-30：语法检查通过 |
| `FORK-OPS-GHCR-PUBLISH` | 保留 `shiguang-lab/orbit` 命名空间与 fork 分支锁豁免；吸收上游工作流更新时人工合并这些 fork 条件 | `"$NODE_BIN" --import tsx/esm --test tests/unit/workflows-no-foreign-fork-publishers.test.ts tests/unit/docker-build-memory-budget.test.ts` | Actions 成功后匿名检查 `docker buildx imagetools inspect ghcr.io/shiguang-lab/orbit:next`，必须含 amd64/arm64 | `release/v3.8.51` (`e399576b5`)，2026-08-30：7/7 通过；匿名多架构检查通过 |

`NODE_BIN` 默认使用当前 `PATH` 中的 `node`；同步机必须使用项目支持的 Node 22+，也可在
`fork-sync-kit/sync.conf` 中显式指定可执行文件路径。

## 问题 1：内置 `nara`（NaraRouter）无法实时拉取模型列表（已用 workaround 绕过）

### 现象

Dashboard 对内置 NaraRouter 连接点 Import Models 永远返回
`source: "local_catalog"` + `warning: "API unavailable — using local catalog"`，
**从未发出过任何网络请求**（与网络/代理/key 无关，均实测排除：真实 key 下上游
`/v1/models` 返回 200、54 个模型，直连与经代理均通）。

### 根因（三个接线点全缺）

models 路由（`src/app/api/providers/[id]/models/route.ts`）里，nara 不满足任何
"实时发现"分支的准入条件，最终落入"无发现配置 → 回退本地目录"分支
（`route.ts` 约 2146 行起，`if (!config && localCatalog.length > 0)`，
warning 文案为硬编码、`intentional: true`）：

1. `isOpenAICompatibleProvider` 是**前缀匹配**（`src/shared/constants/providers.ts:196`，
   要求 id 以 `openai-compatible-` 开头），内置 id `nara` 不匹配；
2. `NAMED_OPENAI_STYLE_PROVIDERS`（`src/app/api/providers/[id]/models/discovery/providerSets.ts`）
   收录了 venice/nanogpt/logfare 等几十个同类聚合器（#3976 与 2026-06-19 sweep 同类修复），
   **但没有 `nara`**；3.8.50 部署构建与上游 main 亦无；
3. 兜底 `deriveConfigFromRegistryModelsUrl`（`discoveryConfig.ts:24`）要求注册表条目有
   `modelsUrl` 字段，而 nara 的条目由 `buildOpenAiCompatibleRegistryEntry` 构建
   （`open-sse/config/providers/registry/nara/index.ts`），**只有 `baseUrl`（chat 用），
   没有 `modelsUrl`**；`PROVIDER_MODELS_CONFIG` 表中也无 nara 条目。

### 二开修复（任选其一，建议 1+2 都做）

```ts
// 1) providerSets.ts 的 NAMED_OPENAI_STYLE_PROVIDERS 集合加一项：
"nara",

// 2) open-sse/config/providers/registry/nara/index.ts 的条目加：
modelsUrl: "https://router.bynara.id/v1/models",
```

附带改进建议（本次排障的痛点）：models 路由对 `NETWORK_ERROR` 类错误是静默吞掉后
回退、不留日志（`getSafeOutboundFetchErrorStatus` 只映射
TIMEOUT/INVALID_URL/URL_GUARD_BLOCKED/REDIRECT_BLOCKED），排障时无迹可循。
建议在回退分支加一行 `console.warn`（带 provider、端点、error.message）。

### 当前 workaround 状态（2026-08-29 已配置）

- 已创建兼容 Provider 节点 `openai-compatible-chat-c4a5b10b-2bf1-4214-b336-9b5911db43d9`
  （名称 NaraRouter，prefix `nararouter`——`nara` 是保留前缀会被拒），
  连接 `e963dc07-4025-41ef-8a31-18ec4336658e`，key 已迁移，自动测试通过，
  Import 实测 `source: "api"`、54 个模型。
- 旧内置 nara 连接（`585d17a0-065a-4e96-a34f-2c17f12b91b2`）已删除，其遗留旧同步目录一并清理。
- 代价：内置条目的免费额度标签（`nara-free` 池，freeModelCatalog）不跟随自定义节点。
- 二开落地后可迁回内置条目：重贴 key → Import → 停用自定义节点。
- 顺带：建议给上游提 issue（与 #3976 / 2026-06-19 sweep 完全同类的一行修复）。

## 问题 2：`kimi-web` 的 refreshToken 无 UI 录入入口（刷新机制本身已完备）

### 现状

kimi-web 的 token 自动续期机制**已经存在且已接入调度**（部署构建里已含）：

- 主动：健康检查周期扫描（日志 `[CredentialHealth] Testing x/10`）对 `kimi-web` 连接，
  access_token（JWT）距到期 <60~240 秒（随机抖动防惊群）时自动调
  `GET <base>/api/auth/token/refresh`（Bearer refresh_token）换新并回写
  新 access/refresh token（`src/lib/tokenHealthCheckKimi.ts`、`src/lib/kimi/tokenRefresh.ts`）；
- 反应式：chat 收到上游 401 且连接有 refresh_token 时，自动换新并重试一次
  （`open-sse/executors/kimi-web.ts` 约 410 行）；
- 手动：`POST /api/providers/[id]/refresh-token`。

缺口：引擎从连接的 `refresh_token` 凭据字段或 `providerSpecificData.refreshToken`
读取，但 **Dashboard 的 kimi-web 连接表单没有 refreshToken 输入框**
（表单按"贴 access_token / kimi-auth cookie"设计），
导致 refresh_token 只能创建连接后通过管理 API 补写一次：

```
PUT /api/providers/<连接ID>
{ "providerSpecificData": { "refreshToken": "<kimi 的 refresh_token>" } }
```

（两处读取位置都会生效；不补则 token 到期后需手动重新贴。）

**workaround 已于 2026-08-29 执行**：连接 `f5693bb7-225c-432c-9a41-f4cca0b419b5`（Kimi Web / main），
refresh_token 已写入 providerSpecificData，手动刷新端点实测
`{"success":true,"message":"Token refreshed successfully"}`，连接 active。
注意：Kimi 换发时会**轮换 refresh_token**（旧即失效），当前有效的 refresh_token
只存在于实例数据库中（加密存储）。

### 二开修复

给 kimi-web 连接表单（`AddApiKeyModal.tsx` / `connectionProviderSpecificData.ts`）
增加 refreshToken 输入项：创建/更新 payload 透传 `refreshToken`
（`CONNECTION_CREDENTIAL_FIELDS` 已含该列，`src/lib/db/providers.ts:105`，
`provider_connections.refresh_token` 列也已存在，纯 UI+schema 放行即可）；
authHint 同步提示 www.kimi.ai Local Storage 里 `access_token` 与 `refresh_token` 两个键。

## 二开时的其他备忘

- 管理操作可用容器内 `JWT_SECRET`（`/app/data/server.env`）铸造会话
  （JWT：`{authenticated:true}` HS256，cookie 名 `auth_token`；不带 Origin 头即过 CSRF 的
  browser-origin 校验），全程走官方管理 API，key 加密/审计/清理按正常路径执行。
- 每次追上游后需重新核对本文件两条问题是否已被官方修复（2026-08-29 时均未修）。

---

## 2026-08-29 更新：两个问题均已在本 fork 修复（commit 待填）

- 问题 1（nara 实时模型列表）：已落地 `[OMNI] nara-model-set`（providerSets.ts 加入 `nara`）
  + `[OMNI] nara-registry-models-url`（registry 条目补 `modelsUrl`），并加了
  `[OMNI] models-route-fallback-log` 排障日志。同步后内置 nara 连接 Import Models 将实时拉取。
- 问题 2（kimi-web refreshToken）：已落地 `[OMNI] kimi-web-refresh-ui`
  （webSessionCredentials 声明 refreshToken + AddApiKeyModal/EditConnectionModal 输入框 + i18n），
  创建/编辑弹窗即可配置 refresh_token 并存入 providerSpecificData，无需再走管理 API 补写。
- 同步套件 fork-sync-kit/ 已随仓库落地（sync.conf 不入库），配合 OMNIROUTE_FORK_SYNC_CN.md。
