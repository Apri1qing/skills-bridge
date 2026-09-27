---
name: sync-skills
description: 同步 skills 到公共目录 ~/.agents/skills/：Claude 插件纯 skill 拷贝；Codex ~/.codex/skills 纯 skill 迁走；Claude ~/.claude/skills 实体 skill 迁走（原位补软链）；反向给 Claude 补软链。若已 setup/init 过 vault 则前后接全量镜像；**未配置则静默跳过、不问**（命令在本插件 scripts/vault-mirror.sh（含 init 从零建仓）；vault 仓只存内容）。绑宿主 SKIP。装/升级/卸载插件后、整理 Codex、或要求同步/预览/列出受管副本时使用。
---

# Sync Skills

`~/.agents/skills/` = 本机纯 skill 事实源；**skills-vault** = 多机内容镜像（无命令）。所有命令在本插件。

| 步骤 | 行为 |
|---|---|
| vault pre | `vault-mirror.sh sync`：git pull，vault↔agents 合并 |
| Claude / Codex bridge | 插件拷贝、Codex 迁入、Claude 实体迁入（原位补软链）、Claude 软链 |
| vault post | `vault-mirror.sh sync --commit`：镜像回仓并 push |

## Commands

Daily entry is the sync script (vault mirror runs automatically **only when already configured**):

```bash
# <skill-dir> = this skill's directory in the installed plugin
bash <skill-dir>/scripts/sync-skills.sh
bash <skill-dir>/scripts/sync-skills.sh --dry-run
bash <skill-dir>/scripts/sync-skills.sh --skip-vault   # host sync only
bash <skill-dir>/scripts/sync-skills.sh list
bash <skill-dir>/scripts/sync-skills.sh --force        # only if user explicitly asks
```

Multi-machine vault setup is **`init-vault`**, not this skill. Do not prompt about vault when none is configured.

## 模型接手：功能型插件的等价物

脚本输出 `SKIP-PLUGIN` 后，剩下的部分由模型完成：

1. **探测本地在装的其他 agent**：检查 `~/.codex`、`~/.gemini`、`~/.cursor`、`~/.grok` 等目录，存在即视为在装
2. **联网查等价装法**：对每个被跳过的功能型插件，搜索它在这些 agent 上的等价安装方式（官方 marketplace / 仓库 / 安装命令）
3. **经用户确认后安装**：列出查到的装法，用户确认才执行；查不到等价物就直说没有，不硬凑
4. **排除名单建议**：同步进来的 skill 里，内容只对 Claude Code 有意义的（引用 Claude 专属机制、插件内部路径等），点名建议用户加入 vault 的 `exclude.txt`

## 判定

- `~/.claude/skills` 里的实体**一律按纯 skill 处理**：Claude Code 用户 skill 目录机制上只有 SKILL.md + 资源（hooks/commands/MCP/agents 是插件层概念，只会出现在 `~/.claude/plugins/`），不做绑宿主判定
- Codex 侧绑宿主不进 agents：依赖内置 image_gen（SKILL.md 正文引用）、`.system/` 系统 skill；其余一律纯 skill，`agents/` 是声明性元数据（如 openai.yaml），其他 agent 忽略
- `.synced-*`、密钥文件不进 vault


