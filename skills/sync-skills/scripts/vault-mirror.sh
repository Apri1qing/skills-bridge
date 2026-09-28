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
  vault-mirror.sh pull                    # fetch only: vault → agents, never writes the vault
  vault-mirror.sh push-dir [target_dir]   # optional: copy vault skills/ to any directory
  vault-mirror.sh status

init: create a content-only skills-vault (skills/ + exclude.txt + README + git).
      With gh auth, optionally create/push a private GitHub repo (--repo owner/name).
setup: point at an existing vault (must already have origin).
Config: $XDG_CONFIG_HOME/skills-bridge/vault.conf
Env: SKILLS_VAULT, AGENTS_SKILLS, EXTRA_TARGET_DIR
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
  EXTRA_TARGET_DIR="${EXTRA_TARGET_DIR:-}"
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
  # env wins when set
  [ -n "${SKILLS_VAULT:-}" ] && VAULT_PATH="$SKILLS_VAULT"
  [ -n "${AGENTS_SKILLS:-}" ] && AGENTS_PATH="$AGENTS_SKILLS"

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

# Vault-side skill provenance manifest + the npx skills CLI's machine-local lock.
# Marker/state file names must match sync-skills.sh.
LOCK_NAME="skills-lock.json"
PLUGIN_MARKER=".synced-from-plugin"
PLUGIN_STATE=".synced-plugin-state"

npx_lock_file() {
  printf '%s/.agents/.skill-lock.json' "$HOME"
}

# Rewrite the vault manifest from the skills copied agents→vault this run.
# $1 = copied skill names (file, one per line)
# $2 = plugin provenance TSV (name <TAB> plugin <TAB> version <TAB> sha)
manifest_harvest() {
  command -v python3 >/dev/null 2>&1 || { echo "manifest: python3 not found, $LOCK_NAME not updated"; return 0; }
  python3 - "$VAULT_PATH/$LOCK_NAME" "$(npx_lock_file)" "$1" "$2" "$SKILLS_DIR" <<'PY'
import json, os, sys

manifest_p, lock_p, synced_p, plugin_p, skills_dir = sys.argv[1:6]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

def lines(path):
    try:
        with open(path) as f:
            return [l.rstrip('\n') for l in f if l.strip()]
    except Exception:
        return []

old = load(manifest_p).get('skills', {})
lock = load(lock_p).get('skills', {})
synced = lines(synced_p)
plugins = {}
for line in lines(plugin_p):
    parts = line.split('\t')
    if len(parts) == 4:
        plugins[parts[0]] = parts[1:4]

on_disk = set(os.listdir(skills_dir)) if os.path.isdir(skills_dir) else set()

skills = {}
for name in sorted(set(list(old.keys()) + synced)):
    if name not in on_disk:
        continue  # pruned: skill dir no longer in the vault
    if name not in synced:
        skills[name] = old[name]
        continue
    if name in lock:
        entry = dict(lock[name])
        entry['origin'] = 'npx'
    elif name in plugins:
        plugin, ver, sha = plugins[name]
        entry = {'origin': 'claude-plugin', 'plugin': plugin,
                 'pluginVersion': ver, 'gitCommitSha': sha}
    else:
        prior = old.get(name)
        if prior and prior.get('origin') in ('npx', 'claude-plugin'):
            entry = prior  # this machine holds no token (e.g. a box): keep provenance
        else:
            entry = {'origin': 'local'}
    skills[name] = entry

doc = {'version': 1, 'skills': skills}
out = json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + '\n'
try:
    with open(manifest_p) as f:
        current = f.read()
except Exception:
    current = None
if current != out:
    with open(manifest_p, 'w') as f:
        f.write(out)
    print('manifest: %d entries (%d harvested this run)' % (len(skills), len(synced)))
else:
    print('manifest: up to date (%d entries)' % len(skills))
PY
}

# Merge npx-origin manifest entries into the machine-local skills lock so
# `npx skills update/list/remove` recognises every skill, vault-sourced included.
# $1 = names whose local entry must adopt the vault entry (refresh list)
lock_backfill() {
  command -v python3 >/dev/null 2>&1 || { echo "manifest: python3 not found, .skill-lock.json not updated"; return 0; }
  mkdir -p "$(dirname "$(npx_lock_file)")"
  python3 - "$VAULT_PATH/$LOCK_NAME" "$(npx_lock_file)" "$1" <<'PY'
import json, sys

manifest_p, lock_p, refresh_p = sys.argv[1:4]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

entries = load(manifest_p).get('skills', {})
doc = load(lock_p)
if not doc:
    doc = {'version': 3}  # matches the npx skills CLI lock this backfill feeds into
skills = doc.setdefault('skills', {})
if not isinstance(skills, dict):
    print('lock: unfamiliar .skill-lock.json shape, left untouched')
    sys.exit(0)
try:
    with open(refresh_p) as f:
        refresh = set(l.rstrip('\n') for l in f if l.strip())
except Exception:
    refresh = set()

added = updated = 0
for name, entry in sorted(entries.items()):
    if entry.get('origin') != 'npx':
        continue
    fields = {k: v for k, v in entry.items() if k != 'origin'}
    if name not in skills:
        skills[name] = fields
        added += 1
    elif name in refresh and skills[name] != fields:
        skills[name] = fields
        updated += 1

if added or updated:
    with open(lock_p, 'w') as f:
        json.dump(doc, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print('lock: %d added, %d refreshed' % (added, updated))
PY
}

rsync_to() {
  local from="$1" to="$2" delete_flag="${3:-}"
  mkdir -p "$to"
  # --checksum: decide by content, not size+mtime — same-size edits inside the
  # same second as a git checkout would otherwise be skipped as "unchanged".
  local args=(-a --checksum "${RSYNC_FILE_EXCLUDES[@]}")
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






vault_state() {
  # prints: configured | missing
  if [ -n "${SKILLS_VAULT:-}" ] && [ -d "${SKILLS_VAULT}/skills" ]; then
    echo configured
    return
  fi
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    if [ -n "${VAULT_PATH:-}" ] && [ -d "${VAULT_PATH}/skills" ]; then
      echo configured
      return
    fi
  fi
  echo missing
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
  if [ -f "$VAULT_PATH/$LOCK_NAME" ] && command -v python3 >/dev/null 2>&1; then
    python3 -c "
import collections, json
c = collections.Counter(e.get('origin', 'local') for e in json.load(open('$VAULT_PATH/$LOCK_NAME')).get('skills', {}).values())
print('manifest:      %d entries (npx %d / claude-plugin %d / local %d)' % (sum(c.values()), c['npx'], c['claude-plugin'], c['local']))" 2>/dev/null || echo "manifest:      unreadable"
  else
    echo "manifest:      none"
  fi
  echo "exclude ids:   ${#EXCLUDE_IDS[@]}"
}

# Decide which npx-origin skills the vault has advanced beyond this machine.
# Base = the vault manifest as this machine last saw it (pre-pull snapshot);
# tokens are the lock identity (sourceUrl|skillPath|skillFolderHash).
#   local==base && remote!=base → remote wins (skip upload, refresh local lock entry)
#   local!=base && remote!=base → both moved: local wins, report as conflict
# claude-plugin skills are plugin-authoritative (refresh via plugin update)
# and local-origin skills are last-syncer-wins by contract — both always upload.
# $1 base manifest file, $2 remote-win list out, $3 conflict list out
manifest_merge_plan() {
  : > "$2"
  : > "$3"
  command -v python3 >/dev/null 2>&1 || return 0
  [ -f "$VAULT_PATH/$LOCK_NAME" ] || return 0
  python3 - "$VAULT_PATH/$LOCK_NAME" "$1" "$(npx_lock_file)" "$2" "$3" <<'PY'
import json, sys

vault_p, base_p, lock_p, win_p, conflict_p = sys.argv[1:6]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

def tok(entry):
    return '%s|%s|%s' % (entry.get('sourceUrl', ''), entry.get('skillPath', ''),
                         entry.get('skillFolderHash', ''))

vault = load(vault_p).get('skills', {})
base = load(base_p).get('skills', {})
lock = load(lock_p).get('skills', {})

win, conflict = [], []
for name, remote in vault.items():
    if remote.get('origin') != 'npx':
        continue
    b, l = base.get(name), lock.get(name)
    if not b or not l:
        continue
    bt, lt, rt = tok(b), tok(l), tok(remote)
    if lt == bt and rt != bt:
        win.append(name)
    elif lt != bt and rt != bt:
        conflict.append(name)

for path, names in ((win_p, win), (conflict_p, conflict)):
    with open(path, 'w') as f:
        f.write('\n'.join(names) + ('\n' if names else ''))
PY
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

  local name dir st ver sha pid rel mk pn m
  local tmp base_manifest synced_names plugin_tsv refresh_list
  tmp="$(mktemp -d)"
  base_manifest="$tmp/base"
  synced_names="$tmp/synced"
  plugin_tsv="$tmp/plugins"
  refresh_list="$tmp/refresh"
  : > "$synced_names"
  : > "$plugin_tsv"
  : > "$refresh_list"
  if [ -f "$VAULT_PATH/$LOCK_NAME" ]; then
    cp "$VAULT_PATH/$LOCK_NAME" "$base_manifest"
  else
    : > "$base_manifest"
  fi

  echo "== git pull =="
  if ! git -C "$VAULT_PATH" pull --ff-only 2>/dev/null && ! git -C "$VAULT_PATH" pull --rebase 2>/dev/null; then
    echo "git pull skipped/failed (offline or no credentials) — continue with local vault"
  fi

  echo "== merge plan =="
  manifest_merge_plan "$base_manifest" "$refresh_list" "$tmp/conflict"
  if [ -s "$tmp/conflict" ]; then
    while IFS= read -r n; do
      echo "CONFLICT: $n （两边都变 — 本地优先，远端旧版在 git 历史）"
    done < "$tmp/conflict"
  fi

  mkdir -p "$SKILLS_DIR"
  echo "== agents → vault (add/update, no delete) =="
  for dir in "$AGENTS_PATH"/*; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    if is_excluded "$name"; then
      echo "exclude (skip upload): $name"
      continue
    fi
    has_skill_md "$dir" || { echo "skip (no SKILL.md): $name"; continue; }
    if grep -Fxq "$name" "$refresh_list"; then
      echo "↧ $name （远端较新 — 不上传，取远端）"
      continue
    fi
    mkdir -p "$SKILLS_DIR/$name"
    rsync_to "$dir" "$SKILLS_DIR/$name" ""
    echo "$name" >> "$synced_names"
    if [ -f "$dir/$PLUGIN_STATE" ]; then
      st="$(cat "$dir/$PLUGIN_STATE")"
      ver="${st%%|*}"
      sha="${st#*|}"
      pid=""
      if [ -f "$dir/$PLUGIN_MARKER" ]; then
        m="$(cat "$dir/$PLUGIN_MARKER")"
        rel="${m#"$HOME"/.claude/plugins/cache/}"
        mk="$(printf '%s' "$rel" | cut -d/ -f1)"
        pn="$(printf '%s' "$rel" | cut -d/ -f2)"
        if [ -n "$pn" ] && [ "$pn" != "$rel" ]; then pid="$pn@$mk"; fi
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$pid" "$ver" "$sha" >> "$plugin_tsv"
    fi
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

  echo "== manifest =="
  lock_backfill "$refresh_list"
  manifest_harvest "$synced_names" "$plugin_tsv"
  rm -rf "$tmp"

  if [ "$do_commit" -eq 1 ]; then
    echo "== commit/push =="
    git -C "$VAULT_PATH" add -A
    if git -C "$VAULT_PATH" diff --cached --quiet; then
      echo "no vault changes to commit"
    else
      git -C "$VAULT_PATH" commit -m "sync: mirror from $(hostname -s 2>/dev/null || echo host) $(date +%Y-%m-%d)"
      git -C "$VAULT_PATH" push -u origin HEAD
      echo "pushed"
    fi
  else
    echo "vault dirty check: $(git -C "$VAULT_PATH" status -sb)"
    echo "(pass --commit to commit+push)"
  fi
}

cmd_pull() {
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
  if ! git -C "$VAULT_PATH" pull --ff-only 2>/dev/null && ! git -C "$VAULT_PATH" pull --rebase 2>/dev/null; then
    echo "git pull skipped/failed (offline or no credentials) — continue with local vault"
  fi

  echo "== vault → agents (fetch only, vault untouched) =="
  local name dir
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

  echo "== manifest =="
  lock_backfill /dev/null
  echo "== pull done (no upload, no commit) =="
}

cmd_push_dir() {
  read_config
  load_excludes
  local dest="${1:-${EXTRA_TARGET_DIR:-}}"
  if [ -z "$dest" ]; then
    echo "usage: $0 push-dir <target_dir>" >&2
    exit 2
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
  pull) cmd_pull ;;
  push-dir) shift; cmd_push_dir "${1:-}" ;;
  status) cmd_status ;;
  state) vault_state ;;
  *) usage ;;
esac
