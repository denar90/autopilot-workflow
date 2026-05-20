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
