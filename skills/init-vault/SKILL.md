---
name: init-vault
description: >-
  Use when the user wants the same skills across machines (another laptop or a
  cloud box like Grok): create or register a private skills-vault, or re-run
  setup. Every machine is a peer — same sync, only the local skills directory
  path may differ. Do not use during ordinary sync.
---

# init-vault

把**任意一台机器**（新电脑、云端 box）接到同一个私有 skills-vault。模型：大家都是对等节点，不是「本机一套、Grok 另推」。

## 每台机器要有的两样东西

1. 本机 skill 目录（落点）  
   - 普通电脑：`~/.agents/skills`  
   - Grok / box：`/home/box/agent-data/workflows`（或你指定的等价目录）
2. 同一个 git vault 的 clone + `vault-mirror.sh setup <vault> [落点]`

## 找到脚本

```bash
find "$HOME/.claude/plugins" -path '*skills-bridge*/vault-mirror.sh' 2>/dev/null | head -1
```

源码安装时也可能在 clone 的 `skills-bridge/skills/sync-skills/scripts/vault-mirror.sh`。记为 `VM`。

## 从零（还没有 GitHub 仓）

在**一台**机器上：

```bash
bash "$VM" init ~/skills-vault --repo OWNER/skills-vault   # 或 --no-github
```

## 新电脑或 box（远端仓已有）

```bash
git clone https://github.com/OWNER/skills-vault.git ~/skills-vault   # box 上路径自定
# 普通电脑：
bash "$VM" setup ~/skills-vault ~/.agents/skills
# Grok box：
bash "$VM" setup ~/skills-vault /home/box/agent-data/workflows
```

然后跑 skills-bridge 的 **`/sync-skills`**（或直接 `bash …/sync-skills.sh`）：pull → 与本机落点合并 → push。  
之后任何节点上新装的 skill，进落点再 sync，就会进 vault；其他节点再 sync 即可更新。

## 不要做

- 不要为 Grok 单独发明第二条旁路命令
- 不要在普通 sync 里自动 init
- box 若暂时不能 `gh`/clone 私库，用已有 vault 打包拷到 box 再 `setup`，效果相同

## 下一步（必做）

`/init-vault` **只建空架子**。要把本机已有 skill 灌进 vault：

1. 跑 **`/sync-skills`**（不要加 `--skip-vault`）
2. 它会把本机落点（电脑：`~/.agents/skills`；Grok box：`workflows/`）镜像进 vault，并 commit/push

以后本机新装 skill，再跑同一次 `/sync-skills` 即可让其他节点（含 Grok）pull 到。
