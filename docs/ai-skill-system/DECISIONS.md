# Decisions Register

| ID | Decision | Reason / enforcement |
|---|---|---|
| D-001 | Always inspect the newest verified repository/source/artifact before edits or builds. | Prevent wrong/old APK, ZIP, or branch selection. |
| D-002 | Never assume `main` is the newest source. | Active release/feature/DB Android branches may be ahead. |
| D-003 | Preserve master/stable baselines; work on isolated branches. | Avoid breaking billing, Admin, reseller, and production flows. |
| D-004 | Make the smallest necessary change after full dependency/flow audit. | Reduce regressions and repeated revisions. |
| D-005 | Regression-test old features and new integration before delivery. | A new feature is incomplete if existing behavior breaks. |
| D-006 | DB Android is separate from Supabase dual-DB development and production routing. | Prevent accidental DB target changes or mixed assumptions. |
| D-007 | PC Billing, Admin, and Reseller have separate source branches and build pipelines. | Prevent cross-product source/artifact mix-ups. |
| D-008 | A health endpoint does not prove API parity, authentication, data integrity, or readiness. | Require endpoint and acceptance-test coverage. |
| D-009 | Never place privileged secrets in client code or repository docs. | Security and credential protection. |
| D-010 | Fresh install/replace testing is required for installable updates when practical. | Validate real user upgrade path. |
| D-011 | Do not reintroduce automatic shutdown countdown. | Shutdown is manual/admin intent; avoid accidental power-off. |
| D-012 | Reseller remains isolated to its own rental records and cannot control PCs/Windows/WoL. | Least privilege and product role separation. |
| D-013 | Finish every task with state, changelog, version ledger and handover. | Work must survive chat loss or interruption. |

Changes to these decisions require an explicit user instruction and a dated explanation; do not silently overwrite them.
