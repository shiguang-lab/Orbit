#!/usr/bin/env bash
# 分叉度 KPI 报告（fork-sync-kit）—— 方案见 OMNIROUTE_FORK_SYNC_CN.md §3.5
#
# 用法:
#   divergence_report.sh <base-ref> [<head-ref>] [--out <file>]
#     base-ref  通常是 vendor/<版本> tag；base..head 的 diff 即完整二开差异
#     head-ref  默认 HEAD
#
# 输出: markdown（触碰的上游文件数 / 新增本地文件数 / diff 行数 / [OMNI] 数 / 阈值告警）
set -euo pipefail

base="${1:?用法: divergence_report.sh <base-ref> [<head-ref>] [--out <file>]}"
head="${2:-HEAD}"
out=""
shift 2 2>/dev/null || true
# 兼容第 2 参为 --out 的调用方式
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done

TH_FILES="${OMNI_KPI_MAX_FILES:-40}"     # 触碰上游文件数阈值
TH_PATCHES="${OMNI_KPI_MAX_PATCHES:-15}" # [OMNI] 补丁数阈值

shortstat="$(git diff --shortstat "$base" "$head" || echo '（无差异）')"
touched="$(git diff --name-only "$base" "$head" || true)"

up_files=()
new_files=()
if [[ -n "$touched" ]]; then
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if git cat-file -e "${base}:${f}" 2>/dev/null; then
      up_files+=("$f")
    else
      new_files+=("$f")
    fi
  done <<< "$touched"
fi

omni_count=0
# 排除 fork-sync-kit 自身（脚本/文档里也含 [OMNI] 字样，会虚增计数）
omni_count="$(git grep -o -e '\[OMNI\]' "$head" -- . ':(exclude)fork-sync-kit' 2>/dev/null | wc -l | tr -d ' ' || true)"

up_list=""
if [[ ${#up_files[@]} -gt 0 ]]; then
  up_list="### 触碰的上游文件（${#up_files[@]}）

$(printf '%s\n' "${up_files[@]}" | head -50 | sed 's/^/- /')
$( [[ ${#up_files[@]} -gt 50 ]] && echo "- …（共 ${#up_files[@]} 个，截断）" )
"
fi

alert=""
if [[ ${#up_files[@]} -gt $TH_FILES ]]; then
  alert+="

> ⚠️ 告警：触碰上游文件 ${#up_files[@]} 超过阈值 ${TH_FILES}，该区域需要造缝或加大回流（方案 §3.5）。"
fi
if [[ $omni_count -gt $TH_PATCHES ]]; then
  alert+="

> ⚠️ 告警：[OMNI] 补丁 ${omni_count} 个超过阈值 ${TH_PATCHES}，触发架构评审。"
fi

body="# 分叉度 KPI（${base} → ${head}）

- 相对上游差异：${shortstat}
- 触碰的上游文件：**${#up_files[@]}**（阈值 ${TH_FILES}）
- 新增本地文件：${#new_files[@]}（local/ 等纯加法，不计入告警）
- [OMNI] 标记数：**${omni_count}**（阈值 ${TH_PATCHES}）${alert}

${up_list}
"

if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; fi
printf '%s' "$body"
