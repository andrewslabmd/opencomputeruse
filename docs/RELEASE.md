# Release

Open Computer Use is distributed free, outside the Mac App Store, as a
notarized disk image on GitHub Releases, and updates itself with Sparkle.
Releases are made from the maintainer's Mac; CI is not involved.

| What | Value |
| --- | --- |
| Identifiers | `com.andrewslabmd.opencomputeruse`, helper `….helper`; development builds add `.dev` |
| Signing | Developer ID, hardened runtime, timestamped, notarized |
| Updates | Sparkle 2.9.4 with an EdDSA key, checks daily, installs only when the user agrees |
| Update feed | `https://github.com/andrewslabmd/opencomputeruse/releases/latest/download/appcast.xml` |
| Download | `https://github.com/andrewslabmd/opencomputeruse/releases/latest/download/Open-Computer-Use.dmg` |
| Versions | `package.json` x.y.z; build number x×10000 + y×100 + z |

These values live in `scripts/release-config.json`. The feed URL and public key
are built into every release, so changing either strands installed copies.
Releasing needs the Developer ID certificate, a notarytool profile and the
Sparkle private key on the release Mac. Upgrading Bun means redoing the
inventory in `BUN_RUNTIME_NOTICES.md`.

## Each release

1. Write `docs/releases/vX.Y.Z.md`: short, user-facing, a list of changes.
   It becomes the GitHub release notes and what Sparkle shows.
2. Commit everything on `main`, then run `pnpm release:prepare X.Y.Z`. It
   refuses to start unless `main` is clean, the tag is unused and the
   certificate, notary profile and Sparkle key are present. It sets the
   version in `package.json` (left uncommitted), runs `pnpm check`, builds the
   release app, notarizes and staples the app and the disk image, checks both
   with Gatekeeper, and writes `release-artifacts/vX.Y.Z/` (disk image, signed
   `appcast.xml`, `SHA256SUMS`, `release.json`). A failure undoes the version
   change and removes the partial folder.
3. Install the disk image from that folder and test it: open it from
   `/Applications`, grant permissions, connect an agent, and from the previous
   release, use Check for Updates.
4. Run `pnpm release:publish X.Y.Z` to see the plan, then again with
   `--confirm`. It checks the files against `SHA256SUMS` and that `main` is
   still at the prepared commit, commits the version as `Release vX.Y.Z`, tags
   and pushes `main` and the tag, creates the GitHub release with the versioned
   and stable-named disk images, `appcast.xml` and `SHA256SUMS`, and checks
   that the public feed and download serve them.
5. Add the CHANGELOG entry once the release is live.

A version is never reused or overwritten. Fix a bad release with a higher
version. To stop new installs and updates from reaching a bad release before
then, make the previous release GitHub's latest again
(`gh release edit vPREVIOUS --latest`); the feed and download follow it.
Installed copies never move to a lower build.

Pre-releases are not published as GitHub pre-releases: `latest` skips them,
so the feed would not offer them.
