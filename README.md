# skills-bridge

For people who use Claude Code **and** other agents: one shared library of skills.

[English](README.md) | [中文](README.zh-CN.md)

## Optional: share skills across machines (and cloud boxes)

Treat every environment as a **peer**: your laptop, another PC, or a cloud box (e.g. Grok). They all talk to the **same private skills-vault**.

- Don’t need sharing? **Ignore vault.** Single-machine sync still works.
- First machine: **`/init-vault`** (create the private git repo).
- Any other machine/box: `git clone` the vault → **`/init-vault`** / `setup` and point the local skills dir at `~/.agents/skills` (laptop) or `/home/box/agent-data/workflows` (Grok box) → **`/sync-skills`**.
- New skills on any peer: land in that machine’s skills dir → sync → push to vault; other peers sync to pull.

No vault configured → sync skips it quietly. **Grok Bot’s cloud box is supported the same way** — treat it as another machine whose local skills folder is `workflows/` (not a separate pipe).

After `/init-vault` the repo may be empty: run **`/sync-skills` once** to copy this machine’s skills into the vault and push.
After `/init-vault`, the agent should ask whether to run `/sync-skills` **right away** to fill the vault (don’t leave you on an empty repo).

## What it does

- **Claude**: copy pure plugin skills into `~/.agents/skills`; symlink repo skills into `~/.claude/skills`
- **Codex**: **migrate** pure skills from `~/.codex/skills` into agents and delete the `.codex` copy (no duplicate slash entries); keep `.system` / host-bound; remove `.codex → .claude` bypass symlinks
- Host-bound skills (hooks / MCP / built-in tools) stay out of the shared repo

## Why you need it

Each tool installs skills **in a different place**, and each only reads its own directory:

- Claude Code plugins land under `~/.claude/`
- Skills installed for Codex & friends (`npx skills add`) land under `~/.agents/`

So a plugin you install in Claude Code is invisible to Codex, and vice versa — one library per tool, install twice, maintain twice.

Worse, **not every plugin can be shared by moving files**: functional plugins (with hooks/MCP/commands/agents) bind their power to the host's machinery — copy the skill files elsewhere and they're dead weight. The only way to use them in another agent is to install the equivalent on that side, and until now, finding whether one exists and how to install it was all on you.

skills-bridge handles both: what can move goes into **the same warehouse** every tool reads (`~/.agents/skills/` — the standard directory Codex, Cursor, and the agentskills ecosystem natively scan); what can't, it detects which agents you have installed, searches the web for each one's equivalent install method, and installs it after your confirmation. It ships 3 skills:

| Skill | Job |
|---|---|
| `/sync-skills` | Keep Claude / Codex / the shared folder in sync (and your other machines if you set up vault) |
| `/skills-maintenance` | Update everything, then sync |
| `/init-vault` | One-time: set up sharing skills across your computers (optional) |

## Install

Not Claude-only. The repo is a standard skills package (`init-vault`, `sync-skills`, `skills-maintenance`).

### Any agent — `npx skills` (recommended)

```bash
# list
npx skills add Apri1qing/skills-bridge -l

# install all three into ~/.agents/skills/
npx skills add Apri1qing/skills-bridge -g --all

# or pick skills
npx skills add Apri1qing/skills-bridge -g -s init-vault -s sync-skills -s skills-maintenance -y
```

Works for Codex, Cursor, Grok, and anything else that reads `~/.agents/skills` (or your agent’s skills root). If you also use Claude Code, run `/sync-skills` once afterward to refresh symlinks.

### Claude Code plugin (optional)

```
/plugin marketplace add Apri1qing/skills-bridge
/plugin install skills-bridge@skills-bridge
```

## `/sync-skills` — two-way sync

Run it after installing, updating, or uninstalling a Claude Code plugin, or after `npx skills add`. One command, both directions:

**Forward (Claude plugins → warehouse).** Skills from pure-skills plugins are copied into the warehouse, immediately usable by Codex and friends. Each copy carries a `.synced-from-plugin` marker recording its source — only marker-holders may be overwritten or cleaned; anything you placed by hand is never touched. Copies of uninstalled plugins are cleaned up.

**Reverse (warehouse → Claude).** Skills that entered the warehouse without going through Claude Code — installed by `npx skills add`, written by hand — get a symlink entry in `~/.claude/skills/`, so Claude Code can use them immediately. Duplicate and dead entries are removed.

**Functional plugins (with hooks/MCP/commands/agents) don't cross.** Their skills are dead weight outside the host, so the script skips them — and the model picks up where the script stops: it detects which other agents you actually have installed (Codex, Gemini, …), searches the web for each one's equivalent install method, and installs it after your confirmation. It also flags synced skills whose content only makes sense inside Claude Code, suggesting them for the exclusion list.

Typical case: `frontend-slides` goes 1.0 → 2.1. Claude Code reads the plugin directory and uses the new version immediately, but Codex reads the *copy* in the warehouse, which doesn't change by itself — run `/sync-skills` and every copy is refreshed.

Just ask in natural language: want a preview of what it would do, or only a list of which skills are managed copies — say so, and the model picks the right way to run it.

## `/skills-maintenance` — update everything

Call it whenever you want everything current. Three steps in order:

1. Update the skills you installed with `npx skills add`
2. Update your Claude Code plugins
3. Run `/sync-skills` for the two-way sync

Then it hands you one summary table of what each step did.

## How it works

Three directories, and **the center is the warehouse — not any single tool**:

```mermaid
flowchart TB
    P["① Claude Code plugins"]
    N["npx skills add"]
    H["Placed by hand"]
    CX["Codex pure skills"]
    W["② 💻 This machine<br/>~/.agents/skills"]
    C["③ Claude entry<br/>~/.claude/skills"]
    V["④ ☁️ skills-vault<br/>private git mirror"]
    M1["💻 Computer A"]
    M2["💻 Computer B"]
    IV["/init-vault"]
    P --> W
    N --> W
    H --> W
    CX --> W
    W -->|"symlink"| C
    C --> CC["Claude Code"]
    W -->|"read directly"| X["Codex / Cursor / …"]
    W <-.->|"when configured: /sync-skills"| V
    M1 <-.->|"pull / push"| V
    M2 <-.->|"pull / push"| V
    IV -.->|"creates / registers"| V
```

Understand this diagram and the rules are all inside it:

- **A skill enters ② by one of three roads**: copied from ① (forward sync); installed straight into ② by `npx skills add`; or placed there by you. **This is the channel that lets skills from the Codex/Cursor ecosystem reach Claude**: once it's in ②, Claude can use it
- **Two directions, two mechanisms**: ① → ② uses **copies** (plugin version directories move on upgrade, which breaks links; a copy is always complete and usable); ② → ③ uses **symlinks** (the warehouse path never changes, the link is safe, and it follows whatever the warehouse holds — `npx skills update` refreshes content and Claude gets the new version with zero action)
- **The marker** = the copy's ID card: it's what forward sync uses to know what it may overwrite, and what reverse sync uses to skip entries Claude already loads through the plugin itself
- **④ is optional**: only if you ran `/init-vault`. Then sync keeps your machines’ skill folders aligned via that private git repo. Never set up? The diagram’s ④ simply doesn’t apply.
- **Functional plugins don't cross** (directory contains `hooks/`, `commands/`, `agents/`, `.mcp.json`): same rule for Claude plugins and Codex plugins alike — the way across is installing the equivalent on the other side, which `/sync-skills` helps you find and do

## Self-consistent by design

skills-bridge is itself a pure-skills plugin, so its own skills sync into the warehouse like everything else — any agent can trigger the sync, while Claude Code keeps reading the plugin original, and neither side interferes with the other. It applies the same rules to itself as to everyone else.

## License

MIT

