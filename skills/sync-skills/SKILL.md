---
name: sync-skills
description: 同步 skills 到公共仓库 ~/.agents/skills/：Claude 插件纯 skill 拷贝进去；Codex ~/.codex/skills 纯 skill 迁走（删 .codex 实体防双份）；反向给 Claude 补 ~/.claude/skills 软链。默认前后接 skills-vault（先 pull 合并，后把 agents 全量镜像回私库并 commit/push）。绑宿主（hooks/MCP/.system/内置工具）SKIP。装/升级/卸载插件后、整理 Codex skills、或要求同步/预览/列出受管副本时使用。
---

# Sync Skills

让 `~/.agents/skills/` 成为不绑宿主的纯 skill 单一事实源；并作为 **skills-vault 多机镜像的本机入口**。

| 步骤 | 行为 |
|---|---|
| vault pre | `skills-vault/scripts/sync.sh sync`：git pull，把远端/vault 合并进 agents |
| Claude 插件 → agents | 拷贝 + `.synced-from-plugin`；功能型插件 SKIP |
| Codex → agents | 纯 skill **迁走**；`.system`/绑宿主 SKIP；旁路软链删除 |
| agents → Claude | 补 `~/.claude/skills/` 软链；插件真身已加载的去重 |
| vault post | `sync.sh sync --commit`：agents 全量镜像回 vault 并 push |

## 判定

- **绑宿主（不进 agents）**：含 `hooks/`、`commands/`、`.mcp.json`、`mcp`；或 `agents/` 里不止展示用 `openai.yaml`；或正文依赖 Codex 内置 `image_gen`；或 `.system/`
- **纯 skill**：其余有 `SKILL.md` 的目录
- **不上 vault**：见 vault 仓 `exclude.txt`（密钥向/绑宿主/点名排除）；`.synced-*` 不进仓

## Workflow

```bash
# <skill-dir> = 本 skill 目录
bash <skill-dir>/scripts/sync-skills.sh              # 全量：vault pre → bridge → vault post
bash <skill-dir>/scripts/sync-skills.sh --dry-run    # 只预览 bridge（跳过 vault）
bash <skill-dir>/scripts/sync-skills.sh --skip-vault # 只跑 bridge，不动 git 镜像
bash <skill-dir>/scripts/sync-skills.sh list         # 列出受管副本
bash <skill-dir>/scripts/sync-skills.sh --force      # 覆盖手管目录（需明确要求）
```

Vault 路径：环境变量 `SKILLS_VAULT`，或 `~/.config/skills-vault/config`（先跑 vault 的 `./scripts/sync.sh setup`），或默认 `~/Documents/personal/skills-vault`。

### 同步后报告

汇总：`SYNC` / `MIGRATE-CODEX` / `DEDUP-CODEX` / `REMOVE-BYPASS` / `SKIP-PLUGIN` / `SKIP-CODEX-BOUND` / `CLEAN` / `LINK` / `UNLINK`，以及 vault pre/post 是否成功。  
`SKIP-PLUGIN` 仍按原流程：为其他 agent 查等价安装（经确认再装）。

### 验证

```bash
ls ~/.agents/skills/ | head -20
cat ~/.agents/skills/<name>/.synced-from-plugin   # 或 .synced-from-codex
ls ~/.codex/skills                                 # 纯 skill 迁完后应主要剩 .system
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print | wc -l   # 应为 0
```

## Notes

- 日常入口是本 skill / `/skills-maintenance`，不必单独记 vault 命令
- Codex 迁走不留软链在 `.codex`；Claude 继续读插件真身
- 手管（无 marker）的 agents 目录默认不覆盖；Codex 源也保留直至 `--force`
