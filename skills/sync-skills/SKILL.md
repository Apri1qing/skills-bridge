---
name: sync-skills
description: 同步 skills 到公共仓库 ~/.agents/skills/：Claude 插件纯 skill 拷贝进去；Codex ~/.codex/skills 纯 skill 迁走（删 .codex 实体防双份）；反向给 Claude 补 ~/.claude/skills 软链。绑宿主（hooks/MCP/.system/内置工具）SKIP。装/升级/卸载插件后、整理 Codex skills、或要求同步/预览/列出受管副本时使用。
---

# Sync Skills

让 `~/.agents/skills/` 成为不绑宿主的纯 skill 单一事实源。

| 方向 | 行为 |
|---|---|
| Claude 插件 → agents | 拷贝 + `.synced-from-plugin` marker；功能型插件 SKIP |
| Codex `~/.codex/skills` → agents | 纯 skill **迁走**（拷贝后删 `.codex` 实体）；`.system`/绑宿主 SKIP；`.codex→.claude` 旁路软链删除 |
| agents → Claude | 给 `~/.claude/skills/` 补软链；插件真身已加载的去重 |

## 判定

- **绑宿主（不进 agents）**：含 `hooks/`、`commands/`、`.mcp.json`、`mcp`；或 `agents/` 里不止展示用 `openai.yaml`；或正文依赖 Codex 内置 `image_gen`；或 `.system/`
- **纯 skill**：其余有 `SKILL.md` 的目录

## Workflow

```bash
# <skill-dir> = 本 skill 目录
bash <skill-dir>/scripts/sync-skills.sh              # 全量同步
bash <skill-dir>/scripts/sync-skills.sh --dry-run    # 只预览
bash <skill-dir>/scripts/sync-skills.sh list         # 列出受管副本
bash <skill-dir>/scripts/sync-skills.sh --force      # 覆盖手管目录（需明确要求）
```

### 同步后报告

汇总：`SYNC` / `MIGRATE-CODEX` / `DEDUP-CODEX` / `REMOVE-BYPASS` / `SKIP-PLUGIN` / `SKIP-CODEX-BOUND` / `CLEAN` / `LINK` / `UNLINK`。  
`SKIP-PLUGIN` 仍按原流程：为其他 agent 查等价安装（经确认再装）。

### 验证

```bash
ls ~/.agents/skills/ | head -20
cat ~/.agents/skills/<name>/.synced-from-plugin   # 或 .synced-from-codex
ls ~/.codex/skills                                 # 纯 skill 迁完后应主要剩 .system
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print | wc -l   # 应为 0
```

## Notes

- Codex 迁走不留软链在 `.codex`，避免 slash 同名双份（Codex 已扫 agents）
- Claude 继续读插件真身；仓库入口是软链，仅补缺
- 手管（无 marker）的 agents 目录默认不覆盖；Codex 源也保留直至 `--force`
