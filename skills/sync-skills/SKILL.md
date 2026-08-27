---
name: sync-skills
description: 双向同步 skills：正向把在装 Claude Code 插件的 skills 拷贝到 ~/.agents/skills/（agentskills 标准目录，Codex 等工具原生扫描），反向给仓库里 Claude Code 还看不到的 skill 补软链入口；功能型插件则探测本地在装的其他 agent，联网查等价安装方式并安装。装/升级/卸载插件后、npx skills add 装新 skill 后，或用户要求同步 skills、预览同步、查看受管副本时使用。
---

# Sync Skills

双向同步，让 `~/.agents/skills/` 公共仓库成为所有 agent 的单一事实源：

- **正向**：在装 Claude Code 插件的 skills → 仓库（拷贝），Codex 等工具即可使用
- **反向**：仓库里 Claude Code 还看不到的 skill → `~/.claude/skills/` 软链入口

## 正向：插件 skills → 仓库

- 源为 manifest（installed_plugins.json）登记的在装插件，取其 `skills/*/SKILL.md`，不扫 cache 全目录
- 拷贝（非软链接）到 `~/.agents/skills/<name>/`，用 `.synced-from-plugin` marker 文件记录来源路径
- 过滤 `docs/`、`.agents/`、`.cursor/`、`.claude/` 多语言镜像路径
- 同插件多版本目录时 `sort -V` 保证最新版本最后写入生效
- `~/.claude/skills/` 不在源内（软链接目录，避免回拷）

### Marker 机制

1. **首次同步**：拷贝时在 skill 目录内创建 `.synced-from-plugin`，内容为源路径
2. **重跑同步**：有 marker → 受管副本，安全覆盖（插件升级后重跑即刷新）
3. **手动内容保护**：无 marker 的目录是用户手动管理的，一律跳过
4. **--force**：无视 marker 全量覆盖

## 反向：仓库 → Claude 入口

正向之后自动执行，纯机械：

1. **去重**：`~/.claude/skills/` 里指向带 marker 副本的软链删掉（Claude 已通过插件真身加载，留着是双份）
2. **清断链**：仓库里已删除的 skill 留下的死入口删掉
3. **补缺**：仓库有、Claude 没有的 skill（`npx skills add` 装的、手写的）建软链入口，marker 副本除外

方向不对称是刻意的：正向拷贝（插件路径带版本号会搬家，软链必断），反向软链（仓库路径稳定，`npx skills update` 刷新内容后 Claude 侧零动作即用新版）。

## Workflow

主脚本在本 skill 的 `scripts/` 内，随 skill 一起分发（插件安装、skills CLI 安装两种形态都自包含）。按用户的自然语言意图选择脚本参数：

```bash
# <skill-dir> = 本 skill 的 base directory（Skill 调用时注入）
bash <skill-dir>/scripts/sync-skills.sh              # 默认：双向全量同步（尊重 marker）
bash <skill-dir>/scripts/sync-skills.sh --dry-run    # 用户想先看看会做什么、要求预览时
bash <skill-dir>/scripts/sync-skills.sh list         # 用户只想查看受管副本及其来源时
bash <skill-dir>/scripts/sync-skills.sh --force      # 用户明确要求覆盖手动管理的目录时；有破坏性，未明确要求不要用
```

### 同步后：报告与甄别（模型侧）

脚本只负责机械同步，以下判断由模型完成：

1. **报告**：向用户简要汇总 SYNC / CLEAN / SKIP-PLUGIN / LINK / UNLINK。SYNC 的 skill 对 Codex 即刻可用；CLEAN 为已清理的受管副本；SKIP-PLUGIN 为功能型插件未同步，走下面的等价安装流程；LINK 为新建的 Claude 入口
2. **内容甄别**：逐个速览本次 SYNC 的 skill 的 SKILL.md，内容明显依赖 Claude 专属机制或工作流、对 Codex 无意义的，在报告中指出并建议加入主脚本 `case "$skill_name"` 的排除名单（用户确认后固化），其余不展开

### SKIP-PLUGIN：为其他 agent 找等价安装

功能型插件的 hooks/commands/agents 搬不动，唯一途径是在其他 agent 侧装等价物。对本次出现的每个 SKIP-PLUGIN 插件：

1. **探测本地在装的 agent**：用 `command -v` 逐个检查 codex、cursor、gemini、opencode、pi 等常见 agent CLI，只为实际装了的找等价物
2. **查等价装法**：用 WebSearch 按「插件名 + agent 名」查该插件在各在装 agent 侧的官方/社区安装方式（不少插件仓库本身就带 `gemini-extension.json`、`opencode.json` 等多端配置，优先查插件源仓库）
3. **确认后安装**：把查到的安装命令列给用户，逐条确认后执行；查不到的简要说明该 agent 无对应物，不猜命令。已装过的（如上次运行已安装）跳过

### 验证

```bash
# 查看受管副本
ls ~/.agents/skills/ | head -20

# 抽查 marker 与内容
cat ~/.agents/skills/<name>/.synced-from-plugin

# Claude 入口断链数应为 0
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -print | wc -l
```

## Notes

- **功能型插件自动排除**：插件目录含 `hooks/`、`commands/`、`agents/`、`.mcp.json`、`mcp` 任一组件即视为功能型，其 skills 不进仓库（留在各端插件内原生生效），改走等价安装流程。白名单在主脚本 `case "$plugin_root"` 处维护，当前为空
- **Claude 专属内容排除**：纯 skills 插件中，内容仅适用于 Claude Code（依赖 Claude 专属机制或工作流）的 skill 不同步——与 Codex 插件依赖其内置能力同理。排除名单在主脚本 `case "$skill_name"` 处维护
- **孤儿清理**：每次同步完成后自动扫描所有 marker，源目录已不存在（上游插件升级时删除的 skill）或所属插件已卸载（`/plugin uninstall` 只改 installed_plugins.json、不删 cache 目录，以 manifest 的 installPath 判断）的副本会被清理；`--dry-run` 模式下仅报告不删除。cache 中已卸载插件和旧版本的残留目录会被跳过、不同步
- **升级链路**：Claude Code 升级插件 → 重跑本 skill → 副本刷新 → Codex 立即可用新版；`npx skills update` 刷新仓库 → Claude 入口是软链，自动生效
- **Claude 侧无感知**：Claude Code 继续读插件真身，正向同步不影响它
- **本 skill 自身**：本插件的两个 skill（skills-maintenance、sync-skills）是 Claude 专属工作流，列在主脚本 `case "$skill_name"` 排除名单里，同步不会触碰自身
