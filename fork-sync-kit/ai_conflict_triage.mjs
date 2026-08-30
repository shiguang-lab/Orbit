#!/usr/bin/env node
/**
 * AI 冲突分诊 + 上游变更简报（fork-sync-kit）
 * 方案见 OMNIROUTE_FORK_SYNC_CN.md §4.3。零依赖，Node >= 18。
 *
 * 用法:
 *   node ai_conflict_triage.mjs --mode triage    --repo . --out ai-triage-report.md
 *   node ai_conflict_triage.mjs --mode changelog --repo . --base synced/release/v3.8.51 \
 *        --target release/v3.8.52 --out changelog-brief.md
 *
 * triage 模式（默认）:
 *   1. 列出 git 未合并文件（git diff --name-only --diff-filter=U）
 *   2. 逐文件提取冲突块（含上下文），调用 OpenAI 兼容 LLM 逐块判定
 *   3. 文件级"全有全无"：该文件所有冲突块都判 auto 才改写落盘并 git add；
 *      任一块 manual -> 整文件保留冲突标记，进人工
 *   4. 输出: 报告 markdown + triage-remaining.txt（未解文件清单，供流水线判断能否自动合并）
 *
 * changelog 模式:
 *   取 base..target 的上游 commit 列表与本地触碰文件，产出关联分析简报。
 *
 * 环境变量:
 *   AI_API_BASE  OpenAI 兼容网关（默认 https://open.bigmodel.cn/api/paas/v4）
 *   AI_API_KEY   必填（triage 与 changelog 模式均需要）
 *   AI_MODEL     默认 glm-4.6（按实际网关填写）
 *   OMNI_MIN_CONFIDENCE   置信度阈值，低于视同 manual（默认 0.9）
 *   OMNI_MAX_HUNK_LINES   单冲突块最大行数，超过直接 manual（默认 200）
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// ---------- 参数 ----------

function argVal(flag, dflt) {
  const i = process.argv.indexOf(flag);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const mode = argVal("--mode", "triage");
const repo = path.resolve(argVal("--repo", "."));
const outFile = path.resolve(repo, argVal("--out", mode === "changelog" ? "changelog-brief.md" : "ai-triage-report.md"));
const minConfidence = Number(process.env.OMNI_MIN_CONFIDENCE || "0.9");
const maxHunkLines = Number(process.env.OMNI_MAX_HUNK_LINES || "200");

// ---------- 基础工具 ----------

const git = (...args) =>
  execFileSync("git", args, { cwd: repo, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });

function readPatchManifest() {
  const p = path.join(repo, "fork-sync-kit", "PATCHES.tsv");
  if (!fs.existsSync(p)) return [];
  return fs
    .readFileSync(p, "utf8")
    .split("\n")
    .filter((l) => l.trim() && !l.startsWith("#"))
    .map((l) => l.split("\t"));
}

// PATCHES.tsv 登记过的文件 = 钩子/补丁保护清单，AI 一律不碰
function protectedPaths() {
  return new Set(readPatchManifest().map((cols) => (cols[2] || "").trim()).filter(Boolean));
}

async function chat(messages) {
  const base = (process.env.AI_API_BASE || "https://open.bigmodel.cn/api/paas/v4").replace(/\/+$/, "");
  const key = process.env.AI_API_KEY;
  if (!key) throw new Error("缺少 AI_API_KEY 环境变量");
  const model = process.env.AI_MODEL || "glm-4.6";
  const res = await fetch(`${base}/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
    body: JSON.stringify({ model, messages, temperature: 0 }),
  });
  if (!res.ok) throw new Error(`LLM HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  return data.choices?.[0]?.message?.content ?? "";
}

function parseJsonLoose(text) {
  const m = text.match(/\{[\s\S]*\}/);
  if (!m) throw new Error("LLM 未返回 JSON");
  return JSON.parse(m[0]);
}

// ---------- triage 模式 ----------

// 解析冲突块。返回 [{ start, end, ours[], theirs[] }]，行号 0-based（含首尾标记行）
function parseConflicts(lines) {
  const blocks = [];
  let cur = null;
  let side = null;
  lines.forEach((line, i) => {
    if (line.startsWith("<<<<<<<")) {
      cur = { start: i, ours: [], theirs: [] };
      side = "ours";
      return;
    }
    if (cur && line.startsWith("=======")) {
      side = "theirs";
      return;
    }
    if (cur && line.startsWith(">>>>>>>")) {
      cur.end = i;
      blocks.push(cur);
      cur = null;
      side = null;
      return;
    }
    if (cur) cur[side].push(line);
  });
  return blocks;
}

function rebuild(lines, blocks, resolutions) {
  const out = [];
  let i = 0;
  let bi = 0;
  while (i < lines.length) {
    const b = blocks[bi];
    if (b && i === b.start) {
      out.push(...resolutions.get(bi));
      i = b.end + 1;
      bi++;
    } else {
      out.push(lines[i]);
      i++;
    }
  }
  return out;
}

function contextOf(lines, b) {
  const from = Math.max(0, b.start - 5);
  const to = Math.min(lines.length, b.end + 6);
  return lines.slice(from, to).join("\n");
}

function buildTriagePrompt(file, hunks) {
  const numbered = hunks
    .map(
      (b, i) =>
        `### 冲突块 ${i}\n上下文:\n\`\`\`\n${contextOf(b.ctx, b)}\n\`\`\`\nours(本地二开侧):\n\`\`\`\n${b.ours.join("\n")}\n\`\`\`\ntheirs(上游新侧):\n\`\`\`\n${b.theirs.join(
          "\n"
        )}\n\`\`\``,
    )
    .join("\n\n");
  return {
    system:
      "你是资深工程助理，帮助一个开源项目的下游 fork 解决 git 合并冲突。" +
      "规则：\n" +
      "1. ours = 本地二开代码（通常带 [OMNI] 标记），theirs = 上游官方新版；\n" +
      "2. 只有当两侧改动互不相交、能机械合并（如双方各自新增、import 并集、明显同一修复取其一）时才判 auto；" +
      "涉及逻辑语义、调用顺序、同一函数被两侧各改一版的一律 manual；\n" +
      "3. 不得丢弃 [OMNI] 本地逻辑，除非它与上游修复明显重复（此时选 theirs 并在 reason 说明）；\n" +
      "4. 保守优先：犹豫即 manual；\n" +
      "5. 只输出 JSON：{\"blocks\":[{\"index\":0,\"verdict\":\"auto|manual\",\"strategy\":\"ours|theirs|merged\"," +
      "\"merged\":\"仅 strategy=merged 且 verdict=auto 时提供整块合并后的完整代码\",\"reason\":\"简短中文理由\",\"confidence\":0~1}]}，" +
      "blocks 必须覆盖每一个冲突块，index 对应编号。",
    user: `文件: ${file}\n冲突块共 ${hunks.length} 个:\n\n${numbered}`,
  };
}

function validateAndResolve(hunks, parsed) {
  const resolutions = new Map();
  const reasons = [];
  const byIndex = new Map((parsed.blocks || []).map((b) => [Number(b.index), b]));
  for (let i = 0; i < hunks.length; i++) {
    const b = byIndex.get(i);
    const hunk = hunks[i];
    if (!b || b.verdict !== "auto") {
      reasons.push(`块${i}: manual（${b?.reason || "LLM 未给出有效判定"}）`);
      return { ok: false, reasons };
    }
    const conf = Number(b.confidence ?? 0);
    if (!(conf >= minConfidence)) {
      reasons.push(`块${i}: manual（置信度 ${conf} < ${minConfidence}）`);
      return { ok: false, reasons };
    }
    let replacement;
    if (b.strategy === "ours") replacement = hunk.ours;
    else if (b.strategy === "theirs") replacement = hunk.theirs;
    else if (b.strategy === "merged" && typeof b.merged === "string" && b.merged.length > 0)
      replacement = b.merged.replace(/\r?\n$/, "").split("\n");
    else {
      reasons.push(`块${i}: manual（strategy/merged 无效）`);
      return { ok: false, reasons };
    }
    if (replacement.length > maxHunkLines * 2) {
      reasons.push(`块${i}: manual（合并结果异常膨胀）`);
      return { ok: false, reasons };
    }
    resolutions.set(i, replacement);
    reasons.push(`块${i}: auto/${b.strategy}（${b.reason}，置信度 ${conf}）`);
  }
  return { ok: true, resolutions, reasons };
}

async function runTriage() {
  const protectedPathsSet = protectedPaths();
  const conflicted = git("diff", "--name-only", "--diff-filter=U")
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
  const report = [];
  const remaining = [];

  if (conflicted.length === 0) {
    fs.writeFileSync(outFile, "# AI 冲突分诊报告\n\n本次 merge 无冲突。\n");
    fs.writeFileSync(path.join(repo, "triage-remaining.txt"), "");
    console.log("无冲突，报告已写出");
    return;
  }
  if (!process.env.AI_API_KEY) {
    // 无 AI 凭据：全部留给人，流程不中断
    fs.writeFileSync(outFile, "# AI 冲突分诊报告\n\n未配置 AI_API_KEY，所有冲突留待人工。\n");
    fs.writeFileSync(path.join(repo, "triage-remaining.txt"), conflicted.join("\n") + "\n");
    console.log("未配置 AI_API_KEY，全部冲突留人工");
    return;
  }

  for (const file of conflicted) {
    try {
      if (protectedPathsSet.has(file)) {
        remaining.push(file);
        report.push({ file, ok: false, why: "钩子/补丁保护清单内，AI 不碰" });
        continue;
      }
      const raw = fs.readFileSync(path.join(repo, file), "utf8");
      const lines = raw.split("\n");
      let hunks = parseConflicts(lines);
      hunks.forEach((b) => (b.ctx = lines));
      if (
        hunks.length === 0 ||
        hunks.length > 30 ||
        lines.length > 2000 ||
        hunks.some((b) => b.end - b.start > maxHunkLines)
      ) {
        remaining.push(file);
        report.push({ file, ok: false, why: "块数/行数超限，直接人工" });
        continue;
      }

      const prompt = buildTriagePrompt(file, hunks);
      let parsed;
      try {
        parsed = parseJsonLoose(await chat([prompt.system, prompt.user].map((c, i) => ({ role: i === 0 ? "system" : "user", content: c }))));
      } catch (e) {
        // 一次重试机会
        try {
          parsed = parseJsonLoose(
            await chat([
              { role: "system", content: prompt.system },
              { role: "user", content: prompt.user + "\n\n（上次输出解析失败，请严格只输出 JSON）" },
            ]),
          );
        } catch {
          throw new Error(`LLM 调用/解析失败: ${e.message}`);
        }
      }
      const result = validateAndResolve(hunks, parsed);
      if (result.ok) {
        const rebuilt = rebuild(lines, hunks, result.resolutions).join("\n");
        fs.writeFileSync(path.join(repo, file), rebuilt);
        git("add", "--", file);
        report.push({ file, ok: true, why: result.reasons.join("；") });
        console.log(`✅ AI 已解: ${file}`);
      } else {
        remaining.push(file);
        report.push({ file, ok: false, why: result.reasons.join("；") });
        console.log(`⚠️ 人工: ${file}`);
      }
    } catch (e) {
      remaining.push(file);
      report.push({ file, ok: false, why: `异常: ${e.message}` });
      console.log(`⚠️ 异常: ${file}: ${e.message}`);
    }
  }

  const lines = [
    "# AI 冲突分诊报告（自动生成）",
    "",
    `策略：文件级全有全无；置信度阈值 ${minConfidence}；单块>${maxHunkLines}行/文件>2000行/块>30 直接人工；`,
    "PATCHES.tsv 登记文件为保护清单，AI 不碰。✅ = AI 已自动解（git add 完成）；⚠️ = 保留冲突标记待人工。",
    "",
    "| 文件 | 结果 | 说明 |",
    "|---|---|---|",
    ...report.map((r) => `| ${r.file} | ${r.ok ? "✅ AI 已解" : "⚠️ 人工"} | ${r.why.replaceAll("|", "\\|").slice(0, 400)} |`),
    "",
    `小结：AI 已解 ${report.filter((r) => r.ok).length} 个文件，待人工 ${remaining.length} 个。`,
    "",
  ];
  fs.writeFileSync(outFile, lines.join("\n"));
  fs.writeFileSync(path.join(repo, "triage-remaining.txt"), remaining.join("\n") + (remaining.length ? "\n" : ""));
  console.log(`分诊完成：已解 ${report.filter((r) => r.ok).length}，待人工 ${remaining.length}，报告 ${outFile}`);
}

// ---------- changelog 模式 ----------

// 本地主分支 ref：优先 origin/main，纯本地仓库回退 main
function mainRef() {
  try {
    git("rev-parse", "--verify", "-q", "origin/main");
    return "origin/main";
  } catch {
    return "main";
  }
}

async function runChangelog(base, target) {
  const commits = git(
    "log",
    "--oneline",
    "--no-merges",
    `${base}..refs/tags/${target}`,
  )
    .split("\n")
    .filter(Boolean);
  const localTouched = git("diff", "--name-only", base, mainRef())
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
  const upstreamFiles = new Set(
    git("diff", "--name-only", base, `refs/tags/${target}`)
      .split("\n")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const overlap = localTouched.filter((f) => upstreamFiles.has(f));
  const ledgerPath = path.join(repo, "FORK_TODO_CN.md");
  const ledger = fs.existsSync(ledgerPath) ? fs.readFileSync(ledgerPath, "utf8") : "";
  const ledgerExcerpt =
    ledger.match(/## 当前有效变更索引[\s\S]*?(?=\n## 问题 1：|$)/)?.[0] ??
    "未找到当前有效变更索引";

  if (!process.env.AI_API_KEY) {
    const fallback = [
      `# 上游变更简报（${base} → ${target}，未配置 AI，仅原始清单）`,
      "",
      `- 上游 commit 数：${commits.length}`,
      `- 本地触碰文件与上游变更文件交集（${overlap.length}）：`,
      ...overlap.map((f) => `  - ${f}`),
      "",
      "## 二开有效变更、合并规则与回归矩阵",
      "",
      ledgerExcerpt,
      "",
    ].join("\n");
    fs.writeFileSync(outFile, fallback);
    console.log(`未配置 AI_API_KEY，已输出原始清单 ${outFile}`);
    return;
  }

  const content = await chat([
    {
      role: "system",
      content:
        "你是资深工程助理。一个开源项目的下游 fork 正在合入上游新版本。" +
        "输入：上游 commit 列表、本地 fork 触碰过的文件（含 [OMNI] 补丁与钩子）、两者的交集文件，以及二开有效变更、合并规则与回归矩阵。" +
        '请输出 markdown 简报，包含四节：1) 上游变更摘要（按主题归组，不逐条罗列）；' +
        '2) 逐个二开 ID 给出明确处置（保留/人工整合/改用上游/无影响）及依据；' +
        '3) 本次必须执行的聚焦回归与额外真实环境检查；4) 建议人工关注的点（排序，最多 5 条）。' +
        "不得在没有证据时建议丢弃二开行为。中文，简洁。",
    },
    {
      role: "user",
      content: `范围: ${base} → ${target}\n上游 commit（${commits.length}）:\n${commits.slice(0, 200).join("\n")}\n\n本地触碰文件（${localTouched.length}）:\n${localTouched.slice(0, 200).join("\n")}\n\n交集文件（${overlap.length}）:\n${overlap.slice(0, 100).join("\n")}\n\n二开台账:\n${ledgerExcerpt.slice(0, 20000)}`,
    },
  ]);
  fs.writeFileSync(outFile, `# 上游变更简报（${base} → ${target}）\n\n${content}\n`);
  console.log(`变更简报已写出 ${outFile}`);
}

// ---------- 入口 ----------

if (mode === "changelog") {
  const base = argVal("--base", "");
  const target = argVal("--target", "");
  if (!base || !target) {
    console.error("changelog 模式需要 --base 与 --target");
    process.exit(2);
  }
  runChangelog(base, target).catch((e) => {
    console.error(`::error::changelog 简报失败: ${e.message}`);
    fs.writeFileSync(outFile, `# 上游变更简报\n\n生成失败: ${e.message}\n`);
    process.exit(0); // 简报失败不阻塞流水线
  });
} else {
  runTriage().catch((e) => {
    console.error(`::error::分诊失败: ${e.message}`);
    // 分诊脚本自身故障不掩盖冲突：如有未合并文件，全部标记为待人工
    try {
      const conflicted = git("diff", "--name-only", "--diff-filter=U")
        .split("\n")
        .filter(Boolean);
      fs.writeFileSync(path.join(repo, "triage-remaining.txt"), conflicted.join("\n") + "\n");
      fs.writeFileSync(outFile, `# AI 冲突分诊报告\n\n脚本异常，全部冲突留待人工：${e.message}\n`);
    } catch {}
    process.exit(0);
  });
}
