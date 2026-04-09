# Cookie Log

Append-only behavior feedback ledger.

## Entry format
- `- YYYY-MM-DD | type=<cookie|zuchinii> | reason=<brief reason> | context=<optional>`

## Entries
- 2026-03-13 | type=zuchinii | reason=Missed directive chain from self-check into brainstorm branch workflow and held brainstorm context in memory instead of following branch behavior. | context=.harbormaster/.context/DIRECTIVES.md -> .harbormaster/branches/brainstorm-session.branch
  fix_report: Verified the chain was actually broken. `.harbormaster/.context/DIRECTIVES.md` referenced missing `.mod` files instead of the real branch workflow files. Repaired the chain to `AGENTS.md -> .harbormaster/.context/DIRECTIVES.md -> .harbormaster/branches/brainstorm-session.branch` and replaced the broken module references with explicit branch-file links.
