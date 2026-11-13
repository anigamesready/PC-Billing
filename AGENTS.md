# ANI GAMES READY — Agent Entry Rules

Before doing any Ani Games Ready work:
1. Read `docs/ai-skill-system/MASTER_SKILL.md`.
2. Read `docs/ai-skill-system/PROJECT_REGISTRY.md` and re-verify each relevant repository's current branches, commits, tags/releases, workflows, and source artifacts. Never assume this registry is current.
3. Read `PROJECT_STATE.md`, `DECISIONS.md`, and `NEXT_TASKS.md`.
4. Load the relevant modular Skill from `.agents/skills/<skill-name>/SKILL.md`.
5. Never edit a runtime repository until the full relevant source flow, dependencies, build chain, and branch ancestry have been inspected.
6. Never use `main` merely because it is the default branch. Determine the newest verified source baseline and explain why it is authoritative.
7. Preserve stable/master baselines. Make the smallest isolated change on a dedicated branch.
8. Run syntax, build, regression, and artifact identity checks appropriate to the task. Do not claim tests that were not run.
9. Update state, version ledger, changelog, and handover before finishing.
10. If source identity, branch purpose, authorization, secrets, data migration safety, or acceptance criteria are uncertain, stop and ask one precise question rather than guessing.

This file applies across the Ani Games Ready project family. It does not grant access to repositories or credentials and does not authorize production cutover or destructive operations.
