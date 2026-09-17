---
name: sync-skills
description: 同步 skills 到公共目录 ~/.agents/skills/：Claude 插件纯 skill 拷贝；Codex ~/.codex/skills 纯 skill 迁走；反向给 Claude 补软链。若已 setup/init 过 vault 则前后接全量镜像；**未配置则静默跳过、不问**（命令在本插件 scripts/vault-mirror.sh（含 init 从零建仓）；vault 仓只存内容）。绑宿主 SKIP。装/升级/卸载插件后、整理 Codex、或要求同步/预览/列出受管副本时使用。
---

# Sync Skills

`~/.agents/skills/` = 本机纯 skill 事实源；**skills-vault** = 多机内容镜像（无命令）。所有命令在本插件。

| 步骤 | 行为 |
|---|---|
| vault pre | `vault-mirror.sh sync`：git pull，vault↔agents 合并 |
| Claude / Codex bridge | 插件拷贝、Codex 迁入、Claude 软链 |
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


## 判定

- 绑宿主不进 agents：hooks/commands/mcp、非展示 agents、依赖内置 image_gen、`.system/`
- `.synced-*`、密钥文件不进 vault


