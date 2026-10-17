# Contributing

Thanks for your interest in Open Computer Use.

## Before you start

- Open an issue to discuss larger changes before writing them.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues.
- This project follows the [code of conduct](CODE_OF_CONDUCT.md).
- Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
  [docs/POLICIES.md](docs/POLICIES.md) first. Changes must keep actions in the
  background: never move the physical pointer, never bring an app to the front,
  never send global input.

## Development

Requirements: macOS 15 or later, Xcode command-line tools, Node.js and pnpm.

```sh
pnpm install --frozen-lockfile
pnpm check    # headless JavaScript contract tests and Swift tests
pnpm build    # dist/OpenComputerUse Dev.app, signed ad hoc
```

`pnpm check` is safe to run anywhere and must pass for every pull request.

The native acceptance scripts (`scripts/test-native-*.mjs --interactive`)
launch fixture apps and send real input to them. Run them only on a Mac where
that is acceptable, with your current build installed and running, and say in
your pull request which ones you ran and their result.

## Pull requests

- Keep each pull request focused on one change; describe what it changes and
  how you verified it.
- Add or update tests for behavior changes.
- Do not commit personal data: observations, screenshots and logs can contain
  application content. Evidence belongs in the ignored `work/` folder.

## Sign-off (Developer Certificate of Origin)

By contributing you certify the [Developer Certificate of Origin](https://developercertificate.org):
that you wrote the change or otherwise have the right to submit it under the
project's license. Sign off every commit:

```sh
git commit -s
```

This adds a `Signed-off-by: Your Name <you@example.com>` line. Contributions
are licensed under the Apache License 2.0.
