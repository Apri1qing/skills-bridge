---
name: init-vault
description: >-
  Use when the user wants the same skills across machines (another laptop or a
  cloud box like Grok): create or register a private skills-vault, then help
  them fill it. After setup succeeds, always offer to run /sync-skills now.
  Do not use during ordinary sync alone.
---

# init-vault

把**任意一台机器**（新电脑、Grok 云端 box）接到同一个私有 skills-vault，并完成**首次灌仓**引导。

## Onboarding（必须按序做完）

### 1. 接好 vault

找到脚本：

```bash
find "$HOME/.claude/plugins" -path '*skills-bridge*/vault-mirror.sh' 2>/dev/null | head -1
```

源码安装也可能在 `skills-bridge/skills/sync-skills/scripts/vault-mirror.sh`。记为 `VM`。

本机 skill 落点：

- 普通电脑：`~/.agents/skills`
- Grok / box：`/home/box/agent-data/workflows`

执行其一：

```bash
# 从零建仓
bash "$VM" init ~/skills-vault
bash "$VM" init ~/skills-vault --repo OWNER/skills-vault
bash "$VM" init ~/skills-vault --no-github

# 已有远端仓
git clone <vault-url> ~/skills-vault
bash "$VM" setup ~/skills-vault ~/.agents/skills          # 电脑
bash "$VM" setup ~/skills-vault /home/box/agent-data/workflows  # Grok box
```

`bash "$VM" status` 确认已配置。

### 2. 立刻引导灌仓（不要停在空仓）

`init` / `setup` **成功后必须马上问用户**（不要只丢一句「以后再 sync」）：

> vault 已经接好，但里面可能还是空的。要不要现在跑 `/sync-skills`，把这台机器上的 skill 灌进 vault 并推到远端？

- **用户说要 / 好 / 可以**：马上执行姊妹 skill **`sync-skills`**（或 `bash <plugin>/skills/sync-skills/scripts/sync-skills.sh`，**不要**加 `--skip-vault`）。跑完后简短汇报：大概同步了多少 skill、是否 push 成功。
- **用户说先不要**：记下「已 setup、尚未首次 sync」，告诉他下次直接 `/sync-skills` 就能灌仓；**到此才可结束本 skill**。

### 3. 之后怎么用（一句话带过）

本机新装 skill → 再跑 `/sync-skills` → 进 vault；其他电脑 / Grok box 同样 setup 后 `/sync-skills` 即可 pull。

## 不要做

- 建仓成功后沉默结束（空仓 onboarding 失败）
- 不经询问就自动 sync（除非用户已明确说「建好并同步」）
- 为 Grok 单独发明旁路命令
- 把密钥写进 vault
