# Agents

## Context

- Product: `docs/PRODUCT.md`
- Runtime and ownership: `docs/ARCHITECTURE.md`
- Privacy and authorization: `docs/POLICIES.md`
- UI: `DESIGN.md`
- Build and checks: `README.md`
- Remaining work: `docs/plans/implementation.md`

## Rules

- This repository owns the standalone product. Do not modify OpenCode Superapp as part of extraction.
- Preserve background-only native actions and one shared host per user.
- Normal checks are headless. Native fixture actions require explicit user authorization.
- Keep generated binaries, credentials, captures, and personal application data out of Git.
- Do not label builds or protocol tests as native acceptance or public release.
