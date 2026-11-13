---
name: handover-keeper
description: Maintain durable task continuity, project state, version records, changelog and next actions across Ani Games Ready chats.
---

# Handover Keeper

Before starting: read project state, decisions, next tasks, changelog, version ledger and the last relevant handover.

At each milestone: record selected repository/branch/full SHA, source baseline, changed files, build run/artifact identity, test outcomes and blockers.

Before ending:
1. Update `PROJECT_STATE.md` with actual current status.
2. Update `VERSION_LEDGER.md` with verified source and artifact details.
3. Append a dated entry to `CHANGELOG.md`.
4. Update `NEXT_TASKS.md`; mark only evidenced completed items done.
5. Create a handover using `HANDOVER_TEMPLATE.md`.
6. State exactly where work stopped and the single next action.
7. Never write secrets or sensitive customer data into handover docs.
