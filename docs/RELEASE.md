# Release

Open Computer Use is distributed free, outside the Mac App Store, as a
notarized disk image on GitHub Releases, and updates itself with Sparkle.
Releases are made from the maintainer's Mac; CI is not involved.

| What | Value |
| --- | --- |
| Identifiers | `com.andrewslabmd.opencomputeruse`, helper `….helper`; development builds add `.dev` |
| Signing | Developer ID Application: MedHue Labs LLC (PGD5DTY3CY), hardened runtime, timestamped |
| Notarization | App Store Connect API key in the `medhuelabs-notary` notarytool profile, shared by the team's apps |
| Updates | Sparkle 2.9.4, EdDSA key in the login Keychain (account `opencomputeruse`), checks daily, installs only when the user agrees |
| Update feed | `https://github.com/andrewslabmd/opencomputeruse/releases/latest/download/appcast.xml` |
| Download | `https://github.com/andrewslabmd/opencomputeruse/releases/latest/download/Open-Computer-Use.dmg` |
| Versions | `package.json` x.y.z; build number x×10000 + y×100 + z |

These values live in `scripts/release-config.json`. The feed URL and public key
are built into every release, so changing either strands installed copies.

## One-time setup on the release Mac

1. The Developer ID certificate is in the login Keychain
   (`security find-identity -v -p codesigning`).
2. Create the notary profile from the team's App Store Connect API key (the
   same key CTRL Micro uses). This reads the key's location from CTRL Micro's
   release Keychain items and stores a profile notarytool validates:

   ```sh
   xcrun notarytool store-credentials medhuelabs-notary \
     --key "$(security find-generic-password -s com.medhue.ctrlmicro.release -a apple-api-key-path -w)" \
     --key-id "$(security find-generic-password -s com.medhue.ctrlmicro.release -a apple-api-key-id -w)" \
     --issuer "$(security find-generic-password -s com.medhue.ctrlmicro.release -a apple-api-issuer -w)"
   ```

3. Back up the Sparkle private key to the password manager. Without it no
   installed copy can be updated again. Export it to a file, store it, then
   delete the file:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account opencomputeruse -x ocu-sparkle.key
   ```

## First public release

0.1.0 was published on 2026-10-19 with these gates:

- [x] Bundled dependency notices: the Bun runtime inside `ocu`, `ocu-host` and
      `ocu-engine` and its transitive licenses are inventoried in
      `BUN_RUNTIME_NOTICES.md`, with links to the LGPL/MPL source and relinking
      steps (`OCU_BUN`). Upgrading Bun means redoing that inventory.
- [x] Release identity and permission persistence, by identity: the app and
      helper designated requirements are the bundle identifier plus the
      Developer ID team, with no version or code hash, and were identical
      between 0.1.0 and a 0.1.1 test build. A live grant, then a Sparkle update,
      is still to be seen with 0.1.1.
- [ ] Native acceptance of the release build: deferred by Mario for 0.1.0; the
      development build carries the native acceptance so far.
- [x] README Install section points to the download.

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
