#!/usr/bin/env bash
# Generic full-mirror between a git skills vault and a local agents skills dir.
# Owned by skills-bridge (commands live here). The vault repo is content-only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/skills-bridge"
CONFIG_FILE="$CONFIG_DIR/vault.conf"
CMD="${1:-}"

usage() {
  cat <<'USAGE' >&2
usage:
  vault-mirror.sh init [vault_path] [--repo owner/name] [--no-github] [--agents path]
  vault-mirror.sh setup <vault_path> [agents_path]
  vault-mirror.sh sync [--commit]
  vault-mirror.sh push-box [workflows_path]
  vault-mirror.sh status

init: create a content-only skills-vault (skills/ + exclude.txt + README + git).
      With gh auth, optionally create/push a private GitHub repo (--repo owner/name).
setup: point at an existing vault (must already have origin).
Config: $XDG_CONFIG_HOME/skills-bridge/vault.conf
Env: SKILLS_VAULT, AGENTS_SKILLS, BOX_WORKFLOWS
Vault layout: <vault>/skills/, <vault>/exclude.txt, README.md
USAGE
  exit 2
}

write_config() {
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG_FILE" <<CFG
# skills-bridge ↔ skills-vault mirror config
VAULT_PATH=$(printf '%q' "$1")
AGENTS_PATH=$(printf '%q' "$2")
CFG
}

read_config() {
  VAULT_PATH="${SKILLS_VAULT:-}"
  AGENTS_PATH="${AGENTS_SKILLS:-${HOME}/.agents/skills}"
  BOX_WORKFLOWS="${BOX_WORKFLOWS:-/home/box/agent-data/workflows}"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  # env wins when set
  [ -n "${SKILLS_VAULT:-}" ] && VAULT_PATH="$SKILLS_VAULT"
  [ -n "${AGENTS_SKILLS:-}" ] && AGENTS_PATH="$AGENTS_SKILLS"
  [ -n "${BOX_WORKFLOWS:-}" ] && BOX_WORKFLOWS="$BOX_WORKFLOWS"

  if [ -z "${VAULT_PATH:-}" ]; then
    echo "VAULT_PATH unset — run: $0 init [path]   # or: $0 setup <vault_path>" >&2
    exit 1
  fi
  SKILLS_DIR="$VAULT_PATH/skills"
  EXCLUDE_FILE="$VAULT_PATH/exclude.txt"
}

load_excludes() {
  EXCLUDE_IDS=()
  if [ -f "$EXCLUDE_FILE" ]; then
    while IFS= read -r id || [ -n "${id:-}" ]; do
      id="$(printf '%s' "$id" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$id" ] && continue
      case "$id" in \#*) continue ;; esac
      EXCLUDE_IDS+=("$id")
    done < "$EXCLUDE_FILE"
  fi
}

is_excluded() {
  local name="$1" e
  for e in "${EXCLUDE_IDS[@]+"${EXCLUDE_IDS[@]}"}"; do
    [ "$e" = "$name" ] && return 0
  done
  return 1
}

has_skill_md() {
  local d="$1"
  [ -f "$d/SKILL.md" ] || [ -f "$d/skill.md" ]
}

RSYNC_FILE_EXCLUDES=(
  --exclude '.git'
  --exclude '.env'
  --exclude '.env.*'
  --exclude '*.pem'
  --exclude '*.key'
  --exclude 'credentials*'
  --exclude '.synced-*'
)

rsync_to() {
  local from="$1" to="$2" delete_flag="${3:-}"
  mkdir -p "$to"
  local args=(-a "${RSYNC_FILE_EXCLUDES[@]}")
  if [ "$delete_flag" = "delete" ]; then
    args+=(--delete --exclude '.synced-*')
  fi
  if command -v rsync >/dev/null 2>&1; then
    rsync "${args[@]}" "$from/" "$to/"
  else
    if [ "$delete_flag" = "delete" ]; then
      find "$to" -mindepth 1 -maxdepth 1 ! -name '.synced-*' -exec rm -rf {} +
    fi
    cp -a "$from/." "$to/"
    rm -rf "$to/.git" 2>/dev/null || true
  fi
}


cmd_init() {
  local vault_arg=""
  local repo=""
  local no_github=0
  local agents="${AGENTS_SKILLS:-$HOME/.agents/skills}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo)
        shift
        repo="${1:-}"
        [ -n "$repo" ] || { echo "--repo needs owner/name" >&2; exit 1; }
        shift
        ;;
      --no-github)
        no_github=1
        shift
        ;;
      --agents)
        shift
        agents="${1:-}"
        [ -n "$agents" ] || { echo "--agents needs a path" >&2; exit 1; }
        shift
        ;;
      -*)
        echo "unknown flag: $1" >&2
        exit 1
        ;;
      *)
        if [ -z "$vault_arg" ]; then
          vault_arg="$1"
          shift
        else
          echo "unexpected arg: $1" >&2
          exit 1
        fi
        ;;
    esac
  done
  vault_arg="${vault_arg:-$HOME/skills-vault}"

  if [ -d "$vault_arg/.git" ]; then
    echo "already a git repo: $vault_arg — use setup instead, or pick another path" >&2
    exit 1
  fi
  if [ -e "$vault_arg" ] && [ ! -d "$vault_arg" ]; then
    echo "path exists and is not a directory: $vault_arg" >&2
    exit 1
  fi

  mkdir -p "$vault_arg/skills" "$agents"
  if [ ! -f "$vault_arg/exclude.txt" ]; then
    cat > "$vault_arg/exclude.txt" <<'EXC'
# Skill ids to skip from the multi-machine mirror (one per line).
EXC
  fi
  if [ ! -f "$vault_arg/README.md" ]; then
    cat > "$vault_arg/README.md" <<'README'
# skills-vault

Content-only private skill mirror for multiple machines.

| Path | Role |
|------|------|
| `skills/<id>/` | Skill bodies |
| `exclude.txt` | Skill ids excluded from mirroring |
| `README.md` | This file |

All commands live in **skills-bridge** (`vault-mirror.sh` / `/sync-skills`). Do not add ops scripts here.
README
  fi

  git -C "$vault_arg" init -b main
  # ignore local junk / secrets if someone drops them by mistake
  if [ ! -f "$vault_arg/.gitignore" ]; then
    cat > "$vault_arg/.gitignore" <<'GI'
.DS_Store
.env
.env.*
*.pem
*.key
credentials*
GI
  fi
  git -C "$vault_arg" add -A
  if ! git -C "$vault_arg" diff --cached --quiet; then
    git -C "$vault_arg" -c user.email="${GIT_AUTHOR_EMAIL:-skills-bridge@local}" \
      -c user.name="${GIT_AUTHOR_NAME:-skills-bridge}" \
      commit -m "init: content-only skills-vault layout"
  fi

  if [ "$no_github" -eq 0 ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      if [ -z "$repo" ]; then
        local gh_user
        gh_user="$(gh api user -q .login 2>/dev/null || true)"
        repo="${gh_user:+$gh_user/}skills-vault"
        repo="${repo#/}"
        if [ -z "$gh_user" ]; then
          repo="skills-vault"
        fi
      fi
      echo "creating private GitHub repo: $repo"
      if gh repo view "$repo" >/dev/null 2>&1; then
        echo "remote repo exists — adding origin"
        git -C "$vault_arg" remote remove origin 2>/dev/null || true
        git -C "$vault_arg" remote add origin "$(gh repo view "$repo" --json url -q .url).git" 2>/dev/null \
          || git -C "$vault_arg" remote add origin "https://github.com/${repo}.git"
      else
        gh repo create "$repo" --private --source="$vault_arg" --remote=origin --push
      fi
      if ! git -C "$vault_arg" remote get-url origin >/dev/null 2>&1; then
        git -C "$vault_arg" remote add origin "https://github.com/${repo}.git"
      fi
      git -C "$vault_arg" push -u origin HEAD || echo "push failed — fix remote then: git -C $vault_arg push -u origin HEAD"
    else
      echo "gh not available/authenticated — local git only. Add origin later, then: $0 setup \"$vault_arg\""
      write_config "$(cd "$vault_arg" && pwd)" "$agents"
      echo "wrote local config (no origin yet). Add a remote before sync --commit."
      echo "VAULT_PATH=$(cd "$vault_arg" && pwd)"
      return 0
    fi
  else
    echo "--no-github: local git only"
  fi

  # setup requires origin when we have one; if missing, still write config
  if git -C "$vault_arg" remote get-url origin >/dev/null 2>&1; then
    cmd_setup "$(cd "$vault_arg" && pwd)" "$agents"
  else
    write_config "$(cd "$vault_arg" && pwd)" "$agents"
    echo "config → $CONFIG_FILE (no origin)"
  fi
  echo "init done: $(cd "$vault_arg" && pwd)"
}

cmd_setup() {
  local vault_arg="${1:-}"
  local agents="${2:-${AGENTS_SKILLS:-$HOME/.agents/skills}}"
  if [ -z "$vault_arg" ]; then
    echo "setup requires <vault_path>" >&2
    exit 1
  fi
  vault_arg="$(cd "$vault_arg" && pwd)"
  if [ ! -d "$vault_arg/.git" ]; then
    echo "not a git repo: $vault_arg" >&2
    exit 1
  fi
  if ! git -C "$vault_arg" remote get-url origin >/dev/null 2>&1; then
    echo "no git remote 'origin' — add one before setup" >&2
    exit 1
  fi
  mkdir -p "$agents" "$vault_arg/skills"
  touch "$vault_arg/exclude.txt"
  write_config "$vault_arg" "$agents"
  echo "config → $CONFIG_FILE"
  echo "  VAULT_PATH=$vault_arg"
  echo "  AGENTS_PATH=$agents"
  echo "  origin=$(git -C "$vault_arg" remote get-url origin)"
}

cmd_status() {
  read_config
  load_excludes
  echo "vault:  $VAULT_PATH"
  echo "agents: $AGENTS_PATH"
  echo "config: $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo '(ok)' || echo '(missing)')"
  echo "origin: $(git -C "$VAULT_PATH" remote get-url origin 2>/dev/null || echo none)"
  echo "vault skills:  $(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  echo "agents skills: $(find "$AGENTS_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  echo "exclude ids:   ${#EXCLUDE_IDS[@]}"
}

cmd_sync() {
  local do_commit=0
  [ "${1:-}" = "--commit" ] && do_commit=1
  read_config
  load_excludes
  if [ ! -d "$AGENTS_PATH" ]; then
    echo "agents path missing: $AGENTS_PATH" >&2
    exit 1
  fi
  if [ ! -d "$VAULT_PATH/.git" ]; then
    echo "vault is not a git repo: $VAULT_PATH" >&2
    exit 1
  fi

  echo "== git pull =="
  git -C "$VAULT_PATH" pull --ff-only || git -C "$VAULT_PATH" pull --rebase

  mkdir -p "$SKILLS_DIR"
  echo "== agents → vault (add/update, no delete) =="
  local name dir
  for dir in "$AGENTS_PATH"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if is_excluded "$name"; then
      echo "exclude (skip upload): $name"
      continue
    fi
    has_skill_md "$dir" || { echo "skip (no SKILL.md): $name"; continue; }
    mkdir -p "$SKILLS_DIR/$name"
    rsync_to "$dir" "$SKILLS_DIR/$name" ""
    echo "↑ $name"
  done

  echo "== vault → agents (union) =="
  for dir in "$SKILLS_DIR"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if is_excluded "$name"; then
      echo "exclude (skip download): $name"
      continue
    fi
    has_skill_md "$dir" || { echo "skip (no SKILL.md): $name"; continue; }
    mkdir -p "$AGENTS_PATH/$name"
    rsync_to "$dir" "$AGENTS_PATH/$name" "delete"
    echo "↓ $name"
  done

  if [ "$do_commit" -eq 1 ]; then
    echo "== commit/push =="
    git -C "$VAULT_PATH" add -A
    if git -C "$VAULT_PATH" diff --cached --quiet; then
      echo "no vault changes to commit"
    else
      git -C "$VAULT_PATH" commit -m "sync: mirror from $(hostname -s 2>/dev/null || echo host) $(date +%Y-%m-%d)"
      git -C "$VAULT_PATH" push origin HEAD
      echo "pushed"
    fi
  else
    echo "vault dirty check: $(git -C "$VAULT_PATH" status -sb)"
    echo "(pass --commit to commit+push)"
  fi
}

cmd_push_box() {
  read_config
  load_excludes
  local dest="${1:-$BOX_WORKFLOWS}"
  if [ ! -d "$(dirname "$dest")" ] && [ ! -d "$dest" ]; then
    # soft check: parent may need mkdir
    :
  fi
  mkdir -p "$dest"
  echo "== vault → $dest =="
  local name dir
  for dir in "$SKILLS_DIR"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    is_excluded "$name" && { echo "exclude: $name"; continue; }
    has_skill_md "$dir" || continue
    mkdir -p "$dest/$name"
    rsync_to "$dir" "$dest/$name" "delete"
    echo "→ $name"
  done
}

case "$CMD" in
  init) shift; cmd_init "$@" ;;
  setup) shift; cmd_setup "$@" ;;
  sync) shift; cmd_sync "${1:-}" ;;
  push-box) shift; cmd_push_box "${1:-}" ;;
  status) cmd_status ;;
  *) usage ;;
esac
