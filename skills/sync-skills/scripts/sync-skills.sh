#!/bin/bash
# 双向同步：
#   正向 Claude Code 插件 skills → ~/.agents/skills/（拷贝 + marker + 版本未变跳过 + 功能型排除 + 孤儿清理）
#   反向 ~/.agents/skills/ → ~/.claude/skills/（软链入口 + 去重 + 清断链）
# sync-skills skill 的底层实现，由该 skill 手动触发。
# 用法: sync-skills.sh [--force] [--dry-run] [list]
AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_PLUGINS="$HOME/.claude/plugins/cache"
MARKER_FILE=".synced-from-plugin"
STATE_FILE=".synced-plugin-state"
FORCE_SYNC=false
DRY_RUN=false
LIST_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_SYNC=true ;;
        --dry-run) DRY_RUN=true ;;
        list) LIST_ONLY=true ;;
    esac
done

mkdir -p "$AGENTS_SKILLS"

# /plugin uninstall 只从 installed_plugins.json 移除条目，不删 cache 目录；
# 故以 manifest 的 installPath 判断插件是否仍安装：cache 中已卸载插件的残留既不同步，受管副本也要清理。
manifest="$HOME/.claude/plugins/installed_plugins.json"
# installPath 与 (version, gitCommitSha) 成对提取（version 缺失记 unknown，sha 缺失记空），
# 供安装判断与同步跳过比对共用
installed_pv=$(python3 -c "
import json
try:
    d = json.load(open('$manifest'))
    for entries in d.get('plugins', {}).values():
        for e in entries:
            print(e.get('installPath', '') + '\t' + e.get('version', 'unknown') + '\t' + e.get('gitCommitSha', ''))
except Exception:
    pass" 2>/dev/null)
installed_paths=$(cut -f1 <<< "$installed_pv")

is_installed() { # $1: cache 下的路径；所属插件仍在安装列表 → 0
    # manifest 不可读（空列表）时保守视为已安装，退回目录存在性判断，避免误清全部受管副本
    [ -n "$installed_paths" ] || return 0
    local p
    while IFS= read -r p; do
        case "$1" in "$p"|"$p"/*) return 0 ;; esac
    done <<< "$installed_paths"
    return 1
}

state_of() { # $1: installPath → 插件指纹 "version|sha"；查不到记 "unknown|"
    local p v s
    while IFS=$'\t' read -r p v s; do
        [ "$p" = "$1" ] && { echo "$v|$s"; return; }
    done <<< "$installed_pv"
    echo "unknown|"
}

# list 模式：列出受管副本及来源
if [ "$LIST_ONLY" = "true" ]; then
    echo "=== 受插件同步管理的 skills ==="
    for d in "$AGENTS_SKILLS"/*/; do
        [ -f "$d$MARKER_FILE" ] && echo "  $(basename "$d") <- $(cat "$d$MARKER_FILE" | sed "s|$HOME|~|")"
    done
    exit 0
fi

# sort -V：同插件多版本目录时，最新版本最后处理、最终生效
# 只枚举已安装插件（manifest installPath）下的 skills，不扫整个 cache：
# 已卸载插件和旧版本的 cache 残留不进循环，既快又不会被误同步
while IFS= read -r p; do [ -n "$p" ] && find "$p" -name "SKILL.md" -path "*/skills/*" 2>/dev/null; done <<< "$installed_paths" | sort -V | while read -r skill_file; do
    skill_dir=$(dirname "$skill_file")
    rel=${skill_file#"$CLAUDE_PLUGINS"/}
    # 跳过多语言/镜像副本，只取插件主 skills 目录
    case "$rel" in
        docs/*|*/docs/*|*/.agents/*|*/.cursor/*|*/.claude/*) continue ;;
    esac
    # 自动排除功能型插件（含 hooks/commands/agents/MCP 组件）——其 skills
    # 与专属机制联动，单独同步意义有限，留在各端插件内原生生效。
    # 白名单例外：skills 独立可用、需要共享的功能型插件。
    plugin_root=$(echo "$rel" | cut -d/ -f1-2)
    plugin_ver_dir=$(echo "$rel" | cut -d/ -f1-3)
    case "$plugin_root" in
        # 白名单当前为空：所有功能型插件均不同步
        # 如需给某功能型插件破例，加一行 "<市场>/<插件>) ;;"
        *)
            is_functional=false
            for comp in hooks commands agents .mcp.json mcp; do
                [ -e "$CLAUDE_PLUGINS/$plugin_ver_dir/$comp" ] && is_functional=true
            done
            if [ "$is_functional" = "true" ]; then
                echo "SKIP-PLUGIN: $plugin_root （功能型插件，不同步）"
                continue
            fi
            ;;
    esac
    skill_name=$(basename "$skill_dir")
    case "$skill_name" in .*) continue ;; esac
    # 排除内容仅适用于 Claude Code 的 skill（依赖 Claude 专属机制或工作流）。
    # 前两个是本插件自身（Claude 专属工作流）；其余候选由 skill 同步后的甄别步骤发现、用户确认后加入。
    case "$skill_name" in
        skills-maintenance|sync-skills) continue ;;
    esac

    target_dir="$AGENTS_SKILLS/$skill_name"

    if [ -d "$target_dir" ] && [ ! -f "$target_dir/$MARKER_FILE" ] && [ "$FORCE_SYNC" != "true" ]; then
        echo "SKIP: $skill_name （手动管理，--force 可覆盖）"
        continue
    fi

    # 同步跳过判据：插件指纹 "version|gitCommitSha"，与副本记录完全一致才跳过。
    # 版本或 sha 任一变化 → 重拷；两者都缺（unknown|）→ 没有可用判据，每次重拷。
    # sha 是 git 内容指纹，补版本号的盲区：作者改内容忘 bump 版本时 sha 仍会变。
    plugin_state=$(state_of "$CLAUDE_PLUGINS/$plugin_ver_dir")
    if [ "$FORCE_SYNC" != "true" ] && [ "$plugin_state" != "unknown|" ] \
       && [ -f "$target_dir/$STATE_FILE" ] && [ "$(cat "$target_dir/$STATE_FILE")" = "$plugin_state" ]; then
        echo "UNCHANGED: $skill_name （${plugin_state%%|*} 未变）"
        continue
    fi

    if [ "$DRY_RUN" = "true" ]; then
        echo "WOULD SYNC: $skill_name <- ${skill_dir#$HOME/}"
        continue
    fi

    rm -rf "$target_dir"
    cp -r "$skill_dir" "$target_dir"
    echo "$skill_dir" > "$target_dir/$MARKER_FILE"
    echo "$plugin_state" > "$target_dir/$STATE_FILE"
    echo "SYNC: $skill_name"
done

# 清理孤儿副本：marker 指向的源目录已不存在（上游插件删除了该 skill），或所属插件已卸载（cache 残留但 manifest 已移除）
for d in "$AGENTS_SKILLS"/*/; do
    marker="$d$MARKER_FILE"
    [ -f "$marker" ] || continue
    src=$(cat "$marker")
    if [ ! -d "$src" ]; then
        reason="源已消失"
    elif ! is_installed "$src"; then
        reason="插件已卸载"
    else
        continue
    fi
    echo "CLEAN: $(basename "$d") （$reason: ${src#$HOME/}）"
    [ "$DRY_RUN" = "true" ] || rm -rf "$d"
done

# ---- 反向同步：agents 仓库 → Claude 入口（~/.claude/skills/ 软链） ----
CLAUDE_SKILLS="$HOME/.claude/skills"
mkdir -p "$CLAUDE_SKILLS"

# 去重：入口指向带 marker 的仓库副本 = Claude 已通过插件真身加载，双份，删
for l in "$CLAUDE_SKILLS"/*; do
    [ -L "$l" ] || continue
    t=$(readlink -f "$l")
    if [ -f "$t/$MARKER_FILE" ]; then
        echo "UNLINK: $(basename "$l") （插件已加载，去重）"
        [ "$DRY_RUN" = "true" ] || rm "$l"
    fi
done

# 清断链：仓库里被删掉的 skill 留下的死入口
find "$CLAUDE_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print | while read -r l; do
    echo "UNLINK: $(basename "$l") （断链）"
    [ "$DRY_RUN" = "true" ] || rm "$l"
done

# 补缺：仓库有、Claude 没有的 skill 建软链（marker 副本除外——插件真身已生效）
for d in "$AGENTS_SKILLS"/*/; do
    n=$(basename "$d")
    case "$n" in .*) continue ;; esac
    [ -f "$d/SKILL.md" ] || continue
    [ -f "$d/$MARKER_FILE" ] && continue
    [ -e "$CLAUDE_SKILLS/$n" ] && continue
    echo "LINK: $n"
    [ "$DRY_RUN" = "true" ] || ln -s "$AGENTS_SKILLS/$n" "$CLAUDE_SKILLS/$n"
done

if [ "$DRY_RUN" != "true" ]; then
    echo ""
    echo "=== 同步完成：插件 skills → $AGENTS_SKILLS；仓库入口 → $CLAUDE_SKILLS ==="
fi
