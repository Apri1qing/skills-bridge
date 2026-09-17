#!/bin/bash
# 同步：
#   Claude 正向：在装插件纯 skills → ~/.agents/skills/（拷贝 + marker）
#   Codex 正向：~/.codex/skills 纯 skills → ~/.agents/skills/（拷贝后删除 .codex 实体，避免双份）
#   Claude 反向：~/.agents/skills/ → ~/.claude/skills/（软链入口）
# 用法: sync-skills.sh [--force] [--dry-run] [--skip-vault] [list]
# 默认：bridge 前后接 skills-vault（pull→整理→镜像回仓）；--skip-vault 关掉
AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_PLUGINS="$HOME/.claude/plugins/cache"
CODEX_SKILLS="$HOME/.codex/skills"
MARKER_FILE=".synced-from-plugin"
STATE_FILE=".synced-plugin-state"
CODEX_MARKER=".synced-from-codex"
CODEX_STATE=".synced-codex-state"
FORCE_SYNC=false
DRY_RUN=false
LIST_ONLY=false
SKIP_VAULT=false
for arg in "$@"; do
    case "$arg" in
        --force) FORCE_SYNC=true ;;
        --dry-run) DRY_RUN=true ;;
        --skip-vault) SKIP_VAULT=true ;;
        list) LIST_ONLY=true ;;
    esac
done

# Optional skills-vault mirror (multi-machine). Bridge stays the user-facing entry.
resolve_vault_sync() {
    if [ -n "${SKILLS_VAULT:-}" ] && [ -x "${SKILLS_VAULT}/scripts/sync.sh" ]; then
        echo "${SKILLS_VAULT}/scripts/sync.sh"
        return 0
    fi
    local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/skills-vault/config"
    if [ -f "$cfg" ]; then
        # shellcheck disable=SC1090
        source "$cfg"
        if [ -n "${VAULT_PATH:-}" ] && [ -x "${VAULT_PATH}/scripts/sync.sh" ]; then
            echo "${VAULT_PATH}/scripts/sync.sh"
            return 0
        fi
    fi
    local cand
    for cand in "$HOME/Documents/personal/skills-vault" "$HOME/Documents/personal/skills-vault"; do
        if [ -x "$cand/scripts/sync.sh" ]; then
            echo "$cand/scripts/sync.sh"
            return 0
        fi
    done
    return 1
}

vault_pre() {
    [ "$SKIP_VAULT" = "true" ] && return 0
    [ "$DRY_RUN" = "true" ] && return 0
    local vs
    if ! vs="$(resolve_vault_sync)"; then
        echo "VAULT: skip (no skills-vault — run vault sync.sh setup, or pass --skip-vault)"
        return 0
    fi
    echo "=== skills-vault pre (pull + merge into agents) ==="
    bash "$vs" sync || echo "VAULT: pre sync failed (continue bridge)"
}

vault_post() {
    [ "$SKIP_VAULT" = "true" ] && return 0
    [ "$DRY_RUN" = "true" ] && return 0
    local vs
    if ! vs="$(resolve_vault_sync)"; then
        return 0
    fi
    echo ""
    echo "=== skills-vault post (mirror agents → vault + commit/push) ==="
    bash "$vs" sync --commit || echo "VAULT: post sync/commit failed"
}

mkdir -p "$AGENTS_SKILLS"

manifest="$HOME/.claude/plugins/installed_plugins.json"
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

is_installed() {
    [ -n "$installed_paths" ] || return 0
    local p
    while IFS= read -r p; do
        case "$1" in "$p"|"$p"/*) return 0 ;; esac
    done <<< "$installed_paths"
    return 1
}

state_of() {
    local p v s
    while IFS=$'\t' read -r p v s; do
        [ "$p" = "$1" ] && { echo "$v|$s"; return; }
    done <<< "$installed_pv"
    echo "unknown|"
}

# 纯 skill 判定（Codex 用户目录）：无 hooks/commands/mcp；agents/ 至多只有 openai.yaml
is_codex_host_bound() {
    local d="$1"
    local comp
    for comp in hooks commands .mcp.json mcp; do
        [ -e "$d/$comp" ] && return 0
    done
    if [ -d "$d/agents" ]; then
        local extras
        extras=$(find "$d/agents" -mindepth 1 -maxdepth 1 ! -name 'openai.yaml' ! -name '.*' 2>/dev/null | head -1)
        [ -n "$extras" ] && return 0
    fi
    if [ -f "$d/SKILL.md" ] && grep -qE 'built-in `image_gen`|内置 `image_gen`|image_gen tool' "$d/SKILL.md" 2>/dev/null; then
        return 0
    fi
    return 1
}

codex_fingerprint() {
    local d="$1"
    if [ -f "$d/SKILL.md" ]; then
        local h names
        h=$(shasum -a 256 "$d/SKILL.md" 2>/dev/null | awk '{print $1}')
        names=$(find "$d" -maxdepth 1 -type f -exec basename {} \; 2>/dev/null | sort | tr '\n' ',')
        echo "$h|$names"
    else
        echo "missing|"
    fi
}

if [ "$LIST_ONLY" = "true" ]; then
    echo "=== 受插件同步管理的 skills ==="
    for d in "$AGENTS_SKILLS"/*/; do
        [ -f "$d$MARKER_FILE" ] && echo "  $(basename "$d") <- $(cat "$d$MARKER_FILE" | sed "s|$HOME|~|")"
    done
    echo "=== 受 Codex 迁入管理的 skills ==="
    for d in "$AGENTS_SKILLS"/*/; do
        [ -f "$d$CODEX_MARKER" ] && echo "  $(basename "$d") <- $(cat "$d$CODEX_MARKER" | sed "s|$HOME|~|")"
    done
    exit 0
fi

vault_pre

echo "=== Claude 插件 → agents ==="
while IFS= read -r p; do [ -n "$p" ] && find "$p" -name "SKILL.md" -path "*/skills/*" 2>/dev/null; done <<< "$installed_paths" | sort -V | while read -r skill_file; do
    skill_dir=$(dirname "$skill_file")
    rel=${skill_file#"$CLAUDE_PLUGINS"/}
    case "$rel" in
        docs/*|*/docs/*|*/.agents/*|*/.cursor/*|*/.claude/*) continue ;;
    esac
    plugin_root=$(echo "$rel" | cut -d/ -f1-2)
    plugin_ver_dir=$(echo "$rel" | cut -d/ -f1-3)
    is_functional=false
    for comp in hooks commands agents .mcp.json mcp; do
        [ -e "$CLAUDE_PLUGINS/$plugin_ver_dir/$comp" ] && is_functional=true
    done
    if [ "$is_functional" = "true" ]; then
        echo "SKIP-PLUGIN: $plugin_root （功能型插件，不同步）"
        continue
    fi
    skill_name=$(basename "$skill_dir")
    case "$skill_name" in .*) continue ;; esac

    target_dir="$AGENTS_SKILLS/$skill_name"

    if [ -d "$target_dir" ] && [ ! -f "$target_dir/$MARKER_FILE" ] && [ ! -f "$target_dir/$CODEX_MARKER" ] && [ "$FORCE_SYNC" != "true" ]; then
        echo "SKIP: $skill_name （手动管理，--force 可覆盖）"
        continue
    fi

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
    rm -f "$target_dir/$CODEX_MARKER" "$target_dir/$CODEX_STATE"
    echo "SYNC: $skill_name"
done

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

echo ""
echo "=== Codex skills → agents（迁走，不留 .codex 双份）==="
if [ -d "$CODEX_SKILLS" ]; then
    if [ -d "$CODEX_SKILLS/.system" ]; then
        echo "SKIP-CODEX-BOUND: .system/* （Codex 系统 skill，整目录保留）"
    fi
    for skill_dir in "$CODEX_SKILLS"/*/; do
        [ -e "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        case "$skill_name" in .*) continue ;; esac
        entry="${skill_dir%/}"

        if [ -L "$entry" ]; then
            resolved=$(readlink -f "$entry" 2>/dev/null || true)
            case "$resolved" in
                "$AGENTS_SKILLS"/*)
                    if [ "$DRY_RUN" = "true" ]; then
                        echo "WOULD REMOVE-CODEX-LINK: $skill_name （已指向 agents，防双份）"
                    else
                        rm "$entry"
                        echo "REMOVE-CODEX-LINK: $skill_name"
                    fi
                    continue
                    ;;
                "$HOME/.claude/skills"/*)
                    if [ "$DRY_RUN" = "true" ]; then
                        echo "WOULD REMOVE-BYPASS: $skill_name -> ~/.claude/skills （旁路软链）"
                    else
                        rm "$entry"
                        echo "REMOVE-BYPASS: $skill_name"
                    fi
                    continue
                    ;;
            esac
            echo "SKIP-CODEX-LINK: $skill_name -> $(readlink "$entry") （非 agents/claude 目标，不动）"
            continue
        fi

        [ -f "$skill_dir/SKILL.md" ] || { echo "SKIP-CODEX: $skill_name （无 SKILL.md）"; continue; }

        if is_codex_host_bound "$skill_dir"; then
            echo "SKIP-CODEX-BOUND: $skill_name （绑宿主，留在 .codex）"
            continue
        fi

        target_dir="$AGENTS_SKILLS/$skill_name"
        fp=$(codex_fingerprint "$skill_dir")

        if [ -d "$target_dir" ] && [ ! -f "$target_dir/$MARKER_FILE" ] && [ ! -f "$target_dir/$CODEX_MARKER" ] && [ "$FORCE_SYNC" != "true" ]; then
            echo "SKIP-CODEX: $skill_name （agents 手管，保留 .codex 源；--force 可覆盖）"
            continue
        fi

        if [ -f "$target_dir/$CODEX_STATE" ] && [ "$(cat "$target_dir/$CODEX_STATE")" = "$fp" ] && [ "$FORCE_SYNC" != "true" ]; then
            if [ -d "$skill_dir" ] && [ ! -L "$entry" ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    echo "WOULD REMOVE-CODEX: $skill_name （agents 已是最新，删 .codex 双份）"
                else
                    rm -rf "$skill_dir"
                    echo "REMOVE-CODEX: $skill_name （去双份）"
                fi
            else
                echo "UNCHANGED-CODEX: $skill_name"
            fi
            continue
        fi

        if [ -f "$target_dir/$MARKER_FILE" ] && [ "$FORCE_SYNC" != "true" ]; then
            if [ "$DRY_RUN" = "true" ]; then
                echo "WOULD DEDUP-CODEX: $skill_name （agents 已有插件副本，删除 .codex 实体）"
            else
                rm -rf "$skill_dir"
                echo "DEDUP-CODEX: $skill_name"
            fi
            continue
        fi

        if [ "$DRY_RUN" = "true" ]; then
            echo "WOULD MIGRATE-CODEX: $skill_name -> ~/.agents/skills/ （拷贝后删除 .codex 实体）"
            continue
        fi

        rm -rf "$target_dir"
        cp -R "$skill_dir" "$target_dir"
        echo "$HOME/.codex/skills/$skill_name" > "$target_dir/$CODEX_MARKER"
        echo "$fp" > "$target_dir/$CODEX_STATE"
        rm -f "$target_dir/$MARKER_FILE" "$target_dir/$STATE_FILE"
        rm -rf "$skill_dir"
        echo "MIGRATE-CODEX: $skill_name"
    done
else
    echo "SKIP: ~/.codex/skills 不存在"
fi

echo ""
echo "=== agents → Claude 软链入口 ==="
CLAUDE_SKILLS="$HOME/.claude/skills"
mkdir -p "$CLAUDE_SKILLS"

for l in "$CLAUDE_SKILLS"/*; do
    [ -L "$l" ] || continue
    t=$(readlink -f "$l")
    if [ -f "$t/$MARKER_FILE" ]; then
        echo "UNLINK: $(basename "$l") （插件已加载，去重）"
        [ "$DRY_RUN" = "true" ] || rm "$l"
    fi
done

find "$CLAUDE_SKILLS" -maxdepth 1 -type l ! -exec test -e {} \; -print 2>/dev/null | while read -r l; do
    echo "UNLINK: $(basename "$l") （断链）"
    [ "$DRY_RUN" = "true" ] || rm "$l"
done

for d in "$AGENTS_SKILLS"/*/; do
    n=$(basename "$d")
    case "$n" in .*) continue ;; esac
    [ -f "$d/SKILL.md" ] || continue
    [ -f "$d/$MARKER_FILE" ] && continue
    [ -e "$CLAUDE_SKILLS/$n" ] && continue
    echo "LINK: $n"
    [ "$DRY_RUN" = "true" ] || ln -s "$AGENTS_SKILLS/$n" "$CLAUDE_SKILLS/$n"
done

if [ "$DRY_RUN" = "true" ]; then
    echo ""
    echo "=== dry-run 结束（未改磁盘）==="
else
    vault_post
    echo ""
    echo "=== 同步完成：Claude 插件/Codex 纯 skill → $AGENTS_SKILLS；Claude 入口 → $CLAUDE_SKILLS（含 vault 镜像）==="
fi
