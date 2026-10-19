# Agents

## Context

- Product: `docs/PRODUCT.md`
- Runtime and ownership: `docs/ARCHITECTURE.md`
- Privacy and authorization: `docs/POLICIES.md`
- UI: `DESIGN.md`
- Build and checks: `README.md`
- Release: `docs/RELEASE.md`
- Remaining work: `docs/plans/implementation.md`
- Working journal: `JOURNAL.md`, kept only on the maintainer's Mac and ignored by Git. Record work and verification there, never in public files.

## Rules

- This repository owns the standalone product. Do not modify OpenCode Superapp as part of extraction.
- Preserve background-only native actions and one shared host per user.
- Normal checks are headless. Native fixture actions require explicit user authorization.
- Keep generated binaries, credentials, captures, and personal application data out of Git.
- Do not label builds or protocol tests as native acceptance or public release.
