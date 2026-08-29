#!/usr/bin/env bash
# 执行 FORK_TODO_CN.md 中全部有效二开功能的聚焦回归。
# 用法: run_fork_regressions.sh [--manifest <tsv>] [--ledger <md>] [--out <md>]
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
manifest="$script_dir/REGRESSIONS.tsv"
ledger="$repo_root/FORK_TODO_CN.md"
out=""
NODE_BIN="${NODE_BIN:-node}"
export NODE_BIN

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    --ledger) ledger="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[[ -f "$manifest" ]] || { echo "::error::二开回归清单不存在: $manifest" >&2; exit 2; }
[[ -f "$ledger" ]] || { echo "::error::二开变更台账不存在: $ledger" >&2; exit 2; }

ledger_ids="$({
  awk '
    /^## 当前有效变更索引/ { in_index=1; next }
    in_index && /^## / { exit }
    in_index && /^\| `FORK-/ {
      id=$2
      gsub(/[ `]/, "", id)
      print id
    }
  ' "$ledger"
} | sort -u)"

manifest_ids="$({
  while IFS=$'\t' read -r id _; do
    [[ -z "${id// }" || "$id" == \#* ]] && continue
    printf '%s\n' "$id"
  done < "$manifest"
} | sort -u)"

missing="$(comm -23 <(printf '%s\n' "$ledger_ids") <(printf '%s\n' "$manifest_ids"))"
extra="$(comm -13 <(printf '%s\n' "$ledger_ids") <(printf '%s\n' "$manifest_ids"))"
if [[ -n "$missing" || -n "$extra" ]]; then
  [[ -z "$missing" ]] || echo "::error::台账有效项缺少 REGRESSIONS.tsv 命令: ${missing//$'\n'/, }" >&2
  [[ -z "$extra" ]] || echo "::error::REGRESSIONS.tsv 存在未登记的 ID: ${extra//$'\n'/, }" >&2
  exit 1
fi

rows=""
failed=0
passed=0
while IFS=$'\t' read -r id description command extra_column; do
  [[ -z "${id// }" || "$id" == \#* ]] && continue
  if [[ -z "$description" || -z "$command" || -n "${extra_column:-}" ]]; then
    echo "::error::REGRESSIONS.tsv 行格式错误（必须恰好 3 列）: $id" >&2
    exit 2
  fi

  echo "[fork-regression] $id: $description"
  if (cd "$repo_root" && bash -c "$command"); then
    status="通过"
    passed=$((passed + 1))
  else
    status="失败"
    failed=$((failed + 1))
  fi
  rows+="| ${id} | ${description} | ${status} | \`${command//\|/\\|}\` |"$'\n'
done < "$manifest"

body="# 二开聚焦回归

- 通过：${passed}
- 失败：${failed}

| ID | 说明 | 结果 | 命令 |
|---|---|---|---|
${rows}"

[[ -z "$out" ]] || printf '%s\n' "$body" > "$out"
printf '%s\n' "$body"

[[ $failed -eq 0 ]]
