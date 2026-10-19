# Agents

## Context

- Product: `docs/PRODUCT.md`
- Runtime and ownership: `docs/ARCHITECTURE.md`
- Privacy and authorization: `docs/POLICIES.md`
- UI: `DESIGN.md`
- Build and checks: `README.md`
- Release: `docs/RELEASE.md`
- Remaining work: `docs/plans/implementation.md`
- Reports: `report_issue` saves locally, asks the user once, and sends only
  after yes to the maintainers' private inbox for triage. GitHub issue templates
  remain for people who want to file publicly. No in-app form or error tracking.
- Working journal: `JOURNAL.md`, kept only on the maintainer's Mac and ignored by Git. Record work and verification there, never in public files.

## Rules

- This repository owns the standalone product. Do not modify OpenCode Superapp as part of extraction.
- Preserve background-only native actions and one shared host per user.
- Normal checks are headless. Native fixture actions require explicit user authorization.
- Keep generated binaries, credentials, captures, and personal application data out of Git.
- Do not label builds or protocol tests as native acceptance or public release.
