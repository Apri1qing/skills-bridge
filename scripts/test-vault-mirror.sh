#!/usr/bin/env bash
# Integration tests for vault-mirror.sh in an isolated scratch HOME.
# Covers: harvest, lock backfill, token three-way merge, pull semantics.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
VM="$HERE/../skills/sync-skills/scripts/vault-mirror.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }
assert_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (expected [$1], got [$2])"; fi
}

scratch() { # prints a fresh machine skeleton: gitconfig + agents + .agents
  local t
  t="$(mktemp -d)"
  printf '[user]\n\tname = test\n\temail = test@test\n' > "$t/.gitconfig"
  mkdir -p "$t/agents" "$t/.agents"
  printf '%s' "$t"
}

lockjson() { # <hash> [skill_name]
  local h="$1" n="${2:-skill-a}"
  printf '{"version":3,"skills":{"%s":{"source":"vercel-labs/skills","sourceUrl":"https://x.git","skillPath":"skills/%s/SKILL.md","skillFolderHash":"%s","installedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}},"dismissed":[],"lastSelectedAgents":[]}' "$n" "$n" "$h"
}

skill_body() { printf -- '---\nname: %s\ndescription: t\n---\nbody %s\n' "$1" "$2"; }

manifest_field() { # <vault> <skill> <field>
  python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['skills'][sys.argv[2]].get(sys.argv[3],''))" "$1/skills-lock.json" "$2" "$3"
}
lock_field() { # <home> <skill> <field>
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('skills',{}).get(sys.argv[2],{}).get(sys.argv[3],''))" "$1/.agents/.skill-lock.json" "$2" "$3"
}

fresh_pair() { # sets MA MB ORIGIN with a vault already pushed by A containing skill-a v1/h1
  MA="$(scratch)"
  MB="$(scratch)"
  local t
  for t in "$MA" "$MB"; do
    mkdir -p "$t/agents/skill-a"
    skill_body skill-a v1 > "$t/agents/skill-a/SKILL.md"
    lockjson h1 > "$t/.agents/.skill-lock.json"
  done
  git init -q --bare "$MA/origin.git"
  git -C "$MA/origin.git" symbolic-ref HEAD refs/heads/main
  HOME="$MA" bash "$VM" init "$MA/vault" --no-github --agents "$MA/agents" >/dev/null 2>&1
  git -C "$MA/vault" remote add origin "$MA/origin.git"
  HOME="$MA" bash "$VM" sync --commit >/dev/null 2>&1
  git clone -q "$MA/origin.git" "$MB/vault"
  HOME="$MB" bash "$VM" setup "$MB/vault" "$MB/agents" >/dev/null 2>&1
}

echo "== 1. harvest: npx / claude-plugin / local origins =="
T="$(scratch)"
mkdir -p "$T/agents/skill-n"
skill_body skill-n n > "$T/agents/skill-n/SKILL.md"
mkdir -p "$T/agents/skill-p"
skill_body skill-p p > "$T/agents/skill-p/SKILL.md"
echo "$T/.claude/plugins/cache/mk/plug/1.2.0/skills/skill-p" > "$T/agents/skill-p/.synced-from-plugin"
printf '1.2.0|sha-p' > "$T/agents/skill-p/.synced-plugin-state"
mkdir -p "$T/agents/skill-l"
skill_body skill-l l > "$T/agents/skill-l/SKILL.md"
lockjson hn skill-n > "$T/.agents/.skill-lock.json"
HOME="$T" bash "$VM" init "$T/vault" --no-github --agents "$T/agents" >/dev/null 2>&1
HOME="$T" bash "$VM" sync >/dev/null 2>&1
assert_eq "npx" "$(manifest_field "$T/vault" skill-n origin)" "npx origin recorded"
assert_eq "hn" "$(manifest_field "$T/vault" skill-n skillFolderHash)" "npx hash carried"
assert_eq "claude-plugin" "$(manifest_field "$T/vault" skill-p origin)" "plugin origin recorded"
assert_eq "plug@mk" "$(manifest_field "$T/vault" skill-p plugin)" "plugin id parsed"
assert_eq "1.2.0" "$(manifest_field "$T/vault" skill-p pluginVersion)" "plugin version parsed"
assert_eq "local" "$(manifest_field "$T/vault" skill-l origin)" "local origin recorded"
[ -e "$T/vault/skills/skill-p/.synced-from-plugin" ] && fail "markers leaked into vault" || ok "markers stay local"
rm -rf "$T"

echo "== 2. lock backfill: vault-sourced skill becomes npx-visible; local fields survive =="
fresh_pair
rm "$MB/.agents/.skill-lock.json"
HOME="$MB" bash "$VM" pull >/dev/null 2>&1
assert_eq "h1" "$(lock_field "$MB" skill-a skillFolderHash)" "B lock backfilled from vault manifest"
rm -rf "$MA" "$MB"

fresh_pair
python3 - "$MB/.agents/.skill-lock.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d['skills']['own-skill'] = {'source': 'o/r', 'skillFolderHash': 'hown'}
d['dismissed'] = ['keepme']
json.dump(d, open(p, 'w'), indent=2)
PY
HOME="$MB" bash "$VM" pull >/dev/null 2>&1
assert_eq "hown" "$(lock_field "$MB" own-skill skillFolderHash)" "existing entries untouched"
assert_eq "keepme" "$(python3 -c "import json;print(json.load(open('$MB/.agents/.skill-lock.json'))['dismissed'][0])")" "machine-local fields untouched"
rm -rf "$MA" "$MB"

echo "== 3. remote wins: stale machine must not clobber a newer vault =="
fresh_pair
skill_body skill-a vBsame > "$MB/agents/skill-a/SKILL.md"   # same-size edit: exercises --checksum
lockjson h2 > "$MB/.agents/.skill-lock.json"
HOME="$MB" bash "$VM" sync --commit >/dev/null 2>&1
OUT="$(HOME="$MA" bash "$VM" sync --commit 2>&1 || true)"
echo "$OUT" | grep -q "↧ skill-a" && ok "upload skipped for remote-newer skill" || fail "upload not skipped"
assert_eq "body vBsame" "$(grep body "$MA/vault/skills/skill-a/SKILL.md")" "vault keeps remote version"
assert_eq "body vBsame" "$(grep body "$MA/agents/skill-a/SKILL.md")" "stale machine receives new content"
assert_eq "h2" "$(lock_field "$MA" skill-a skillFolderHash)" "stale machine lock refreshed"
rm -rf "$MA" "$MB"

echo "== 4. both changed: CONFLICT reported, local wins, history keeps the loser =="
fresh_pair
skill_body skill-a vB > "$MB/agents/skill-a/SKILL.md"
lockjson hB > "$MB/.agents/.skill-lock.json"
HOME="$MB" bash "$VM" sync --commit >/dev/null 2>&1
skill_body skill-a vA > "$MA/agents/skill-a/SKILL.md"
lockjson hA > "$MA/.agents/.skill-lock.json"
OUT="$(HOME="$MA" bash "$VM" sync --commit 2>&1 || true)"
echo "$OUT" | grep -q "CONFLICT: skill-a" && ok "conflict reported" || fail "conflict not reported"
assert_eq "body vA" "$(grep body "$MA/vault/skills/skill-a/SKILL.md")" "local wins the vault"
assert_eq "body vB" "$(git -C "$MA/vault" show "HEAD~1:skills/skill-a/SKILL.md" | grep body)" "losing version in git history"
assert_eq "hA" "$(manifest_field "$MA/vault" skill-a skillFolderHash)" "manifest follows winner"
rm -rf "$MA" "$MB"

echo "== 5. pull never writes the vault =="
fresh_pair
skill_body skill-a v2 > "$MA/agents/skill-a/SKILL.md"
lockjson h2 > "$MA/.agents/.skill-lock.json"
HOME="$MA" bash "$VM" sync --commit >/dev/null 2>&1
HOME="$MB" bash "$VM" pull >/dev/null 2>&1
assert_eq "$(git -C "$MA/origin.git" rev-parse main)" "$(git -C "$MB/vault" rev-parse HEAD)" "HEAD fast-forwards to remote, no local commit created"
[ -z "$(git -C "$MB/vault" status --porcelain)" ] && ok "working tree clean after pull" || fail "pull dirtied the vault"
rm -rf "$MA" "$MB"

echo "== 6. new skill flows down to the other machine =="
fresh_pair
mkdir -p "$MA/agents/skill-new"
skill_body skill-new fresh > "$MA/agents/skill-new/SKILL.md"
HOME="$MA" bash "$VM" sync --commit >/dev/null 2>&1
HOME="$MB" bash "$VM" sync >/dev/null 2>&1
assert_eq "body fresh" "$(grep body "$MB/agents/skill-new/SKILL.md")" "new skill arrives on B"
assert_eq "local" "$(manifest_field "$MB/vault" skill-new origin)" "new skill manifest origin"
rm -rf "$MA" "$MB"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
