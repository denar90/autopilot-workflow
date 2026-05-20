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
