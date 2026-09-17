---
name: skills-maintenance
description: 一键更新并同步整个 skills 体系：skills CLI 更新（npx skills update）、Claude Code 插件更新，然后调用 sync-skills（内含 vault-mirror pull→整理→镜像回仓）。当用户要求一键维护/更新整个 skills 体系、或运行 /skills-maintenance 时使用。
---

# Skills Maintenance

一键维护 skills 体系：两个更新源 + 双向同步（**含 vault 多机镜像**）。全部步骤顺序执行，每步有完成标准，最后输出汇总报告。

## Step 1: 更新 agents 里 skills CLI 管理的 skills

```bash
npx -y skills update -g -y
```

**完成标准**：命令退出码 0，记录输出中 `Updated N skill(s)` 的 N。

## Step 2: 更新 Claude Code 插件

```bash
for p in $(python3 -c "
import json
d = json.load(open('$HOME/.claude/plugins/installed_plugins.json'))
print(' '.join(d['plugins'].keys()))"); do
  claude plugin update "$p" 2>&1 | tail -1
done
```

**完成标准**：每个插件都有结果行；`Failed` 的单独列出告知用户。refreshed 类结果提醒用户"重启会话生效"。

## Step 3: 双向同步 + vault 镜像

执行姊妹 skill `sync-skills`（与本 skill 同源安装，用 Skill 工具调用）。`sync-skills` 默认会：

1. vault `git pull` 并合并进 `~/.agents/skills`
2. Claude 插件 / Codex → agents，agents → Claude 软链
3. agents 全量镜像回 vault 并 commit/push

**完成标准**：脚本跑完；记录 SYNC / SKIP-PLUGIN / CLEAN / LINK / UNLINK 与 vault pre/post；Claude 入口断链数为 0：

```bash
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print | wc -l
```

只要 bridge、不要动私库时，在 sync-skills 加 `--skip-vault`。

## 汇总报告

三步全部完成后，向用户输出一张表：每步的结果（更新数/同步数/新建入口数/vault 是否 push）以及需要重启会话才生效的项。
