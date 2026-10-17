# OpenComputerUse — development

Standalone macOS computer-use host extracted from OpenCode Superapp. The name and bundle identifiers are provisional. Licensed under the Apache License 2.0 (see `LICENSE` and `NOTICE`).

## Status

Implemented: native menu-bar host/helper, existing observation/action engine, shared local host, MCP and CLI adapters, concurrent agents (one per app, each with its own engine), stop/pause, permission controls, and standalone build recipe. Native and external-agent acceptance are recorded separately in JOURNAL.md. No public release.

Target: macOS 15+, Apple silicon development builds. Other architectures are unvalidated.

## Development

Requires Xcode command-line tools, Node and pnpm. End-user bundles include their executable runtime.

```sh
pnpm install --frozen-lockfile
pnpm check
pnpm build
```

`pnpm build` produces `dist/OpenComputerUse Dev.app`. Defaults to ad-hoc development signing. Set `OCU_SIGN_IDENTITY` to an available signing identity to test stable identity; this does not notarize or publish the app.

Open the app, grant permissions to its own helper using its explicit permission controls, then use the bundled `Contents/MacOS/ocu` command. The app can install an owned symlink at `~/.local/bin/ocu`.

```sh
ocu status
ocu permissions
ocu apps
ocu observe 'Application Name'
ocu observe 'Application Name' --screenshot
ocu batch 'Application Name' '[{"kind":"click","at":{"x":100,"y":100}}]'
ocu stop
ocu resume
ocu setup claude
ocu mcp
```

Batch coordinates must be grounded in the actual current application; the command observes and acts on the same connection. MCP is preferred for iterative workflows. CLI observe releases when finished. `--screenshot` also captures the app's window and writes it to a private temporary file (or `--screenshot=FILE`); the output names the file instead of embedding the image. `ocu setup claude` prints configuration and does not change existing agent settings.

## Layout

- `apps/macos`: SwiftUI/AppKit menu-bar app.
- `packages/native`: signed helper and capture foundation.
- `packages/engine`: extracted JavaScript broker and target resolver.
- `packages/host`: shared local execution authority.
- `packages/protocol`: versioned framing and canonical tool schemas.
- `packages/cli`, `packages/mcp`: client adapters.
- `upstream`: provenance of the code extracted from OpenCode Superapp.
- `tests`: contract tests and opt-in native fixture.

Read docs/ARCHITECTURE.md for the actual ownership contract and docs/POLICIES.md for the local trust boundary.

## Native acceptance

With explicit authorization to launch and manipulate a synthetic fixture:

```sh
node scripts/test-native.mjs --interactive
node scripts/test-claude.mjs --interactive
node scripts/test-native-selection.mjs --interactive
```

The original native and Claude fixture commands passed against the signed development bundle. They verify the target stayed inactive, foreground/pointer preservation, exact text, and the panel action. Native testing also verifies screenshots and Stop preventing queued typing. The UI itself still needs visual acceptance.

The selection acceptance command creates an owned Finder directory/window and a background AppKit fixture. It checks 19 live cases across Finder icon/list/column views, tables, outlines, grouped collections, tabs, a button and an editor. It verifies actual application selection/state, closes its own windows and leaves evidence under ignored `work/`. It does not activate the target app or generate physical input.

Opt-in observation/lifecycle acceptance: `node scripts/test-native-observation.mjs --interactive` runs owned AppKit fixtures for complete large-tree/multiwindow coverage, selected underline/strikethrough, window closure with/without process exit, uncertain native return, queued-action stopping, permissions during collection, Stop cancellation and a fresh post-Stop observation. Generated data stays under ignored `work/native-observation-*`; no physical/global input or app activation is used. It tests the currently installed development build, so rebuild/restart it first.

Opt-in click/action acceptance: `node scripts/test-native-clicks.mjs --interactive` launches an owned accessory fixture in the background (`open -g`) and checks `list_apps`, double/triple clicks with Cmd+Shift carried on the events, Cmd-click and Shift-click NSTableView selection, the table double action, `perform_action` listing, AXIncrement, a custom action, refusal of an unadvertised action, and AXShowMenu/AXCancel. The fixture records what AppKit received and audits the foreground every 10 ms. Evidence stays under ignored `work/native-clicks-*`.

Opt-in concurrent-agent acceptance: `node scripts/test-native-agents.mjs --interactive` connects two clients to two owned background fixtures. It checks simultaneous observations, refusal of the other agent's app, four rounds of one agent double-clicking with Cmd while the other types (each app receives only its own input, delivery receipts name only its own process), both apps holding their own background activation at once, and releasing one agent restoring only its app. Evidence stays under ignored `work/native-agents-*`.

Opt-in native scroll/file-panel acceptance: `node scripts/test-native-interaction.mjs --interactive` checks native WebKit scroll in four directions, exact offscreen reveal, native URL publication, both filename-edit methods, and a new-folder save through uncertain native returns. It reads actual WebKit scroll offsets and NSSavePanel completion URLs independently of tool receipts. Generated files stay under ignored `work/`; this is OS-contract acceptance, separate from natural-language agent trials. Rebuild/restart the signed development bundle first.
