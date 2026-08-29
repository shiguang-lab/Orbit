# OmniRoute 二开待办（本地已知问题与修复要点）

> 记录日期：2026-08-29。
> 核对基线：`release/v3.8.51`（commit `7c04e75e54f288cfbdca11175ddfab5ab20fe252`），
> 部署实例为本地构建 `local/omniroute-qodercli:3.8.50-qodercli-1.1.34-r1`（model.publib.cn）。
> 两个问题均已在该部署实例上实测复现/验证；截至记录日，上游 main 分支均未修复。

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
