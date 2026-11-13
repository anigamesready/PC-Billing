---
name: project-auditor
description: Audit Ani Games Ready repositories, source lineage, dependencies, workflows, and release artifacts before any code edit or build.
---

# Project Auditor

1. Identify product and exact repository; search installed repositories if identity is uncertain.
2. Read repository metadata, default branch, relevant branches, recent commits, tags/releases, workflows and recursive trees.
3. Determine authoritative source using full commit SHA and ancestry, not branch labels or timestamps alone.
4. Inspect source archives, their hashes, extraction layout, ordered patch scripts and build workflow.
5. Inspect caller/callee relationships, APIs/RPCs, database tables, environment variables and cross-product dependencies.
6. Compare candidate branches and document why one is selected.
7. Flag stale main branches, old ZIPs/APKs, mismatched workflows, missing secrets, unsupported build triggers and unverified artifacts.
8. Produce an audit report with exact refs, findings, risks, and a minimal implementation plan.
9. Do not edit runtime files until audit is complete and ambiguity is resolved.
