#!/usr/bin/env bash
# 补丁清单核对（fork-sync-kit）—— 方案见 OMNIROUTE_FORK_SYNC_CN.md §3.3
# 替代 FORK_TODO_CN.md 中"每次追上游后需重新核对"的人工步骤。
#
# 用法:
#   check_local_patches.sh [--against <ref>] [--manifest <tsv>] [--out <file>]
#     --against   与哪个 ref 比对"上游是否已原生修复"，默认 upstream/main
#     --manifest  默认脚本同目录 PATCHES.tsv
#     --out       额外写出 markdown 文件（流水线贴 PR 用），不传则只打印
#
# 判定:
#   丢失 = 工作区该文件缺锚点（补丁没重放成功，阻塞合并，退出码 1）
#   健康 = 本地补丁在位
#   可删 = 上游已含同判定特征（提示，删除前人工确认）
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
against="upstream/main"
manifest="${script_dir}/PATCHES.tsv"
out=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --against)  against="$2"; shift 2 ;;
    --manifest) manifest="$2"; shift 2 ;;
    --out)      out="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$manifest" ]] || { echo "::error::补丁清单不存在: $manifest" >&2; exit 2; }

rows=""
lost=0; healthy=0; removable=0
while IFS=$'\t' read -r id desc file anchor upfix upable extra; do
  [[ -z "${id// }" || "$id" == \#* ]] && continue
  [[ -z "$file" ]] && continue
  status="健康"
  reason=""
  if [[ ! -f "$file" ]]; then
    status="丢失"
    reason="文件不存在于工作区"
  elif ! grep -qE -- "$anchor" "$file"; then
    status="丢失"
    reason="未匹配锚点: $anchor"
  elif [[ -n "${upfix:-}" ]]; then
    if git show "${against}:${file}" 2>/dev/null | grep -qE -- "$upfix"; then
      status="可删"
      reason="上游 ${against} 已含修复特征: $upfix"
    fi
  fi
  [[ -z "${reason:-}" ]] && reason="-"
  case "$status" in
    丢失) lost=$((lost+1)) ;;
    可删) removable=$((removable+1)) ;;
    *)    healthy=$((healthy+1)) ;;
  esac
  rows+="| ${id} | ${desc} | ${file} | ${status} | ${reason} |${upable:+ ${upable} |}|
"
done < "$manifest"

summary="补丁清单核对：健康 ${healthy}，可删 ${removable}，丢失 ${lost}（对照 ${against}）"
body="# ${summary}

| id | 说明 | 文件 | 状态 | 判定依据 | upstreamable |
|---|---|---|---|---|---|
${rows}
"

if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; fi
printf '%s' "$body"
if [[ $lost -gt 0 ]]; then
  echo "::error::存在丢失的本地补丁，合并前必须修复（方案 §3.3）"
  exit 1
fi
