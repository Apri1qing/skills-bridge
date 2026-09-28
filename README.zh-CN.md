# skills-bridge

给同时使用 Claude Code 和其他 agent 的人：你的 skills，所有工具共用一份。

[English](README.md) | [中文](README.zh-CN.md)

## Onboard——把这段贴给你的 agent

Claude Code、Codex、Grok Bot 都行：

```text
为我安装并配置 skills-bridge：
1. 通读整个 README（https://github.com/Apri1qing/skills-bridge，
   中文版 README.zh-CN.md），理解 skills-bridge 和 skills-vault 的关系。
2. 按你自己的环境安装 skills-bridge，并验证装好了。
3. 问我：要不要把这套 skill 库在多台机器间共享。
   要，就走 /init-vault 引导；不要就到此为止，无需任何配置。
```

## 它能做什么

各个工具把 skill 装在**不同的地方**，又各自只认自己的目录——Claude Code 装的插件 Codex 看不见，反过来也一样。skills-bridge 给它们一个公共库（`~/.agents/skills`，Codex、Cursor 和 agentskills 生态原生扫描的标准目录）：

- **Claude → 公共仓库**：插件里的纯 skill 复制进来，其他工具立刻能用
- **公共仓库 → Claude**：不经 Claude Code 进来的 skill 补上 `~/.claude/skills` 软链入口，Claude Code 立刻能用
- **Codex**：`~/.codex/skills` 里的纯 skill 迁进公共仓库，不留双份
- **手放的 skill**：`~/.claude/skills` 里的实体同样迁进公共仓库，原位换成软链，Claude Code 无感继续用
- **绑宿主的功能型插件**（hooks / MCP / 内置工具）没法靠搬文件共享——skills-bridge 探测你装了哪些其他 agent，联网查各家的等价装法，经你确认后装上

## 安装

### `npx skills`

```bash
npx skills add Apri1qing/skills-bridge -g
```

### Claude Code 插件

```
/plugin marketplace add Apri1qing/skills-bridge
/plugin install skills-bridge@skills-bridge
```

## 三个 skill

| Skill | 职责 |
|---|---|
| `/sync-skills` | 让 Claude / Codex / 公共目录对齐（若已配置 vault，也同步到其他电脑） |
| `/skills-maintenance` | 先更新一切，再同步 |
| `/init-vault` | 一次性：配置「多台电脑共用 skill」（可选） |

任何地方装了、更新了、卸载了 skill，跑一次 `/sync-skills`；想让一切保持最新，跑 `/skills-maintenance`。典型场景：插件从 1.0 升到 2.1——Claude Code 马上用新版，但其他工具读的是公共仓库里的*副本*，一次 `/sync-skills` 全部刷新。

## 给 agent 的话

用户把这段指给你看，就是想让你替他把 skills-bridge 配好。三步。

**1. 知道自己在装什么。** skills-bridge 让所有 agent 共用一个 skill 库（`~/.agents/skills`）：给某个 agent 装的 skill 其他 agent 也能用（`/sync-skills` 双向对齐）；`/skills-maintenance` 一键更新一切；可选的私有 git vault 让同一个库跟着用户跨机器走。

**2. 按自己的环境安装，并验证：**

| 你是 | 安装 | 验证 |
|---|---|---|
| Claude Code | `/plugin marketplace add Apri1qing/skills-bridge`，再 `/plugin install skills-bridge@skills-bridge` | `/sync-skills` 能跑 |
| Codex，或任何读 `~/.agents/skills` 的 agent | `npx skills add Apri1qing/skills-bridge -g` | `~/.agents/skills/sync-skills` 存在 |
| Grok Bot 云端 box | 下面这组命令 | `/home/box/agent-data/workflows` 下出现各 skill 目录 |

Grok Bot 的 box 没有插件系统、也不保证有 Node——安装就是纯 git + cp（只要求 bash 和 git）：

```bash
git clone https://github.com/Apri1qing/skills-bridge.git ~/skills-bridge
mkdir -p /home/box/agent-data/workflows
cp -r ~/skills-bridge/skills/* /home/box/agent-data/workflows/
```

之后升级用 `git -C ~/skills-bridge pull && cp -r ~/skills-bridge/skills/* /home/box/agent-data/workflows/`。box 上 `/skills-maintenance` 不适用（它的两个更新源都不存在），日常就是 `/sync-skills`，或 `vault-mirror.sh pull` 只拉不推。

**3. 问用户一个问题：「要把这套 skill 库在你的多台机器间共享吗？」**

- **要** → 走 `/init-vault` 引导：创建私有 vault（`bash <插件>/skills/sync-skills/scripts/vault-mirror.sh init ~/skills-vault --repo OWNER/skills-vault`），或 clone 用户已有的 vault 并登记本机 skill 落点（`bash <插件>/skills/sync-skills/scripts/vault-mirror.sh setup ~/skills-vault <skills目录>`，Grok box 是 `/home/box/agent-data/workflows`）。然后跑一次 `/sync-skills` 灌仓或拉取。
- **不要** → 到此为止。单机同步不依赖 vault，无需任何配置。

最后用一句话告诉用户日常用法：任何地方装了/更新了 skill 就跑 `/sync-skills`；要一键更新一切就跑 `/skills-maintenance`。

## 可选：多台机器共用同一套 skill

笔记本、另一台电脑、Grok 云端 box，都可以连到**同一个私有 skills-vault**（一个私有 git 仓）。

- **第一台机器**：跑 `/init-vault`，再跑一次 `/sync-skills` 灌仓并 push
- **其他机器 / Grok box**：`git clone` vault 仓库，跑 `/init-vault` 登记本机 skill 落点（电脑是 `~/.agents/skills`，Grok box 是 `/home/box/agent-data/workflows`），然后 `/sync-skills`
- **日常**：任何一台新装了 skill，在那台跑 `/sync-skills` 推上去，其他机器跑 `/sync-skills` 拉下来；纯消费的机器（比如只拉不推的 Grok box）可以跑 `vault-mirror.sh pull`

同步不会弄丢你的工作：陈旧的机器打不回较新的 vault，两边都变会报 CONFLICT、可从 vault 的 git 历史找回，vault 来的 skill 在每台机器上都能 `npx skills update`。

不需要多机共享？完全不用管 vault——没配置时同步会自动跳过它，单机照常。

## 许可

MIT
