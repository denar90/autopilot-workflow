# autopilot_sh

Resumable, agent-agnostic ralph-loop driver: takes a Linear ticket from worktree creation through merge as a sequence of single-shot agent subprocesses.

## Why

A single long-lived agent context bloats and degrades. Splitting into phases — research / plan / implement / review — with fresh subprocesses keeps each phase lean and lets you resume after any crash.

## Install

```bash
git clone <this-repo>
cd autopilot_sh
./install.sh   # symlinks bin/autopilot into ~/.local/bin
```

You need: bash 3.2+ (macOS default works), `jq`, `envsubst` (from `gettext`), `git` with worktree support, and a coding-agent CLI on PATH (default: Claude Code's `claude`). The agent must have a **Linear MCP server** installed and authenticated — ticket fetch goes through MCP, not direct API. For Claude Code, enable the `plugin:linear:linear` MCP (or equivalent).

## Usage

```bash
cd /path/to/your/repo
cp /path/to/autopilot_sh/.autopilotrc.example .autopilotrc
# edit .autopilotrc — set symlinks, setup, verify commands

# Default: interactive — pauses at plan TLDR and post-review checkpoint.
autopilot https://linear.app/<team>/issue/TEAM-123/some-slug

# Full autopilot: no human in the loop.
autopilot --full https://linear.app/<team>/issue/TEAM-123/some-slug
```

Re-run the same command to resume from the last completed phase.

## Modes

| Mode | Plan checkpoint | Review checkpoint |
| --- | --- | --- |
| `interactive` (default) | Shows TLDR. Type `go` to proceed, `changes <feedback>` to re-run the planner with your additions (loops until `go`), or `stop` to halt. | Shows summary. Type `merge` / `pr` / `preview` / `hold`. |
| `full` | Auto-approved. | Takes `AUTOPILOT_DEFAULT_ACTION` (default `pr`). |

Set via `--full` / `--interactive` CLI flag (overrides `AUTOPILOT_MODE` env).

## Configuration

See `.autopilotrc.example`. Per-project config lives in `.autopilotrc` in each repo you want to drive.

| Var | Default | Purpose |
| --- | --- | --- |
| `AUTOPILOT_MODE` | `interactive` | `interactive` or `full` |
| `AUTOPILOT_DEFAULT_ACTION` | `pr` | In `full` mode: what to do after review (`merge`/`pr`/`preview`/`hold`) |
| `AUTOPILOT_WORKTREE_BASE` | `$HOME/wt` | Where worktrees live |
| `AUTOPILOT_AGENT_CMD` | `claude -p --output-format=stream-json --model $AUTOPILOT_MODEL` | Coding-agent CLI. Reads prompt on stdin. |
| `AUTOPILOT_MODEL` | `claude-opus-4-7` | Model passed to the agent |
| `AUTOPILOT_VERIFY_CMD` | `make check test` | Run at end of implement + after each fixer cycle |
| `AUTOPILOT_SETUP_CMD` | (none) | Run inside fresh worktree (e.g. `pnpm install`) |
| `AUTOPILOT_SYMLINKS` | (none) | Newline list of paths to symlink from source repo (`.env`, `.mcp.json`) |

## Using with non-Claude agents

Set `AUTOPILOT_AGENT_CMD` to any CLI that reads a prompt on stdin and exits non-zero on failure. Examples:

```bash
# Codex CLI
export AUTOPILOT_AGENT_CMD="codex -p"

# Aider
export AUTOPILOT_AGENT_CMD="aider --message-file /dev/stdin"
```

Whichever agent you choose, it must have a Linear MCP server installed and authenticated. The Linear-fetch prompt explicitly refuses to fall back to direct HTTP — single auth path, intentional.

## Phase order

```
worktree → research → plan → [checkpoint] → implement → review×3 → [checkpoint] → merge|pr|preview|hold
```

Each phase writes a marker to `<worktree>/.autopilot/state.json`. Re-running the entry script skips completed phases.

## Layout

```
bin/autopilot       Entry script
lib/                Sourced bash modules
prompts/            Per-phase prompt templates ({{VAR}} substitution)
templates/          Initial state.json, feedback.json, plan template
tests/              bats-core unit tests
```

## Development

```bash
make test    # bats tests
make lint    # shellcheck
```

## License

MIT
