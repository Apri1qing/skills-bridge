---
name: init-vault
description: >-
  Use when the user wants the same skills on more than one computer: create or
  register a private skills-vault, or re-run setup. Do not use during ordinary
  sync — vault is optional and never required.
---

# init-vault

帮用户**一次性**配好多机共用的 skill 备份。用户没提多机/vault 时不要主动推荐。

## 找到脚本

在已安装的 **skills-bridge** 插件目录里找：

```bash
find "$HOME/.claude/plugins" -path '*skills-bridge*/vault-mirror.sh' 2>/dev/null | head -1
```

若用户从源码装过，也可能在其 clone 的 `skills-bridge/skills/sync-skills/scripts/vault-mirror.sh`。把路径记为 `VM`。

## 流程

1. 问清：本地目录（默认 `~/skills-vault`）；是否建 GitHub 私有库（要则 `owner/name`，不要则本地 git 即可）；若已有 git 仓则只登记。
2. 执行：

```bash
# 新建
bash "$VM" init ~/skills-vault
bash "$VM" init ~/skills-vault --repo OWNER/REPO
bash "$VM" init ~/skills-vault --no-github

# 已有仓只登记
bash "$VM" setup /path/to/skills-vault
```

3. `bash "$VM" status` 确认已配置。
4. 说明：之后日常用 `/sync-skills` 即可；vault 里只放 skill 内容，不要放密钥。

## 不要做

- 不要在普通 `/sync-skills` 流程里自动 init
- 不要写死某个人的本机路径
