#!/usr/bin/env bash
# OmniRoute 本地同步编排器（fork-sync-kit）—— 全流程在本机执行，不依赖 GitHub 工作流
# 方案见 OMNIROUTE_FORK_SYNC_CN.md §4。
#
# 用法:
#   sync.sh                     # 检测上游最新 release 并同步（交互确认后合入/发布）
#   sync.sh --to <tag>          # 指定上游 tag（安全公告快车道也走这里）
#   sync.sh --yes               # 非交互确认（等价人工选 y；major 仍会拒绝）
#   sync.sh --no-build          # 合入但不触发 release.sh 构建发布
#   sync.sh --no-push           # 接受但不推送到 origin（默认按 sync.conf 的 PUSH_AFTER_ACCEPT）
#   sync.sh --continue          # 冲突人工解决并提交后，从检查阶段继续
#   sync.sh --abort             # 放弃本次未完成的同步，回到合并前状态
#   sync.sh --status            # 只查看：上游最新版本 / 上次 synced / 分级
#
# 配置: fork-sync-kit/sync.conf（从 sync.conf.example 复制）。
# 状态与报告: .fork-sync/（state 文件 + reports/*.md），两者均可随仓库忽略或归档。
set -euo pipefail

KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$KIT_DIR/.." && pwd)"
CONF="$KIT_DIR/sync.conf"
STATE_DIR="$REPO_ROOT/.fork-sync"
STATE="$STATE_DIR/state"
REPORTS="$STATE_DIR/reports"

[[ -f "$CONF" ]] || { echo "缺少配置: $CONF —— 请从 sync.conf.example 复制并填写（方案 §10）"; exit 2; }
# shellcheck source=/dev/null
source "$CONF"
: "${UPSTREAM_URL:?sync.conf 缺少 UPSTREAM_URL}"
UPSTREAM_TAG_PREFIX="${UPSTREAM_TAG_PREFIX:-release/v}"
AUTO_ACCEPT_PATCH="${AUTO_ACCEPT_PATCH:-false}"
TEST_CMD="${TEST_CMD:-}"
mkdir -p "$REPORTS"

TO="" YES=0 NO_BUILD=0 NO_PUSH=0 CONT=0 STATUS=0 ABORT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TO="${2:?--to 需要 tag}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --no-push) NO_PUSH=1; shift ;;
    --continue) CONT=1; shift ;;
    --status) STATUS=1; shift ;;
    --abort) ABORT=1; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

G=(git -C "$REPO_ROOT")
GQ() { "${G[@]}" rev-parse -q --verify "$1" >/dev/null 2>&1; }
log() { echo "[sync] $*"; }
err() { echo "[sync] 错误: $*" >&2; }
notify() {
  local msg="$1"
  if [[ "${NOTIFY_MACOS:-true}" == "true" ]]; then
    osascript -e "display notification \"$msg\" with title \"OmniRoute fork-sync\"" >/dev/null 2>&1 || true
  fi
  if [[ -n "${SYNC_WEBHOOK_URL:-}" ]]; then
    curl -fsS -m 5 -X POST -H 'content-type: application/json' \
      -d "{\"msgtype\":\"text\",\"text\":{\"content\":\"$msg\"}}" "$SYNC_WEBHOOK_URL" >/dev/null 2>&1 || true
  fi
}

# origin（fork 自己的远端）探测：设置 HAS_ORIGIN / behind / ahead，供 status 与主流程共用
HAS_ORIGIN=0; behind=0; ahead=0
origin_probe() {
  "${G[@]}" remote get-url origin >/dev/null 2>&1 || return 0
  HAS_ORIGIN=1
  "${G[@]}" fetch origin --prune 2>/dev/null || log "⚠️ origin fetch 失败（离线/凭据），按本地状态继续"
  if GQ "refs/remotes/origin/main"; then
    behind="$( "${G[@]}" rev-list --count HEAD..origin/main )"
    ahead="$( "${G[@]}" rev-list --count origin/main..HEAD )"
  fi
}

"${G[@]}" config rerere.enabled true
"${G[@]}" remote add upstream "$UPSTREAM_URL" 2>/dev/null || "${G[@]}" remote set-url upstream "$UPSTREAM_URL"
"${G[@]}" fetch upstream --tags --prune

latest="$( "${G[@]}" tag -l "${UPSTREAM_TAG_PREFIX}*" --sort=-v:refname | head -1 )"
last="$( "${G[@]}" tag -l 'synced/*' --sort=-v:refname | head -1 )"; last="${last#synced/}"

# ---------- --status / --abort ----------

if [[ $STATUS -eq 1 ]]; then
  origin_probe
  echo "上游最新: ${latest:-无}"
  echo "上次 synced: ${last:-无}"
  echo "分支: $("${G[@]}" rev-parse --abbrev-ref HEAD)  工作区: $("${G[@]}" status --porcelain | wc -l | tr -d ' ') 个改动"
  if [[ $HAS_ORIGIN -eq 1 ]] && GQ "refs/remotes/origin/main"; then
    echo "origin/main: 本地领先 ${ahead}，落后 ${behind}"
  else
    echo "origin/main: 未配置或无 main 分支"
  fi
  exit 0
fi

if [[ $ABORT -eq 1 ]]; then
  [[ -f "$STATE" ]] || { echo "没有进行中的同步"; exit 0; }
  # shellcheck source=/dev/null
  source "$STATE"
  if GQ MERGE_HEAD; then
    "${G[@]}" merge --abort; log "已放弃合并，回到 $pre_merge_sha"
  else
    "${G[@]}" reset --hard "$pre_merge_sha"; log "已回滚到合并前 $pre_merge_sha"
  fi
  rm -f "$STATE"
  exit 0
fi

# ---------- origin 预检（fork 自己的远端；落后则拒绝同步）----------

origin_probe
if [[ $HAS_ORIGIN -eq 1 ]] && GQ "refs/remotes/origin/main"; then
  branch="$( "${G[@]}" rev-parse --abbrev-ref HEAD )"
  [[ "$branch" == "main" ]] || { err "同步须在 main 分支执行（当前在 $branch）"; exit 1; }
  if [[ $behind -gt 0 ]]; then
    err "本地 main 落后 origin/main $behind 个提交，请先执行: git pull --ff-only"
    exit 1
  fi
fi

# ---------- 有未完成同步时的保护 ----------

if [[ -f "$STATE" && $CONT -eq 0 ]]; then
  err "存在未完成的同步（${STATE}）。请先处理：" >&2
  echo "  人工解决冲突并 commit 后: sync.sh --continue" >&2
  echo "  或放弃本次同步:          sync.sh --abort" >&2
  exit 1
fi

# ---------- 1. 目标版本与分级（--continue 优先读未完成状态）----------

if [[ $CONT -eq 1 ]]; then
  [[ -f "$STATE" ]] || { err "没有进行中的同步，--continue 无从继续"; exit 1; }
  # shellcheck source=/dev/null
  source "$STATE"
  kind="$tier"
  diff_end="$pre_merge_sha" # --continue 时 HEAD 已含上游变更，纪律自检以合并前基线为终点
  log "继续未完成的同步：${target}（${kind}，合并前基线 ${pre_merge_sha}）"
else
  target="$TO"
  [[ -n "$target" ]] || target="$latest"
  [[ -n "$target" ]] || { err "上游无 ${UPSTREAM_TAG_PREFIX}* tag" >&2; exit 1; }
  if GQ "refs/tags/synced/$target"; then log "$target 已同步过，结束"; exit 0; fi

  ver_num="$(echo "$target" | tr -cd '0-9.')"
  if [[ -z "$last" ]]; then
    kind=major # 无基线：首次同步一律人工专项
  else
    last_num="$(echo "$last" | tr -cd '0-9.')"
    if   [[ "${ver_num%.*}"  = "${last_num%.*}"  ]]; then kind=patch
    elif [[ "${ver_num%%.*}" = "${last_num%%.*}" ]]; then kind=minor
    else kind=major; fi
  fi
  diff_end="HEAD"
  log "目标 ${target}（${kind}，上次 synced：${last:-无}）"

  if [[ $kind == major ]]; then
    ts="$(date +%Y%m%d-%H%M%S)"
    safe_target="$(echo "$target" | tr '/' '_')" # tag 里的 / 不能进文件名
    report="$REPORTS/$ts-$safe_target.md"
    cat > "$report" <<EOF
# 同步报告：$target

分级为 major（或无 synced 基线），按方案 §4.2 走人工专项，编排器不自动合入。
建议：先人工分批合入并 commit，再以 sync.sh --continue 走检查与接受。
EOF
    log "major/无基线版本 → 人工专项，报告已写出 ${report}"
    notify "OmniRoute 上游 $target 为 major，需人工专项"
    exit 3
  fi
fi

ts="$(date +%Y%m%d-%H%M%S)"
safe_target="$(echo "$target" | tr '/' '_')"
report="$REPORTS/$ts-$safe_target.md"
ver_num="$(echo "$target" | tr -cd '0-9.')"

# ---------- 2. 分叉纪律自检（合并前，方案 §3.2）----------

unsigned=""
if [[ -n "$last" ]]; then
  base_vendor="vendor/$last"
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    case "$f" in local/*|fork-sync-kit/*|.fork-sync/*|.gitignore) continue ;; esac
    [[ -f "$REPO_ROOT/$f" ]] || continue
    grep -q '\[OMNI\]' "$REPO_ROOT/$f" || unsigned+="$f"$'\n'
  done < <("${G[@]}" diff --name-only "$base_vendor" "$diff_end")
  if [[ -n "$unsigned" ]]; then
    log "⚠️ 以下文件相对 $base_vendor 被改过但无 [OMNI] 标记（方案 §3.2，自动接受将被拒绝）:"
    echo "$unsigned" | sed 's/^/    /'
  fi
fi

# ---------- 3. 合并 / 继续 ----------

conflicts=0
if [[ $CONT -eq 0 ]]; then
  "${G[@]}" tag -f "vendor/$target" "refs/tags/$target"
  pre_merge_sha="$( "${G[@]}" rev-parse HEAD )"
  printf 'target=%s\ntier=%s\npre_merge_sha=%s\n' "$target" "$kind" "$pre_merge_sha" > "$STATE"
  log "合并前基线 ${pre_merge_sha}（回滚: sync.sh --abort）"
  if "${G[@]}" merge --no-ff "refs/tags/$target" -m "chore(sync): merge upstream $target"; then
    conflicts=0
  else
    conflicts=1
  fi
else
  GQ "refs/tags/vendor/$target" || "${G[@]}" tag -f "vendor/$target" "refs/tags/$target"
fi

# ---------- 4. AI：变更简报 + 冲突分诊 ----------

export AI_API_BASE AI_API_KEY AI_MODEL
brief_file="$REPORTS/$ts-$safe_target-brief.md"
if [[ $CONT -eq 0 && -n "$last" && -n "${AI_API_KEY:-}" ]]; then
  node "$KIT_DIR/ai_conflict_triage.mjs" --mode changelog --repo "$REPO_ROOT" \
    --base "synced/$last" --target "$target" --out "$brief_file" || true
fi

remaining=0
if [[ $conflicts -eq 1 ]]; then
  node "$KIT_DIR/ai_conflict_triage.mjs" --repo "$REPO_ROOT" --out "$REPORTS/$ts-$safe_target-triage.md" || true
  if [[ -f "$REPO_ROOT/triage-remaining.txt" ]]; then
    remaining="$(wc -l < "$REPO_ROOT/triage-remaining.txt" | tr -d ' ')"
    rm -f "$REPO_ROOT/triage-remaining.txt" # 运行时产物，不能进 wip commit
  fi
  # 已解文件脚本内已 git add；剩余冲突原样暂存（带标记），保证 diff 可见
  "${G[@]}" add -A
  "${G[@]}" commit -m "wip(sync): merge upstream $target — 剩余冲突已暂存待人工" || true
  if [[ $remaining -gt 0 ]]; then
    cat > "$report" <<EOF
# 同步报告：${target}（未完成）

- 剩余冲突 $remaining 个，见 $REPORTS/$ts-$safe_target-triage.md
- 人工解决并 commit 后执行: sync.sh --continue
- 放弃本次同步: sync.sh --abort
EOF
    log "剩余冲突 $remaining 个 → 停在 main 上的合并中状态，报告 $report"
    notify "OmniRoute 同步 ${target}：剩余冲突 ${remaining}，待人工"
    exit 3
  fi
fi

# ---------- 5. 门禁：补丁核对 / 本地测试 ----------

patch_rc=0
bash "$KIT_DIR/check_local_patches.sh" --against "$target" --out "$REPORTS/$ts-$safe_target-patches.md" || patch_rc=$?
bash "$KIT_DIR/divergence_report.sh" "vendor/$target" HEAD --out "$REPORTS/$ts-$safe_target-divergence.md" || true

if [[ $patch_rc -ne 0 ]]; then
  err "补丁核对失败（有丢失的本地补丁），阻塞接受。报告 $REPORTS/$ts-$safe_target-patches.md"
  notify "OmniRoute 同步 ${target}：补丁核对失败，阻塞"
  exit 1
fi

if [[ -n "$TEST_CMD" ]]; then
  log "运行本地验证: $TEST_CMD"
  if ! ( cd "$REPO_ROOT" && bash -c "$TEST_CMD" ); then
    err "本地验证失败，阻塞接受（回滚: sync.sh --abort）"
    notify "OmniRoute 同步 ${target}：本地测试失败，阻塞"
    exit 1
  fi
else
  log "⚠️ 未配置 TEST_CMD，无本地验证门禁（sync.conf）"
fi

# ---------- 6. 决策：接受 / 停下待人工 ----------

accept=0
if [[ $kind == patch && "$AUTO_ACCEPT_PATCH" == "true" && $remaining -eq 0 && -z "$unsigned" ]]; then
  accept=1; how="自动接受（patch + 无剩余冲突 + 无未标记改动）"
elif [[ $YES -eq 1 ]]; then
  accept=1; how="人工 --yes 确认"
elif [[ -t 0 ]]; then
  printf "接受 $target 并%s? [y/N] " "$([[ $NO_BUILD -eq 1 ]] && echo "合入（不构建）" || echo "构建发布")"
  read -r ans
  if [[ "$ans" == y* || "$ans" == Y* ]]; then accept=1; how="交互确认"; fi
fi

if [[ $accept -ne 1 ]]; then
  cat > "$report" <<EOF
# 同步报告：${target}（待人工决策）

- 分级: ${kind}；上游已合入本地 main（未打 synced 标签）
- AI 简报: $( [[ -f "$brief_file" ]] && echo "$brief_file" || echo 无 )
- 冲突分诊: $( [[ -f "$REPORTS/$ts-$safe_target-triage.md" ]] && echo "$REPORTS/$ts-$safe_target-triage.md" || echo 无冲突 )
- 补丁核对 / 分叉度: $REPORTS/$ts-$safe_target-patches.md / $REPORTS/$ts-$safe_target-divergence.md
- 接受并发布: sync.sh --continue --yes $([[ $NO_BUILD -eq 1 ]] && echo --no-build)
- 放弃: sync.sh --abort
EOF
  log "已停下待人工决策，报告 $report"
  notify "OmniRoute 同步 $target 待人工决策"
  exit 0
fi

# ---------- 7. 接受：打 synced 标签 + 发布 ----------

"${G[@]}" tag "synced/$target" -m "synced upstream $target ($how)"
rm -f "$STATE" "$REPO_ROOT/triage-remaining.txt"
cat > "$report" <<EOF
# 同步报告：${target}（已接受）

- 方式: ${how}；synced 标签已打在 $("${G[@]}" rev-parse --short HEAD)
- AI 简报: $( [[ -f "$brief_file" ]] && echo "$brief_file" || echo 无 )
- 冲突分诊: $( [[ -f "$REPORTS/$ts-$safe_target-triage.md" ]] && echo "$REPORTS/$ts-$safe_target-triage.md" || echo 无冲突 )
- 补丁核对 / 分叉度: $REPORTS/$ts-$safe_target-patches.md / $REPORTS/$ts-$safe_target-divergence.md
EOF
log "已接受 ${target}（synced 标签就位）"
notify "OmniRoute 已接受上游 $target"

# ---------- 7.1 推送到 fork 自己的远端 ----------

if [[ $NO_PUSH -eq 0 && "${PUSH_AFTER_ACCEPT:-true}" == "true" && $HAS_ORIGIN -eq 1 ]]; then
  if "${G[@]}" push origin main "refs/tags/synced/$target" "refs/tags/vendor/$target"; then
    log "已推送 main 与 synced/vendor 标签到 origin"
  else
    err "推送到 origin 失败（网络/凭据？）。本地已接受不受影响，稍后手动: git push origin main --tags"
    notify "OmniRoute 同步 $target：origin 推送失败，需手动补推"
  fi
fi

if [[ $NO_BUILD -eq 0 ]]; then
  bash "$KIT_DIR/release.sh" "$ver_num"
else
  log "跳过构建发布（--no-build）；需要时手动: release.sh $ver_num"
fi
