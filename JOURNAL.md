# Journal

Dated history of what changed and how it was verified. Earlier development took place in a private repository; this public repository starts from its state on 2026-10-16, summarized below. New entries record actual work, verification and remaining uncertainty, and contain no personal application data.

## 2026-10-17 — App icon and agent cursor overlay

- Icon: an Icon Composer document (`assets/icon/OpenComputerUse.icon`) modeled on Airpoint's: dark tile, two blue ripple layers and Phosphor's `navigation-arrow` pointer (MIT, credited in `THIRD_PARTY_NOTICES.md`) clicking at their center. `assets/icon/layers.swift` regenerates the layers; `pnpm build:icon` (Xcode 26 or later) compiles the committed `Assets.car` and `.icns`, which `pnpm build` copies into the app and the helper. Finder shows the icon on both.
- Overlay: engines report each spatial action's window and point to the host; the host publishes the latest cursor per agent (`cursors.json`) and withdraws it on release, cancel, Stop and disconnect; the menu-bar app draws one click-through panel per agent directly above the target window (pointer in the agent's color, name tag, window highlight, click ripple). MCP connections are now named after the agent's MCP client. A **Show agent cursors** switch turns it off.
- Feasibility first: an AppKit panel ordered with `order(.above, relativeTo:)` above another app's window stayed directly above it; when OCU's activation raised the target, one 50 ms re-stack restored the order (280 checks, out of place twice). Pointer input and app-scoped Accessibility hit-testing reached the target through the panel.
- Evidence: `pnpm check` (85 JavaScript, 154 Swift); new `scripts/test-native-overlay.mjs` passed 6 cases (cursor published for the target window and the panel directly above it after a double-click, a row selection and typing; input reached the target; release removed cursor and panel; neither the fixture nor OpenComputerUse came to the front). With the overlay running, `test-native-clicks.mjs` passed 12/12 and `test-native-agents.mjs` all cases. Window captures of the overlay composited on the target show the pointer at each action point (`work/native-overlay-1792261893729`).
- Remaining uncertainty: not yet exercised live with the target on another Space, minimized, in full screen or under Stage Manager; the window highlight uses a fixed 14-point corner radius, which may not match every window style.

## 2026-10-17 — Repository made public

- Outcome: `andrewslabmd/opencomputeruse` is public with only `main` (no tags). Enabled and verified: private vulnerability reporting, secret scanning with push protection, Dependabot alerts and security updates, and protection of `main` against force pushes and deletion. Wiki and Projects are off; topics are set. GitHub detects Apache-2.0 and the community profile is complete.
- Evidence: repository settings read back through the GitHub API after each change; all five Dependabot alerts are fixed.
- Remaining uncertainty: the checks workflow has still not run. GitHub did not start the job because the owner account is locked due to a billing issue (the earlier `startup_failure` runs had the same cause); it runs once the account's billing is resolved. `pnpm check` passes locally.

## 2026-10-17 — Open-source readiness

- Outcome: app identifiers moved to the publisher's domain (`com.andrewslabmd.opencomputeruse.dev`, `.dev.helper`, fixture `.clickfixture`). The README is rewritten for new users: purpose, status, install, connecting an agent, tools, safety and responsible use, limits, development. Added `SECURITY.md` (private reporting through GitHub), `CONTRIBUTING.md` (Developer Certificate of Origin sign-off), the Contributor Covenant 2.1, issue and pull-request templates, Dependabot, and a macOS checks workflow that runs automatically only once the repository is public. The policy and integration notes now state the license and the `list_apps` tool.
- Evidence: `pnpm check` passes (84 JavaScript, 154 Swift); the workflow and template YAML parse; the documentation-structure check passes; the open-source readiness check passes except the code of conduct's contact, since set to hello@andrewslabmd.com; it now passes.
- Live: the renamed build is a new app to macOS, so Accessibility and Screen Recording were granted again (once per identifier change; the old identifier's entries stay in System Settings until removed). On that build `test-native-clicks.mjs` passed 12/12 (AXCancel again left the menu open; Escape closed it) and `test-native-agents.mjs` 10/10.
- Test change: both live tests now fail only when a fixture comes to the front or the foreground guard catches an app jumping forward after OCU input. A user switching apps during a run (recorded by the guard as `user_switch`) is reported instead; one run had failed on exactly that while OCU input reached only the fixtures.
- Dependencies: Dependabot reported three medium advisories (ajv ReDoS with the unused `$data` option, fast-uri host normalization, yaml deep nesting in tests only). Updated ajv 8.18.0, fast-uri 3.1.8 and yaml 2.8.3; `pnpm check` and the live click test pass on the rebuilt app, whose permissions carried over.
- GitHub did not start the checks workflow or Dependabot's own runs while the repository was private (`startup_failure`); the cause, found after it became public, is the account billing lock recorded above.

## 2026-10-16 — Public repository and license

Released under the Apache License 2.0 (`LICENSE`, `NOTICE`). The public history starts here as one commit; the private development history is kept outside this repository.

## Development before the public repository (2026-09-09 to 2026-10-16)

- **Extraction (2026-09):** the computer-use engine, native helper and operator guidance were extracted from OpenCode Superapp into a standalone macOS menu-bar app with a shared local host, MCP and CLI adapters, Stop/Resume and permission controls. Provenance is in `upstream/extraction.json`.
- **Observation (2026-10-11 to 10-13):** complete Accessibility collection without node, child or depth limits, batched attribute reads, compact YAML snapshots, stable native element ids, exact window scoping, selection and text-style state, and change-only snapshots after actions.
- **Native actions (2026-10-12 to 10-13):** target-scoped operations on retained native elements (press, select, text editing with exact selection, scroll, adjustable controls, open, context menus, reveal), with identity, window and geometry validated before each dispatch and uncertain native returns reported rather than repeated.
- **Background focus (2026-10-12 to 10-15):** a synthetic per-process app-state activation, requested only when an action needs it, restored on release, never changing the real foreground app or moving the pointer; a foreground guard puts the user's app back when OCU's own input makes another app jump to the front, and stands down when the user switches apps.
- **Input isolation (2026-10-13):** keyboard and pointer events from a private event source, posted only to the target process and bound to the observed window, with listen-only delivery receipts.
- **Electron and web content (2026-10-14):** Chromium's complete accessibility mode is requested so web presses are delivered; web presses and pointer input are confirmed against the fresh snapshot.
- **Surfaces without controls (2026-10-15):** keystroke text, pointer drag/swipe and long press for canvases, remote and device screens; `observe --screenshot`.
- **Resilience (2026-10-15):** clients reconnect after host restarts without replaying actions; stale hosts no longer block startup.
- **Clicks and actions (2026-10-16):** double/triple clicks and modifier clicks, `perform_action` for any advertised Accessibility action, `list_apps`.
- **Concurrent agents (2026-10-16):** one engine per agent, at most one agent per app, separate observations and background focus per agent.
- **Self-contained (2026-10-16):** the previously bundled third-party automation backend was removed; every observation, capture and action is this project's own code.

Verification at the start of the public history: `pnpm check` passes (84 JavaScript contract tests, 154 Swift tests). The opt-in native acceptance scripts (`scripts/test-native-*.mjs`) passed against a signed development build on macOS, including `test-native-clicks.mjs` (12 cases) and `test-native-agents.mjs` (10 cases). Known limits: AXCancel does not reliably close context menus (Escape does), and agents' native requests are still processed one at a time.
