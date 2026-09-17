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
  vault-mirror.sh setup <vault_path> [agents_path]
  vault-mirror.sh sync [--commit]
  vault-mirror.sh push-box [workflows_path]
  vault-mirror.sh status

Config: $XDG_CONFIG_HOME/skills-bridge/vault.conf (or ~/.config/...)
Env overrides: SKILLS_VAULT, AGENTS_SKILLS, BOX_WORKFLOWS
Vault data: <vault>/skills/, <vault>/exclude.txt
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
    echo "VAULT_PATH unset — run: $0 setup <vault_path>" >&2
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
  setup) shift; cmd_setup "$@" ;;
  sync) shift; cmd_sync "${1:-}" ;;
  push-box) shift; cmd_push_box "${1:-}" ;;
  status) cmd_status ;;
  *) usage ;;
esac
