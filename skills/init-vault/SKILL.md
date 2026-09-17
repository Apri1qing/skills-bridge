---
name: init-vault
description: >-
  Use when the user wants to create or register a skills-vault (multi-machine
  skill mirror): first-time init, point at an existing git vault, or re-run
  setup. Do NOT use during ordinary /sync-skills — vault is optional.
---

# init-vault

只有用户**主动**要多机 skill 镜像时才用。日常 `/sync-skills` 发现没有 vault 会静默跳过，不会问。

## 脚本位置

与 `sync-skills` 同插件：

```bash
VM="<skills-bridge>/skills/sync-skills/scripts/vault-mirror.sh"
# 若从本机仓库：
VM="$HOME/Documents/personal/skills-bridge/skills/sync-skills/scripts/vault-mirror.sh"
```

也可在已安装插件 cache 里找 `skills-bridge/**/vault-mirror.sh`。

## Workflow

1. 问清（仅本 skill 内询问）：
   - 本地路径（默认 `~/skills-vault`）
   - 是否创建 GitHub **私有**库（要：`owner/name`；不要：`--no-github`）
   - 已有仓只登记：走 `setup`，不要 `init`
2. 执行其一：

```bash
# 从零
bash "$VM" init ~/skills-vault
bash "$VM" init ~/skills-vault --repo you/skills-vault
bash "$VM" init ~/skills-vault --no-github

# 已有 git vault
bash "$VM" setup /path/to/skills-vault
```

3. `bash "$VM" status` 确认 `configured`，`skills/` 与 `exclude.txt` 存在。
4. 告诉用户：以后 `/sync-skills` 会自动 pull/镜像；内容仓不要塞命令脚本。

## 不要做

- 不要在普通同步流程里自动 init
- 不要把密钥写进 vault
- 用户没提 vault 时不要推荐本 skill
