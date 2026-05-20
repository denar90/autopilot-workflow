# Autopilot Ralph-Loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a standalone, agent-agnostic bash project that drives a Linear ticket from worktree creation through merge as a sequence of resumable, single-shot agent subprocesses (ralph loop pattern). Source design: `/Users/artemdenysov/trayo/trayoai/docs/plans/2026-05-20-autopilot-ralph-loop-design.md`.

**Architecture:** Plain bash driver (`bin/autopilot`) walks a fixed phase order, persisting completion markers to `<worktree>/.autopilot/state.json`. Each phase shells out to a single coding-agent CLI invocation (default `claude -p`, configurable via `AUTOPILOT_AGENT_CMD`) with a phase-specific prompt template piped to stdin and full stdout streamed to a per-phase log. Resume = re-run the entry script; it skips any phase whose marker is already set. The review loop is decomposed into reviewer / adversary / fixer subprocesses sharing `feedback.json` as their only mutable state.

**Tech Stack:**
- Bash 5+ (works under macOS zsh shell since invocations are explicit `#!/usr/bin/env bash`)
- `jq` for JSON manipulation (state, feedback, ticket cache)
- `bats-core` for unit tests (`brew install bats-core`)
- `git` worktrees
- Any coding-agent CLI that accepts a prompt on stdin and exits non-zero on failure (defaults: Claude Code via `claude -p`)
- **Linear MCP server** configured on the agent (required — ticket fetch goes through MCP, not direct API)

---

## Repo Layout (target end state)

```
autopilot_sh/
├── bin/
│   └── autopilot                  # Entry script; sources lib/*.sh and runs phase loop
├── lib/
│   ├── agent.sh                   # run_phase wrapper; agent invocation; cwd guard
│   ├── checkpoint.sh              # Interactive checkpoints (plan / review)
│   ├── config.sh                  # Loads .autopilotrc; resolves env defaults
│   ├── linear.sh                  # URL parsing, ticket fetch (curl or via agent)
│   ├── phases.sh                  # Phase order table; phase_lt; need()
│   ├── state.sh                   # state.json read/write/mark
│   └── ui.sh                      # print_tldr; summary tables; pretty logging
├── prompts/
│   ├── 02-research.md             # Templates use {{PLACEHOLDER}} substitution
│   ├── 03-plan.md
│   ├── 04-implement.md
│   ├── 05a-reviewer.md
│   ├── 05b-adversary.md
│   ├── 05c-fixer.md
│   └── 06-pr-body.md
├── templates/
│   ├── plan-template.md           # Embedded in 03-plan prompt
│   ├── state.json                 # Initial state shape
│   └── feedback.json              # Initial feedback shape
├── tests/
│   ├── helpers.bash               # Common bats helpers
│   ├── test_phases.bats
│   ├── test_state.bats
│   ├── test_linear.bats
│   └── test_config.bats
├── docs/
│   └── plans/
│       └── 2026-05-20-autopilot-implementation.md   # this file
├── .autopilotrc.example           # Project-level config example
├── install.sh                     # Symlink bin/autopilot to ~/.local/bin
├── Makefile                       # `make test`, `make lint`
├── README.md
└── LICENSE
```

## Phase Order (canonical, used by `lib/phases.sh`)

```
none
worktree_done
research_done
plan_done
plan_approved
implement_done
review_cycle_1_done
review_cycle_2_done
review_cycle_3_done
review_approved
merged
```

## Run modes

Two modes, selected by `--full` / `--interactive` CLI flag (overrides `AUTOPILOT_MODE` env; default `interactive`).

| Mode | CHECKPOINT 1 (plan) | CHECKPOINT 2 (post-review) |
| --- | --- | --- |
| `interactive` | Print plan TLDR, prompt `go / changes <feedback> / stop`. On `changes`, re-run plan phase with feedback. Loop until `go`. | Print review summary, prompt `merge / pr / preview / hold`. |
| `full` | Auto-approve, no prompt, no TLDR pause. | Take `AUTOPILOT_DEFAULT_ACTION` (default `pr`) without prompting. |

Resume semantics are unchanged: re-running with a different `--mode` from a half-completed run uses the new mode for any phases not yet marked.

## Conventions

- Every shell script starts with `#!/usr/bin/env bash` + `set -euo pipefail`.
- `lib/*.sh` files only define functions — never run side effects on source.
- All paths are absolute or rooted in `$WT` (worktree). No relative paths in driver.
- Each agent prompt has a defensive first instruction: *"Verify cwd is `<worktree>`. If not, exit with error."*
- Commit messages: `task N: <component> — <one-line summary>`. Frequent commits, one per task.
- Tests: bats-core. Unit tests cover pure-logic libs (phases, state, linear URL parsing, config). Agent invocations are stubbed via `AUTOPILOT_AGENT_CMD=cat` or `=true`.

---

## Task 1: Initialize repo + skeleton

**Files:**
- Create: `/Users/artemdenysov/projects/autopilot_sh/.gitignore`
- Create: `/Users/artemdenysov/projects/autopilot_sh/README.md`
- Create: `/Users/artemdenysov/projects/autopilot_sh/LICENSE`
- Create: `/Users/artemdenysov/projects/autopilot_sh/Makefile`

**Step 1: Init git**

```bash
cd /Users/artemdenysov/projects/autopilot_sh
git init -b main
```

Verify: `git status` → "On branch main".

**Step 2: Write .gitignore**

```
.DS_Store
*.log
/tmp/
node_modules/
```

**Step 3: Write a minimal README.md (placeholder; expanded in Task 17)**

```markdown
# autopilot_sh

Resumable, agent-agnostic ralph-loop driver that takes a Linear ticket from worktree creation through merge.

See `docs/plans/2026-05-20-autopilot-implementation.md` for design and implementation status.
```

**Step 4: Write LICENSE (MIT, author: Artem Denysov)**

Standard MIT text with `Copyright (c) 2026 Artem Denysov`.

**Step 5: Write Makefile**

```makefile
.PHONY: test lint install

test:
	bats tests/

lint:
	shellcheck bin/autopilot lib/*.sh

install:
	./install.sh
```

**Step 6: Verify and commit**

```bash
ls -la                       # confirm .git, .gitignore, README.md, LICENSE, Makefile present
git add .
git commit -m "task 1: repo skeleton — gitignore, README, LICENSE, Makefile"
```

Expected: `git log --oneline` shows one commit.

---

## Task 2: Phase ordering library (TDD)

**Files:**
- Create: `tests/helpers.bash`
- Create: `tests/test_phases.bats`
- Create: `lib/phases.sh`

**Step 1: Write the failing test**

Create `tests/helpers.bash`:

```bash
# Common test setup
LIB_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/lib"
```

Create `tests/test_phases.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/phases.sh"
}

@test "phase_index returns 0 for 'none'" {
  run phase_index none
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "phase_index returns monotonic ranks" {
  a=$(phase_index worktree_done)
  b=$(phase_index research_done)
  c=$(phase_index plan_done)
  [ "$a" -lt "$b" ]
  [ "$b" -lt "$c" ]
}

@test "phase_lt is strict less-than" {
  run phase_lt none worktree_done
  [ "$status" -eq 0 ]
  run phase_lt worktree_done worktree_done
  [ "$status" -ne 0 ]
  run phase_lt research_done worktree_done
  [ "$status" -ne 0 ]
}

@test "phase_index errors on unknown phase" {
  run phase_index gibberish_phase
  [ "$status" -ne 0 ]
}

@test "all canonical phases are recognized" {
  for p in none worktree_done research_done plan_done plan_approved \
           implement_done review_cycle_1_done review_cycle_2_done \
           review_cycle_3_done review_approved merged; do
    run phase_index "$p"
    [ "$status" -eq 0 ]
  done
}
```

**Step 2: Run tests and verify they fail**

```bash
bats tests/test_phases.bats
```

Expected: All tests fail with "source: No such file" or similar.

**Step 3: Implement `lib/phases.sh`**

```bash
#!/usr/bin/env bash
# Phase ordering library. Source-only; defines functions.

# Canonical phase order. Index is rank.
_AUTOPILOT_PHASES=(
  none
  worktree_done
  research_done
  plan_done
  plan_approved
  implement_done
  review_cycle_1_done
  review_cycle_2_done
  review_cycle_3_done
  review_approved
  merged
)

# phase_index <phase> -> prints rank, exits 1 on unknown
phase_index() {
  local target="$1"
  local i
  for i in "${!_AUTOPILOT_PHASES[@]}"; do
    if [[ "${_AUTOPILOT_PHASES[$i]}" == "$target" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo "phase_index: unknown phase '$target'" >&2
  return 1
}

# phase_lt <a> <b> -> exit 0 if rank(a) < rank(b)
phase_lt() {
  local a b
  a=$(phase_index "$1") || return 2
  b=$(phase_index "$2") || return 2
  [[ "$a" -lt "$b" ]]
}
```

**Step 4: Run tests and verify they pass**

```bash
bats tests/test_phases.bats
```

Expected: 5 tests pass.

**Step 5: Commit**

```bash
git add lib/phases.sh tests/test_phases.bats tests/helpers.bash
git commit -m "task 2: phases.sh — phase ordering with tests"
```

---

## Task 3: State library (TDD)

**Files:**
- Create: `templates/state.json`
- Create: `tests/test_state.bats`
- Create: `lib/state.sh`

**Step 1: Write `templates/state.json`**

```json
{
  "ticket": null,
  "worktree": null,
  "branch": null,
  "plan_path": null,
  "phase": "none",
  "updated_at": null
}
```

**Step 2: Write the failing test**

`tests/test_state.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/phases.sh"
  source "$LIB_DIR/state.sh"
  TMP="$(mktemp -d)"
  export WT="$TMP"
  mkdir -p "$WT/.autopilot"
  cp "$LIB_DIR/../templates/state.json" "$WT/.autopilot/state.json"
}

teardown() {
  rm -rf "$TMP"
}

@test "state_phase returns 'none' from fresh template" {
  run state_phase
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "mark_phase updates state.json" {
  mark_phase worktree_done
  run state_phase
  [ "$output" = "worktree_done" ]
}

@test "mark_phase updates updated_at" {
  mark_phase worktree_done
  ts=$(jq -r .updated_at "$WT/.autopilot/state.json")
  [ "$ts" != "null" ]
  [ -n "$ts" ]
}

@test "mark_phase rejects unknown phase" {
  run mark_phase gibberish
  [ "$status" -ne 0 ]
}

@test "need returns success when current phase is behind target" {
  # state is 'none', so need worktree_done -> true
  run need worktree_done
  [ "$status" -eq 0 ]
}

@test "need returns failure when current phase has reached target" {
  mark_phase worktree_done
  run need worktree_done
  [ "$status" -ne 0 ]
}

@test "state_set updates a top-level field" {
  state_set ticket "TRA-550"
  val=$(jq -r .ticket "$WT/.autopilot/state.json")
  [ "$val" = "TRA-550" ]
}
```

**Step 3: Run tests to verify they fail**

```bash
bats tests/test_state.bats
```

Expected: failures because `lib/state.sh` doesn't exist.

**Step 4: Implement `lib/state.sh`**

```bash
#!/usr/bin/env bash
# State management. Requires $WT and phases.sh to be sourced.

_state_file() { echo "$WT/.autopilot/state.json"; }

state_phase() {
  jq -r .phase "$(_state_file)" 2>/dev/null || echo "none"
}

state_set() {
  local key="$1" value="$2"
  local tmp
  tmp=$(mktemp)
  jq --arg v "$value" ".${key} = \$v" "$(_state_file)" > "$tmp"
  mv "$tmp" "$(_state_file)"
}

mark_phase() {
  local phase="$1"
  phase_index "$phase" >/dev/null || return 1
  local tmp now
  tmp=$(mktemp)
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq --arg p "$phase" --arg t "$now" '.phase = $p | .updated_at = $t' \
    "$(_state_file)" > "$tmp"
  mv "$tmp" "$(_state_file)"
}

# need <target_phase>: exit 0 if current phase < target (i.e. work still to do)
need() {
  phase_lt "$(state_phase)" "$1"
}
```

**Step 5: Run tests to verify they pass**

```bash
bats tests/test_state.bats
```

Expected: 7 tests pass.

**Step 6: Commit**

```bash
git add lib/state.sh templates/state.json tests/test_state.bats
git commit -m "task 3: state.sh — state.json read/write with tests"
```

---

## Task 4: Linear URL parsing (TDD)

**Files:**
- Create: `tests/test_linear.bats`
- Create: `lib/linear.sh`

**Step 1: Write the failing test**

`tests/test_linear.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  source "$LIB_DIR/linear.sh"
}

@test "linear_parse_ticket from canonical URL" {
  run linear_parse_ticket "https://linear.app/trayo/issue/TRA-550/add-foo-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "TRA-550" ]
}

@test "linear_parse_ticket from URL with no slug" {
  run linear_parse_ticket "https://linear.app/trayo/issue/TRA-12"
  [ "$status" -eq 0 ]
  [ "$output" = "TRA-12" ]
}

@test "linear_parse_ticket from bare identifier" {
  run linear_parse_ticket "TRA-550"
  [ "$status" -eq 0 ]
  [ "$output" = "TRA-550" ]
}

@test "linear_parse_ticket lowercases identifier prefix in output is preserved as uppercase" {
  run linear_parse_ticket "https://linear.app/foo/issue/abc-1/hi"
  [ "$status" -eq 0 ]
  [ "$output" = "ABC-1" ]
}

@test "linear_parse_ticket rejects empty input" {
  run linear_parse_ticket ""
  [ "$status" -ne 0 ]
}

@test "linear_parse_ticket rejects nonsense" {
  run linear_parse_ticket "https://example.com/foo"
  [ "$status" -ne 0 ]
}

@test "linear_parse_slug from URL with slug" {
  run linear_parse_slug "https://linear.app/trayo/issue/TRA-550/add-foo-bar"
  [ "$status" -eq 0 ]
  [ "$output" = "add-foo-bar" ]
}

@test "linear_parse_slug returns empty for URL without slug" {
  run linear_parse_slug "https://linear.app/trayo/issue/TRA-550"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "linear_branch_name composes ticket + slug" {
  run linear_branch_name "TRA-550" "add-foo-bar"
  [ "$output" = "feature/tra-550-add-foo-bar" ]
}

@test "linear_branch_name omits slug when empty" {
  run linear_branch_name "TRA-550" ""
  [ "$output" = "feature/tra-550" ]
}
```

**Step 2: Run tests to verify they fail**

```bash
bats tests/test_linear.bats
```

Expected: all fail (file missing).

**Step 3: Implement `lib/linear.sh` (parse helpers only; fetch added in Task 7)**

```bash
#!/usr/bin/env bash
# Linear URL parsing and ticket fetch helpers.

# linear_parse_ticket <url-or-id> -> prints uppercase TEAM-NUMBER
linear_parse_ticket() {
  local input="${1:-}"
  [[ -z "$input" ]] && return 1
  local id=""
  if [[ "$input" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
    id="$input"
  elif [[ "$input" =~ /issue/([A-Za-z]+-[0-9]+) ]]; then
    id="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  # uppercase
  echo "${id^^}"
}

# linear_parse_slug <url> -> prints slug after the ticket id, or empty string
linear_parse_slug() {
  local input="${1:-}"
  if [[ "$input" =~ /issue/[A-Za-z]+-[0-9]+/([A-Za-z0-9._-]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# linear_branch_name <TICKET> <slug> -> prints feature/ticket-slug (lowercase)
linear_branch_name() {
  local ticket="${1,,}"
  local slug="${2:-}"
  if [[ -z "$slug" ]]; then
    echo "feature/${ticket}"
  else
    echo "feature/${ticket}-${slug}"
  fi
}
```

**Step 4: Run tests, verify pass**

```bash
bats tests/test_linear.bats
```

Expected: 10 tests pass.

**Step 5: Commit**

```bash
git add lib/linear.sh tests/test_linear.bats
git commit -m "task 4: linear.sh — URL/identifier parsing with tests"
```

---

## Task 5: Config loader (TDD)

**Files:**
- Create: `.autopilotrc.example`
- Create: `tests/test_config.bats`
- Create: `lib/config.sh`

**Step 1: Write `.autopilotrc.example`**

```bash
# autopilot per-project config. Source this file from your repo root.
# Copy to .autopilotrc in any repo you want autopilot to drive.

# Where worktrees live. Each worktree is "${AUTOPILOT_WORKTREE_BASE}/${project_name}/${ticket}"
: "${AUTOPILOT_WORKTREE_BASE:=$HOME/wt}"

# Coding agent invocation. Stdin = prompt, stdout = stream.
: "${AUTOPILOT_AGENT_CMD:=claude -p --output-format=stream-json --model ${AUTOPILOT_MODEL:-claude-opus-4-7}}"

# Default model passed via env. Per-phase overrides reserved (AUTOPILOT_MODEL_REVIEWER, etc.) but unused in v1.
: "${AUTOPILOT_MODEL:=claude-opus-4-7}"

# Files to symlink from the source repo into the worktree on creation.
# Newline-separated list of paths relative to repo root.
AUTOPILOT_SYMLINKS=".env
.mcp.json"

# Post-checkout setup command. Runs inside the fresh worktree.
AUTOPILOT_SETUP_CMD="pnpm install && pnpm prisma generate"

# Verification command run at end of implement and after each fixer cycle.
AUTOPILOT_VERIFY_CMD="make check test"

# Run mode: 'interactive' (default) or 'full'. CLI --full / --interactive overrides this.
: "${AUTOPILOT_MODE:=interactive}"

# In 'full' mode, what to do after the 3 review cycles complete.
# One of: merge / pr / preview / hold.
: "${AUTOPILOT_DEFAULT_ACTION:=pr}"
```

**Step 2: Write the failing test**

`tests/test_config.bats`:

```bash
#!/usr/bin/env bats

load helpers

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  source "$LIB_DIR/config.sh"
}

teardown() {
  rm -rf "$TMP"
}

@test "config_load applies defaults when no .autopilotrc present" {
  config_load
  [ "${AUTOPILOT_WORKTREE_BASE}" = "$HOME/wt" ]
  [ -n "${AUTOPILOT_AGENT_CMD}" ]
  [ -n "${AUTOPILOT_VERIFY_CMD}" ]
}

@test "config_load sources local .autopilotrc when present" {
  cat > .autopilotrc <<EOF
AUTOPILOT_WORKTREE_BASE="/tmp/custom-wt"
AUTOPILOT_VERIFY_CMD="echo custom"
EOF
  config_load
  [ "${AUTOPILOT_WORKTREE_BASE}" = "/tmp/custom-wt" ]
  [ "${AUTOPILOT_VERIFY_CMD}" = "echo custom" ]
}

@test "config_load preserves caller-set env overrides" {
  export AUTOPILOT_WORKTREE_BASE="/override"
  config_load
  [ "${AUTOPILOT_WORKTREE_BASE}" = "/override" ]
}

@test "config_project_name uses git remote when available" {
  git init -q
  git remote add origin git@github.com:foo/my-cool-repo.git
  run config_project_name
  [ "$output" = "my-cool-repo" ]
}

@test "config_project_name falls back to dir basename without remote" {
  git init -q
  mv "$TMP" "${TMP}-named-mycoolproj" || true
  # fallback path: no remote
  run config_project_name
  [ -n "$output" ]
}
```

**Step 3: Run tests to verify they fail**

```bash
bats tests/test_config.bats
```

Expected: file missing.

**Step 4: Implement `lib/config.sh`**

```bash
#!/usr/bin/env bash
# Config loader. Defaults < .autopilotrc < caller env.

config_load() {
  # Defaults (only set if unset, so caller env wins).
  : "${AUTOPILOT_WORKTREE_BASE:=$HOME/wt}"
  : "${AUTOPILOT_MODEL:=claude-opus-4-7}"
  : "${AUTOPILOT_AGENT_CMD:=claude -p --output-format=stream-json --model $AUTOPILOT_MODEL}"
  : "${AUTOPILOT_SETUP_CMD:=}"
  : "${AUTOPILOT_VERIFY_CMD:=make check test}"
  : "${AUTOPILOT_SYMLINKS:=}"
  : "${AUTOPILOT_MODE:=interactive}"
  : "${AUTOPILOT_DEFAULT_ACTION:=pr}"

  # Source .autopilotrc from cwd if present. Caller env still wins because
  # .autopilotrc should use `: ${X:=...}` form. Defensive: only source regular files.
  if [[ -f .autopilotrc ]]; then
    # shellcheck disable=SC1091
    source .autopilotrc
  fi

  export AUTOPILOT_WORKTREE_BASE AUTOPILOT_MODEL AUTOPILOT_AGENT_CMD \
         AUTOPILOT_SETUP_CMD AUTOPILOT_VERIFY_CMD AUTOPILOT_SYMLINKS \
         AUTOPILOT_MODE AUTOPILOT_DEFAULT_ACTION
}

# config_project_name -> prints repo name from origin remote, else cwd basename
config_project_name() {
  local url name
  if url=$(git config --get remote.origin.url 2>/dev/null) && [[ -n "$url" ]]; then
    name="${url##*/}"
    name="${name%.git}"
    echo "$name"
  else
    basename "$PWD"
  fi
}
```

**Step 5: Run tests, verify pass**

```bash
bats tests/test_config.bats
```

Expected: 5 tests pass.

**Step 6: Commit**

```bash
git add lib/config.sh .autopilotrc.example tests/test_config.bats
git commit -m "task 5: config.sh — .autopilotrc loader with project-name detection"
```

---

## Task 6: Agent invocation wrapper

**Files:**
- Create: `lib/agent.sh`
- Create: `lib/ui.sh`

**Step 1: Write `lib/ui.sh`**

```bash
#!/usr/bin/env bash
# UI helpers: colored logging, summary tables.

_ts() { date +"%H:%M:%S"; }

log_info()  { printf "\033[1;36m[%s]\033[0m %s\n" "$(_ts)" "$*"; }
log_warn()  { printf "\033[1;33m[%s]\033[0m %s\n" "$(_ts)" "$*" >&2; }
log_err()   { printf "\033[1;31m[%s]\033[0m %s\n" "$(_ts)" "$*" >&2; }
log_ok()    { printf "\033[1;32m[%s]\033[0m %s\n" "$(_ts)" "$*"; }

# print_tldr <plan_path>
print_tldr() {
  local plan="$1"
  [[ -f "$plan" ]] || { log_err "Plan not found: $plan"; return 1; }
  echo "── Plan TLDR ───────────────────────────────"
  # Print up to the first "## Task" or first 40 lines.
  awk '/^## Task / { exit } { print }' "$plan" | sed -n '1,40p'
  echo "────────────────────────────────────────────"
}

# feedback_summary <feedback.json>: print open/fixed/dropped totals by severity
feedback_summary() {
  local f="$1"
  [[ -f "$f" ]] || { log_err "Feedback not found: $f"; return 1; }
  echo "── Review summary ──────────────────────────"
  jq -r '
    .items
    | group_by(.severity)[]
    | "\(.[0].severity): " +
      "open=" + (map(select(.status=="open"))|length|tostring) + " " +
      "fixed=" + (map(select(.status=="fixed"))|length|tostring) + " " +
      "dropped=" + (map(select(.status=="dropped_by_adversary"))|length|tostring) + " " +
      "wontfix=" + (map(select(.status=="wontfix"))|length|tostring)
  ' "$f"
  echo "────────────────────────────────────────────"
}
```

**Step 2: Write `lib/agent.sh`**

```bash
#!/usr/bin/env bash
# Agent invocation wrapper. Requires: $WT, $AUTOPILOT_AGENT_CMD, lib/ui.sh sourced.

# render_prompt <prompt_template> <out_file>
# Substitutes {{VAR}} placeholders from current env into a prompt file.
render_prompt() {
  local tmpl="$1" out="$2"
  [[ -f "$tmpl" ]] || { log_err "Template missing: $tmpl"; return 1; }
  # envsubst handles ${VAR} but we use {{VAR}} for readability.
  # Strategy: convert {{VAR}} to ${VAR} then envsubst.
  sed -E 's/\{\{([A-Z_][A-Z0-9_]*)\}\}/\$\{\1\}/g' "$tmpl" | envsubst > "$out"
}

# run_phase <phase_name>
# Reads prompts/<phase_name>.md, renders it to .autopilot/prompts/<phase>.md,
# pipes to the agent inside the worktree, tees to .autopilot/logs/<phase>.log.
run_phase() {
  local name="$1"
  local repo_root="${AUTOPILOT_ROOT}"
  local tmpl="${repo_root}/prompts/${name}.md"
  local rendered="${WT}/.autopilot/prompts/${name}.md"
  local logf="${WT}/.autopilot/logs/${name}.log"

  mkdir -p "${WT}/.autopilot/prompts" "${WT}/.autopilot/logs"
  render_prompt "$tmpl" "$rendered" || return 1

  log_info "Phase ${name} → ${AUTOPILOT_AGENT_CMD%% *}"
  # shellcheck disable=SC2086
  ( cd "$WT" && eval $AUTOPILOT_AGENT_CMD ) < "$rendered" 2>&1 | tee "$logf"
  local rc="${PIPESTATUS[0]}"
  if [[ "$rc" -ne 0 ]]; then
    log_err "Phase ${name} exited ${rc}. Log: ${logf}"
    return "$rc"
  fi
  log_ok "Phase ${name} done."
}
```

**Step 3: Manually smoke-test `render_prompt`**

```bash
mkdir -p /tmp/ap-smoke && cd /tmp/ap-smoke
cat > tmpl.md <<'EOF'
Worktree is {{WT}}. Ticket is {{TICKET}}.
EOF
WT=/foo TICKET=TRA-1 bash -c '
  source /Users/artemdenysov/projects/autopilot_sh/lib/ui.sh
  source /Users/artemdenysov/projects/autopilot_sh/lib/agent.sh
  render_prompt tmpl.md out.md
  cat out.md
'
```

Expected output: `Worktree is /foo. Ticket is TRA-1.`

**Step 4: Commit**

```bash
git add lib/agent.sh lib/ui.sh
git commit -m "task 6: agent.sh + ui.sh — prompt rendering and agent invocation"
```

---

## Task 7: Linear ticket fetch via MCP + Phase 01 prep

**Files:**
- Modify: `lib/linear.sh` — add `linear_fetch`
- Create: `prompts/01-worktree-fetch.md`

**Prerequisite:** The configured agent (`AUTOPILOT_AGENT_CMD`) must have a Linear MCP server installed and authenticated. For Claude Code this means the `plugin:linear:linear` MCP (or equivalent) is enabled in the user's config. Fetch goes through MCP only — no direct HTTP path. This is a deliberate single-auth-path choice.

**Step 1: Extend `lib/linear.sh` with fetch**

Append:

```bash
# linear_fetch <TICKET_ID> <out_json_path>
# Routes through the agent's Linear MCP. Agent must have Linear MCP configured.
linear_fetch() {
  local ticket="$1" out="$2"
  local rendered="${WT}/.autopilot/prompts/01-worktree-fetch.md"
  mkdir -p "$(dirname "$rendered")"
  TICKET="$ticket" OUT="$out" render_prompt \
    "${AUTOPILOT_ROOT}/prompts/01-worktree-fetch.md" "$rendered"
  # shellcheck disable=SC2086
  ( cd "$WT" && eval $AUTOPILOT_AGENT_CMD ) < "$rendered" \
    | tee "$WT/.autopilot/logs/01-worktree-fetch.log"
  if [[ ! -s "$out" ]]; then
    log_err "Linear fetch did not produce $out. Check that the agent's Linear MCP is installed and authenticated."
    return 1
  fi
}
```

**Step 2: Write `prompts/01-worktree-fetch.md`**

```markdown
You are a Linear fetch agent. Do exactly one thing and exit.

Call your Linear MCP tool (e.g. `mcp__plugin_linear_linear__get_issue` or whichever Linear MCP your runtime exposes) to fetch ticket `{{TICKET}}`. Write the response as JSON to the absolute path `{{OUT}}`. The JSON must include at minimum: `identifier`, `title`, `description`, `state`, `url`, `team`.

If you do not have a Linear MCP tool available, exit non-zero with a clear error message — do NOT attempt a direct HTTP call.

Do not read other files. Do not edit anything else. Do not summarize. Exit immediately after writing the file.
```

**Step 3: Smoke-verify with stubbed agent**

```bash
cd /tmp && rm -rf ap-smoke7 && mkdir ap-smoke7 && cd ap-smoke7
mkdir -p .autopilot/prompts .autopilot/logs
WT=$PWD AUTOPILOT_ROOT=/Users/artemdenysov/projects/autopilot_sh \
AUTOPILOT_AGENT_CMD="bash -c 'cat > /dev/null; echo {\"identifier\":\"TRA-1\"} > '$PWD'/ticket.json'" \
bash -c '
  source $AUTOPILOT_ROOT/lib/ui.sh
  source $AUTOPILOT_ROOT/lib/agent.sh
  source $AUTOPILOT_ROOT/lib/linear.sh
  linear_fetch TRA-1 $PWD/ticket.json && cat ticket.json
'
```

Expected: prints `{"identifier":"TRA-1"}`.

**Step 4: Commit**

```bash
git add lib/linear.sh prompts/01-worktree-fetch.md
git commit -m "task 7: linear_fetch via MCP + fetch prompt"
```

---

## Task 8: Phase 01 — bash-driven worktree creation

**Files:**
- Create: `lib/phase01.sh`
- Create: `templates/feedback.json`

**Step 1: Write `templates/feedback.json`**

```json
{
  "cycles": [],
  "items": []
}
```

**Step 2: Write `lib/phase01.sh`**

```bash
#!/usr/bin/env bash
# Phase 01: bash-driven worktree creation. Requires:
# $AUTOPILOT_ROOT, $AUTOPILOT_WORKTREE_BASE, $AUTOPILOT_SYMLINKS,
# $AUTOPILOT_SETUP_CMD, source_repo set by caller.

phase01_worktree() {
  local linear_input="$1"
  local source_repo="$2"   # absolute path to the repo we're cutting a worktree from

  local ticket slug branch project wt
  ticket=$(linear_parse_ticket "$linear_input") || { log_err "Bad Linear input"; return 1; }
  slug=$(linear_parse_slug "$linear_input")
  branch=$(linear_branch_name "$ticket" "$slug")
  project=$(cd "$source_repo" && config_project_name)
  wt="${AUTOPILOT_WORKTREE_BASE}/${project}/${ticket,,}"

  export WT="$wt"
  log_info "Worktree target: $WT"
  log_info "Branch:          $branch"
  log_info "Source repo:     $source_repo"

  if [[ -d "$WT" ]]; then
    log_warn "Worktree dir already exists — assuming resume; skipping git worktree add"
  else
    ( cd "$source_repo" && git fetch origin main )
    ( cd "$source_repo" && git worktree add "$WT" -b "$branch" origin/main )
  fi

  mkdir -p "$WT/.autopilot/prompts" "$WT/.autopilot/logs"
  [[ -f "$WT/.autopilot/state.json" ]] \
    || cp "$AUTOPILOT_ROOT/templates/state.json" "$WT/.autopilot/state.json"
  [[ -f "$WT/.autopilot/feedback.json" ]] \
    || cp "$AUTOPILOT_ROOT/templates/feedback.json" "$WT/.autopilot/feedback.json"

  # Symlinks
  if [[ -n "$AUTOPILOT_SYMLINKS" ]]; then
    while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      local src="$source_repo/$rel"
      local dst="$WT/$rel"
      if [[ -e "$src" && ! -e "$dst" ]]; then
        mkdir -p "$(dirname "$dst")"
        ln -s "$src" "$dst"
        log_info "Symlinked $rel"
      fi
    done <<< "$AUTOPILOT_SYMLINKS"
  fi

  # Fetch ticket JSON
  linear_fetch "$ticket" "$WT/.autopilot/ticket.json"

  # Record state
  state_set ticket "$ticket"
  state_set worktree "$WT"
  state_set branch "$branch"

  # Setup command
  if [[ -n "${AUTOPILOT_SETUP_CMD:-}" ]]; then
    log_info "Running setup: $AUTOPILOT_SETUP_CMD"
    ( cd "$WT" && eval "$AUTOPILOT_SETUP_CMD" ) || { log_err "Setup failed"; return 1; }
  fi
}
```

**Step 3: Smoke-test against a throwaway repo**

```bash
rm -rf /tmp/src-repo /tmp/wt-base
mkdir -p /tmp/src-repo && cd /tmp/src-repo
git init -q -b main && git commit --allow-empty -m initial
git remote add origin git@github.com:foo/dummy.git

cd /Users/artemdenysov/projects/autopilot_sh
AUTOPILOT_ROOT=$PWD \
AUTOPILOT_WORKTREE_BASE=/tmp/wt-base \
AUTOPILOT_AGENT_CMD="bash -c 'cat > /dev/null; echo {\"identifier\":\"TRA-1\"} > \$OUT'" \
AUTOPILOT_SYMLINKS="" AUTOPILOT_SETUP_CMD="" \
bash -c '
  source lib/ui.sh; source lib/phases.sh; source lib/state.sh
  source lib/linear.sh; source lib/config.sh; source lib/agent.sh; source lib/phase01.sh
  config_load
  phase01_worktree "TRA-1" /tmp/src-repo
  echo "--- state ---"; cat $WT/.autopilot/state.json
  echo "--- ticket ---"; cat $WT/.autopilot/ticket.json
'
```

Expected: `git worktree list` (from /tmp/src-repo) shows the new worktree; state.json has ticket=TRA-1; ticket.json has identifier=TRA-1.

**Step 4: Commit**

```bash
git add lib/phase01.sh templates/feedback.json
git commit -m "task 8: phase01.sh — bash-driven worktree creation"
```

---

## Task 9: Research, plan, implement prompts

**Files:**
- Create: `prompts/02-research.md`
- Create: `prompts/03-plan.md`
- Create: `prompts/04-implement.md`
- Create: `templates/plan-template.md`

**Step 1: Write `prompts/02-research.md`**

```markdown
You are the research agent for ticket {{TICKET}}.

Verify cwd is `{{WT}}`. If not, exit with error.

1. Read `.autopilot/ticket.json` to understand the task.
2. Spawn three codebase research subagents IN PARALLEL using your Agent tool. Each gets a focused brief:
   - One for relevant files and call sites
   - One for similar patterns / prior art to model after
   - One for code conventions and constraints (lint rules, type signatures, test style)
3. Read every file the subagents flag.
4. Produce `.autopilot/research.md` with three sections:
   - **Relevant files** — bullet list of `path:line` with one-line purpose
   - **Patterns to model after** — short snippets showing the conventions
   - **Constraints** — types, naming, error handling, test conventions you must respect

Do NOT write a plan. Do NOT modify any source code. Research only.
Exit when `research.md` is written.
```

**Step 2: Write `templates/plan-template.md`**

```markdown
# {{TITLE}} Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** <one sentence>

**Architecture:** <2-3 sentences>

**Tech Stack:** <key libs>

---

## Task 1: <bite-sized task>

**Files:**
- Create: `<path>`
- Modify: `<path>:<lines>`
- Test: `<path>`

**Step 1: Write the failing test**

\`\`\`<lang>
<test code>
\`\`\`

**Step 2: Run test, verify failure**

Run: `<cmd>`
Expected: <fail mode>

**Step 3: Implement minimal code**

\`\`\`<lang>
<impl>
\`\`\`

**Step 4: Run test, verify pass**

Run: `<cmd>`

**Step 5: Commit**

\`\`\`bash
git add <files>
git commit -m "task 1: <summary>"
\`\`\`

---

(repeat for each task)
```

**Step 3: Write `prompts/03-plan.md`**

```markdown
You are the planning agent for ticket {{TICKET}}.

Verify cwd is `{{WT}}`. If not, exit with error.

1. Read `.autopilot/ticket.json` and `.autopilot/research.md`.
2. Do NOT spawn research subagents — research is already done.
3. Write an implementation plan to `docs/plans/{{DATE}}-{{TICKET_LC}}-{{SLUG}}.md` following the structure in `{{AUTOPILOT_ROOT}}/templates/plan-template.md`.

Plan must contain:
- A 1-sentence Goal and 2-3 sentence Architecture
- Bite-sized tasks (2-5 min each), TDD, with full code snippets and exact verification commands
- Each task has commit at the end

Update `.autopilot/state.json` `plan_path` field to the file you wrote (use `jq` in a Bash tool call).

Exit after the plan file and state update are written.
```

**Step 4: Write `prompts/04-implement.md`**

```markdown
You are the implementation agent for ticket {{TICKET}}.

Verify cwd is `{{WT}}`. If not, exit with error.

1. Read the plan at `{{PLAN_PATH}}`.
2. Read every file the plan mentions, plus `.autopilot/research.md` for context.
3. Execute each task in order. After each task:
   - Run the task's verification command(s) exactly as specified.
   - If a verification fails, debug and fix before moving on.
   - Commit with the message specified in the plan.
   - Update the plan file: replace the task's heading with `## Task N: <name> [DONE]`.
4. After all tasks: run `{{VERIFY_CMD}}`. It must pass.

Resume rules: if you see `[DONE]` markers from a prior run, skip those tasks but still read their files.

Exit non-zero if the final verify fails.
```

**Step 5: Commit**

```bash
git add prompts/02-research.md prompts/03-plan.md prompts/04-implement.md templates/plan-template.md
git commit -m "task 9: prompts for research / plan / implement phases"
```

---

## Task 10: Checkpoint helpers

**Files:**
- Create: `lib/checkpoint.sh`

**Step 1: Write `lib/checkpoint.sh`**

```bash
#!/usr/bin/env bash
# Interactive checkpoints. Reads from /dev/tty so checkpoints work even when
# stdout is being piped to tee. Honors $AUTOPILOT_MODE (interactive|full).

_ask() {
  local prompt="$1" reply=""
  printf "%s " "$prompt" > /dev/tty
  IFS= read -r reply < /dev/tty
  echo "$reply"
}

# checkpoint_plan <plan_path>
# interactive: print TLDR, loop on go/changes/stop. 'changes <feedback>' or a
#              follow-up prompt re-runs 03-plan with that feedback.
# full:        no-op (auto-approve).
checkpoint_plan() {
  local plan="$1"
  if [[ "${AUTOPILOT_MODE:-interactive}" == "full" ]]; then
    log_info "Plan auto-approved (full mode)."
    return 0
  fi
  print_tldr "$plan"
  while :; do
    local ans
    ans=$(_ask "Proceed? [go / changes / stop]")
    case "$ans" in
      go)      return 0 ;;
      changes*)
        # Accept inline feedback after 'changes ', otherwise prompt for it.
        local fb="${ans#changes}"
        fb="${fb# }"
        [[ -z "$fb" ]] && fb=$(_ask "What should change?")
        log_info "Re-running plan with feedback: $fb"
        FEEDBACK="$fb" run_phase 03-plan || return 1
        print_tldr "$plan"
        ;;
      stop)    log_info "Stopping at plan checkpoint."; exit 0 ;;
      *)       log_warn "Unknown response: $ans" ;;
    esac
  done
}

# checkpoint_review <branch> <commit_count>
# interactive: prompt merge/pr/preview/hold.
# full:        take $AUTOPILOT_DEFAULT_ACTION (default 'pr').
checkpoint_review() {
  local branch="$1" commits="$2"
  feedback_summary "$WT/.autopilot/feedback.json"
  echo
  echo "Branch:  $branch"
  echo "Commits: $commits"

  if [[ "${AUTOPILOT_MODE:-interactive}" == "full" ]]; then
    local act="${AUTOPILOT_DEFAULT_ACTION:-pr}"
    log_info "Review auto-action (full mode): $act"
    _AUTOPILOT_REVIEW_DECISION="$act"
    export _AUTOPILOT_REVIEW_DECISION
    return 0
  fi

  while :; do
    local ans
    ans=$(_ask "Action? [merge / pr / preview / hold]")
    case "$ans" in
      merge|pr|preview|hold)
        _AUTOPILOT_REVIEW_DECISION="$ans"
        export _AUTOPILOT_REVIEW_DECISION
        return 0
        ;;
      *) log_warn "Unknown response: $ans" ;;
    esac
  done
}
```

Also update `prompts/03-plan.md` to consume an optional `{{FEEDBACK}}` placeholder. Add this section at the bottom of the prompt:

```markdown
If `{{FEEDBACK}}` is non-empty, treat it as user revisions to the plan you previously wrote. Re-read the existing plan file, apply the revisions, and overwrite the same plan file in place. Do not create a new file.
```

**Step 2: Smoke-test interactively**

```bash
cd /Users/artemdenysov/projects/autopilot_sh
echo -e "go" | bash -c '
  source lib/ui.sh; source lib/checkpoint.sh
  print_tldr docs/plans/2026-05-20-autopilot-implementation.md
' < /dev/tty
```

(Manual: type `go`, expect exit 0.)

**Step 3: Commit**

```bash
git add lib/checkpoint.sh
git commit -m "task 10: checkpoint.sh — plan + review interactive checkpoints"
```

---

## Task 11: Review cycle prompts

**Files:**
- Create: `prompts/05a-reviewer.md`
- Create: `prompts/05b-adversary.md`
- Create: `prompts/05c-fixer.md`

**Step 1: Write `prompts/05a-reviewer.md`**

```markdown
You are the REVIEWER for ticket {{TICKET}}, cycle {{CYCLE}}.

Verify cwd is `{{WT}}`. If not, exit.

Tools you may use: Read, Grep, Glob, Bash (read-only — no git mutate, no edits to source). The only file you may write/edit is `.autopilot/feedback.json`.

1. Read `.autopilot/feedback.json` first. Note all `open` items — do NOT re-flag any issue whose `detail` substantively matches one you would raise. That's overlap.
2. Diff to review: `git diff {{BASE_SHA}}..{{HEAD_SHA}}`.
3. Apply the standard review checklist: correctness, tests, architecture, perf, security, style.
4. For each NEW finding, append an object to `.items` with:
   - `id`: `c{{CYCLE}}-r-NNN` (3-digit monotonic per cycle+source)
   - `cycle`: {{CYCLE}} (integer)
   - `source`: `"reviewer"`
   - `severity`: `"critical"` | `"important"` | `"minor"`
   - `category`: one of correctness / tests / architecture / perf / security / style
   - `title`: short title
   - `detail`: what + where as `file:line — explanation`
   - `status`: `"open"`
   - `resolution_sha`: null, `resolution_note`: null

Exit when done. Be specific. No vibes-based feedback.
```

**Step 2: Write `prompts/05b-adversary.md`**

```markdown
You are the ADVERSARY for ticket {{TICKET}}, cycle {{CYCLE}}.

Verify cwd is `{{WT}}`. If not, exit.

Tools: Read, Grep, Glob, Bash (read-only). Edit only `.autopilot/feedback.json`.

1. Read `.autopilot/feedback.json`.
2. For each `open` item with `cycle == {{CYCLE}}` and `source == "reviewer"`:
   - **Confirm** (leave as-is) if the issue is real and the severity is calibrated.
   - **Downgrade severity** if overblown — change `severity` and append note to `detail`: ` [adversary: downgraded — <reason>]`.
   - **Drop** if it's noise, churn, or a matter of taste — set `status` to `"dropped_by_adversary"` and append to `detail`: ` [adversary: dropped — <reason>]`.
3. Then run YOUR OWN review pass on `git diff {{BASE_SHA}}..{{HEAD_SHA}}`. Append items the reviewer missed with `source: "adversary"` and `id: "c{{CYCLE}}-a-NNN"`.

Be ruthless about noise. Junior-reviewer pedantry should be dropped. Real bugs must survive.

Exit when done.
```

**Step 3: Write `prompts/05c-fixer.md`**

```markdown
You are the FIXER for ticket {{TICKET}}, cycle {{CYCLE}}.

Verify cwd is `{{WT}}`. If not, exit.

Full tool access scoped to {{WT}}.

1. Read `.autopilot/feedback.json`.
2. For every item with `status == "open"` and `severity != "minor"`: fix it.
   - After each fix:
     - Stage and commit with `fix(review-c{{CYCLE}}): <item title>`
     - Update that item in `feedback.json`: set `status` to `"fixed"`, `resolution_sha` to the new commit SHA (`git rev-parse HEAD`), `resolution_note` to a one-sentence summary.
3. For `minor` items: fix only if trivial (<5 LoC). Otherwise mark `status` to `"wontfix"` with a `resolution_note` explaining why.
4. After all fixes: run `{{VERIFY_CMD}}`. Must pass. If it fails, debug and fix before exiting.

Exit non-zero if verify fails.
```

**Step 4: Commit**

```bash
git add prompts/05a-reviewer.md prompts/05b-adversary.md prompts/05c-fixer.md
git commit -m "task 11: review cycle prompts (reviewer, adversary, fixer)"
```

---

## Task 12: Review cycle driver

**Files:**
- Create: `lib/review.sh`

**Step 1: Write `lib/review.sh`**

```bash
#!/usr/bin/env bash
# Review cycle driver. Requires $WT and prior libs sourced.

# run_review_cycle <N>
run_review_cycle() {
  local n="$1"
  local base head
  base=$(git -C "$WT" merge-base origin/main HEAD)
  head=$(git -C "$WT" rev-parse HEAD)

  # Record cycle metadata
  local tmp; tmp=$(mktemp)
  jq --argjson n "$n" --arg b "$base" --arg h "$head" --arg t "$(date -u +%FT%TZ)" \
    '.cycles += [{n: $n, started_at: $t, base_sha: $b, head_sha: $h}]' \
    "$WT/.autopilot/feedback.json" > "$tmp"
  mv "$tmp" "$WT/.autopilot/feedback.json"

  export CYCLE="$n" BASE_SHA="$base" HEAD_SHA="$head"

  run_phase 05a-reviewer  || return 1
  run_phase 05b-adversary || return 1
  run_phase 05c-fixer     || return 1
}
```

**Step 2: Commit**

```bash
git add lib/review.sh
git commit -m "task 12: review.sh — three-step review cycle driver"
```

---

## Task 13: PR-body prompt + Phase 06 (merge or PR)

**Files:**
- Create: `prompts/06-pr-body.md`
- Create: `lib/phase06.sh`

**Step 1: Write `prompts/06-pr-body.md`**

```markdown
You are generating a PR body for ticket {{TICKET}}.

Verify cwd is `{{WT}}`. If not, exit.

1. Read `.autopilot/ticket.json` and the plan at `{{PLAN_PATH}}`.
2. Read `git log {{BASE_SHA}}..HEAD --oneline`.
3. Write a markdown PR body to `.autopilot/pr-body.md`:
   - ## Summary (3-6 bullets — what changed and why)
   - ## Linear ticket — link from `ticket.json.url`
   - ## Test plan — bullet list of the verification commands used
   - ## Notes — anything reviewers should pay attention to (any wontfix items from feedback.json)

Exit after writing the file.
```

**Step 2: Write `lib/phase06.sh`**

```bash
#!/usr/bin/env bash
# Phase 06: merge / pr / preview / hold.

phase06_merge_or_pr() {
  local branch base
  branch=$(jq -r .branch "$WT/.autopilot/state.json")
  base=$(git -C "$WT" merge-base origin/main HEAD)

  case "${_AUTOPILOT_REVIEW_DECISION:-hold}" in
    merge)
      ( cd "$WT" && git checkout main && git pull --ff-only && \
        git merge --no-ff "$branch" -m "merge: $branch" && \
        git push origin main )
      ;;
    pr)
      export BASE_SHA="$base"
      run_phase 06-pr-body || return 1
      local body="$WT/.autopilot/pr-body.md"
      ( cd "$WT" && git push -u origin "$branch" && \
        gh pr create --title "$(jq -r .title "$WT/.autopilot/ticket.json")" \
                     --body-file "$body" )
      ;;
    preview)
      log_info "Preview: branch $branch pushed but not merged."
      ( cd "$WT" && git push -u origin "$branch" )
      ;;
    hold)
      log_info "Hold: nothing to push. Worktree preserved at $WT."
      ;;
  esac
}
```

**Step 3: Commit**

```bash
git add prompts/06-pr-body.md lib/phase06.sh
git commit -m "task 13: phase06.sh + PR-body prompt"
```

---

## Task 14: Entry script wiring everything together

**Files:**
- Create: `bin/autopilot`

**Step 1: Write `bin/autopilot`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve AUTOPILOT_ROOT (this script's repo).
AUTOPILOT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AUTOPILOT_ROOT

# Source libs in dependency order.
# shellcheck source=../lib/ui.sh
source "$AUTOPILOT_ROOT/lib/ui.sh"
source "$AUTOPILOT_ROOT/lib/config.sh"
source "$AUTOPILOT_ROOT/lib/phases.sh"
source "$AUTOPILOT_ROOT/lib/state.sh"
source "$AUTOPILOT_ROOT/lib/linear.sh"
source "$AUTOPILOT_ROOT/lib/agent.sh"
source "$AUTOPILOT_ROOT/lib/checkpoint.sh"
source "$AUTOPILOT_ROOT/lib/review.sh"
source "$AUTOPILOT_ROOT/lib/phase01.sh"
source "$AUTOPILOT_ROOT/lib/phase06.sh"

usage() {
  cat <<EOF
Usage: autopilot [--interactive | --full] <linear-url-or-id>

Runs the ralph-loop from worktree creation through merge. Resumable: re-run to
continue from the last completed phase.

Modes:
  --interactive (default)   Pause at plan TLDR and post-review checkpoints.
  --full                    No checkpoints. Auto-approves plan; takes
                            AUTOPILOT_DEFAULT_ACTION (default 'pr') after review.

Env vars (see .autopilotrc.example):
  AUTOPILOT_MODE            interactive | full (overridden by CLI flag)
  AUTOPILOT_DEFAULT_ACTION  merge | pr | preview | hold (full mode only; default pr)
  AUTOPILOT_WORKTREE_BASE   Default: \$HOME/wt
  AUTOPILOT_AGENT_CMD       Default: claude -p ...
  AUTOPILOT_MODEL           Default: claude-opus-4-7
  AUTOPILOT_VERIFY_CMD      Default: make check test
  AUTOPILOT_SETUP_CMD       Default: (none)
  AUTOPILOT_SYMLINKS        Newline-separated paths to symlink from source repo

Prerequisite: the agent referenced by AUTOPILOT_AGENT_CMD must have a Linear
MCP server installed and authenticated.
EOF
}

# Parse flags.
MODE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)        MODE_OVERRIDE="full"; shift ;;
    --interactive) MODE_OVERRIDE="interactive"; shift ;;
    -h|--help)     usage; exit 0 ;;
    --) shift; break ;;
    -*) log_err "Unknown flag: $1"; usage; exit 2 ;;
    *)  break ;;
  esac
done

[[ $# -lt 1 ]] && { usage; exit 2; }
LINEAR_INPUT="$1"
[[ -n "$MODE_OVERRIDE" ]] && AUTOPILOT_MODE="$MODE_OVERRIDE"
: "${AUTOPILOT_MODE:=interactive}"
: "${AUTOPILOT_DEFAULT_ACTION:=pr}"
export AUTOPILOT_MODE AUTOPILOT_DEFAULT_ACTION
log_info "Mode: $AUTOPILOT_MODE"

# We assume the caller's cwd is the source repo.
SOURCE_REPO="$(pwd)"
[[ -d "$SOURCE_REPO/.git" ]] || { log_err "Run from inside a git repo"; exit 1; }

config_load

TICKET=$(linear_parse_ticket "$LINEAR_INPUT") || { log_err "Bad Linear input"; exit 1; }
SLUG=$(linear_parse_slug "$LINEAR_INPUT")
PROJECT=$(config_project_name)
WT="${AUTOPILOT_WORKTREE_BASE}/${PROJECT}/${TICKET,,}"
export TICKET SLUG PROJECT WT

# If worktree doesn't exist yet, phase 01 creates it. If it does, state.json
# already exists and we read its phase to know where to resume.
if [[ ! -f "$WT/.autopilot/state.json" ]]; then
  phase01_worktree "$LINEAR_INPUT" "$SOURCE_REPO"
  mark_phase worktree_done
fi

DATE=$(date -u +%F)
TICKET_LC="${TICKET,,}"
export DATE TICKET_LC

# Phase 02
if need research_done; then run_phase 02-research && mark_phase research_done; fi

# Phase 03
if need plan_done; then run_phase 03-plan && mark_phase plan_done; fi

# Checkpoint 1
if need plan_approved; then
  PLAN_PATH=$(jq -r .plan_path "$WT/.autopilot/state.json")
  export PLAN_PATH
  checkpoint_plan "$WT/$PLAN_PATH"
  mark_phase plan_approved
fi

# Phase 04
if need implement_done; then
  export PLAN_PATH=$(jq -r .plan_path "$WT/.autopilot/state.json")
  export VERIFY_CMD="$AUTOPILOT_VERIFY_CMD"
  run_phase 04-implement && mark_phase implement_done
fi

# Phases 05x1..3
for n in 1 2 3; do
  marker="review_cycle_${n}_done"
  if need "$marker"; then
    run_review_cycle "$n" && mark_phase "$marker"
  fi
done

# Checkpoint 2
if need review_approved; then
  branch=$(jq -r .branch "$WT/.autopilot/state.json")
  commits=$(git -C "$WT" rev-list --count "origin/main..HEAD")
  checkpoint_review "$branch" "$commits"
  mark_phase review_approved
fi

# Phase 06
if need merged; then
  export PLAN_PATH=$(jq -r .plan_path "$WT/.autopilot/state.json")
  phase06_merge_or_pr && mark_phase merged
fi

log_ok "Autopilot done for $TICKET. Phase: $(state_phase)."
```

**Step 2: Make executable**

```bash
chmod +x bin/autopilot
```

**Step 3: Sanity check — usage and bad input**

```bash
./bin/autopilot
# Expected: prints usage, exit 2
./bin/autopilot nonsense
# Expected: "Run from inside a git repo" if no .git in cwd, OR "Bad Linear input" if .git present
```

**Step 4: Commit**

```bash
git add bin/autopilot
git commit -m "task 14: bin/autopilot — entry script wiring all phases"
```

---

## Task 15: Install script

**Files:**
- Create: `install.sh`

**Step 1: Write `install.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
TARGET="${TARGET_DIR}/autopilot"

mkdir -p "$TARGET_DIR"

if [[ -L "$TARGET" || -e "$TARGET" ]]; then
  echo "Already exists: $TARGET. Remove it first if you want to reinstall."
  exit 1
fi

ln -s "$ROOT/bin/autopilot" "$TARGET"
echo "Installed: $TARGET -> $ROOT/bin/autopilot"
echo "Ensure $TARGET_DIR is on your PATH."
```

**Step 2: Make executable + commit**

```bash
chmod +x install.sh
git add install.sh
git commit -m "task 15: install.sh — symlink bin/autopilot into ~/.local/bin"
```

---

## Task 16: Lint pass (shellcheck)

**Step 1: Install shellcheck if missing**

```bash
command -v shellcheck >/dev/null || brew install shellcheck
```

**Step 2: Run lint**

```bash
make lint
```

Expected: zero errors. Fix any reported issues by editing the offending file inline and re-running. Common fixes: quote variables, replace `[ ]` with `[[ ]]`, mark `# shellcheck disable=...` only where intentional.

**Step 3: Commit any fixes**

```bash
git add -u
git commit -m "task 16: shellcheck fixes" || echo "no fixes needed"
```

---

## Task 17: README + smoke test

**Files:**
- Modify: `README.md`

**Step 1: Replace README.md with full docs**

```markdown
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

You need: `bash 5+`, `jq`, `git` with worktree support, and a coding-agent CLI on PATH (default: Claude Code's `claude`). The agent must have a **Linear MCP server** installed and authenticated — ticket fetch goes through MCP, not direct API. For Claude Code, enable the `plugin:linear:linear` MCP (or equivalent).

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
```

**Step 2: Run the full test suite**

```bash
make test
```

Expected: all tests pass.

**Step 3: End-to-end dry-run with a stub agent**

```bash
# Fresh source repo
rm -rf /tmp/src-e2e /tmp/wt-e2e
mkdir -p /tmp/src-e2e && cd /tmp/src-e2e
git init -q -b main
git commit --allow-empty -m "initial"
git remote add origin git@github.com:foo/e2e.git

# Stub agent that just writes files the phases expect
cat > /tmp/stub-agent.sh <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
# Best-effort: detect phase by env and write expected outputs
case "${1:-}" in *) ;; esac
EOF
chmod +x /tmp/stub-agent.sh

AUTOPILOT_WORKTREE_BASE=/tmp/wt-e2e \
AUTOPILOT_AGENT_CMD="/tmp/stub-agent.sh" \
AUTOPILOT_VERIFY_CMD="true" \
AUTOPILOT_SETUP_CMD="" \
LINEAR_API_KEY="" \
/Users/artemdenysov/projects/autopilot_sh/bin/autopilot TRA-1 || true
```

Expected: phase 01 succeeds (worktree created, state.json has phase `worktree_done`). Later phases may fail because the stub doesn't write the right outputs — that's OK; the goal here is to confirm the driver flow up to the first agent-dependent phase.

**Step 4: Commit + final tag**

```bash
git add README.md
git commit -m "task 17: README + smoke test"
git tag v0.1.0
```

---

## Out of scope (deferred to follow-ups)

- Per-phase model overrides (`AUTOPILOT_MODEL_REVIEWER`, etc.)
- Parallel reviewers
- Dynamic cycle count based on open-item severity
- Multi-ticket parallelism / webhook trigger
- Integration tests that actually invoke Claude (cost gate)
- Migration guide for users who have an existing `/autopilot` slash command

## Verification — definition of done

- `make test` passes (all bats suites green)
- `make lint` passes (shellcheck clean)
- `./bin/autopilot --help`-equivalent (no-arg) prints usage and exits 2
- End-to-end smoke (Task 17 Step 3) creates a worktree and marks `worktree_done`
- A real Linear ticket run (manual, not in plan) completes through at least the plan checkpoint
- `git tag` shows `v0.1.0`
