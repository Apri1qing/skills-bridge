---
name: sync-skills
description: 同步 skills 到公共目录 ~/.agents/skills/：Claude 插件纯 skill 拷贝；Codex ~/.codex/skills 纯 skill 迁走；反向给 Claude 补软链。默认前后接 vault 全量镜像（命令在本插件 scripts/vault-mirror.sh；vault 仓只存内容）。绑宿主 SKIP。装/升级/卸载插件后、整理 Codex、或要求同步/预览/列出受管副本时使用。
---

# Sync Skills

`~/.agents/skills/` = 本机纯 skill 事实源；**skills-vault** = 多机内容镜像（无命令）。所有命令在本插件。

| 步骤 | 行为 |
|---|---|
| vault pre | `vault-mirror.sh sync`：git pull，vault↔agents 合并 |
| Claude / Codex bridge | 插件拷贝、Codex 迁入、Claude 软链 |
| vault post | `vault-mirror.sh sync --commit`：镜像回仓并 push |

## 命令

```bash
# <skill-dir>/scripts/
bash sync-skills.sh                 # vault pre → bridge → vault post
bash sync-skills.sh --dry-run
bash sync-skills.sh --skip-vault    # 只 bridge
bash sync-skills.sh list
bash sync-skills.sh --force

# 首次配置 vault（路径通用，勿写死）
bash vault-mirror.sh setup /path/to/skills-vault
bash vault-mirror.sh status
bash vault-mirror.sh push-box [/path/to/workflows]   # 通常在 box 上
```

配置：`~/.config/skills-bridge/vault.conf`；或环境变量 `SKILLS_VAULT` / `AGENTS_SKILLS` / `BOX_WORKFLOWS`。  
排除列表在 **vault 仓** 的 `exclude.txt`（数据，不是命令）。

## 判定

- 绑宿主不进 agents：hooks/commands/mcp、非展示 agents、依赖内置 image_gen、`.system/`
- `.synced-*`、密钥文件不进 vault
