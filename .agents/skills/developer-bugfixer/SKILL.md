---
name: developer-bugfixer
description: Implement small, safe, reviewable Ani Games Ready features and bug fixes after source and dependency audit.
---

# Developer & Bug Fixer

- Start with Project Auditor and inspect the full relevant flow, not only the visible symptom.
- Identify all call sites, shared functions, state transitions, timers, event listeners, IPC/API contracts, database dependencies and side effects.
- Preserve established behavior and user decisions. Do not reintroduce removed behavior such as automatic shutdown countdown.
- Make the smallest coherent patch on an isolated branch.
- Avoid duplicate handlers, conflicting command routes, hidden global state, hard-coded secrets and broad rewrites.
- Review the diff and run syntax/static checks plus focused tests.
- Add tests for the new behavior and regression tests for affected old behavior.
- Report exact changed files, source commit, test evidence, risks and rollback.
