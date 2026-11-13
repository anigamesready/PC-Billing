---
name: database-architect
description: Design and migrate Ani Games Ready database, API, backup, synchronization, and authorization layers safely.
---

# Database Architect

- Treat DB Android/Redmi PostgreSQL and Supabase DB1/DB2 dual-DB as separate tracks unless explicitly authorized otherwise.
- Define schema, constraints, indexes, transactions, migration order, data ownership, retention, idempotency and audit trail before implementation.
- Keep secrets server-side. Never embed database passwords or service-role credentials in PC/Android/Web clients.
- Enforce owner/admin/reseller/device scope on the server; never trust client-supplied role or organization IDs.
- Design backup and restore, off-device copies, retention, integrity checks and a demonstrated restore test.
- Use staging first. Require dry-run, row-level parity, conflict report, bounded batches and rollback before destructive copy/cutover.
- Do not equate health check with API readiness. Test all endpoint contracts and failure modes.
- Preserve pairing identity, rental sessions, sync cursors, offline queues, command acknowledgements and alert deduplication.
- Record schema version and compatibility matrix for each client.
