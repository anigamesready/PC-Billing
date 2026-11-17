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

## Additional mandatory checks — Termux/Bash and repeat-defect prevention

- When a defect was introduced by a prior assistant-provided patch/package, stop repeating the same instructions. Record the exact observed failure and add a prevention rule before continuing.
- For every Termux shell script, validate both bash -n and runtime execution of the affected path under Bash. Syntax-only checks do not catch every expansion-time failure (for example, \${#VAR:-0} produces bad substitution).
- Test variables in unset, empty, valid-placeholder and invalid-short states using disposable fixtures. Do not print secret values; assert only presence/length/status.
- For a length check, normalize a default first (for example, value="\${VAR:-}") and then measure \${#value}; do not combine length expansion with :-.
- Before packaging, inspect the exact installer, start, stop, status and agent files in the artifact; test the actual install layout and command paths, not a separate copy with different paths.
- Preserve established credentials. Reuse the existing ANI_EDGE_PROXY_SECRET from the stage .env; never generate/replace it just to repair agent startup. Configure Worker RELAY_SHARED_SECRET from that same value only when required, and do not add a duplicate binding when it already exists.
- Before telling the user to change Cloudflare settings, distinguish an absent binding, a duplicate-name Add attempt, a secret mismatch (agent handshake unauthorized), and an agent process that never started. Require evidence for the relevant case.
- Do not mark a package ready based only on archive checksum or syntax checks. Require runtime smoke tests, secret-redaction scans, install simulation, and a truthful device-test status.
