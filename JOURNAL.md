# Journal

Dated history of what changed and how it was verified. Earlier development took place in a private repository; this public repository starts from its state on 2026-10-16, summarized below. New entries record actual work, verification and remaining uncertainty, and contain no personal application data.

## 2026-10-17 — Open-source readiness

- Outcome: app identifiers moved to the publisher's domain (`com.andrewslabmd.opencomputeruse.dev`, `.dev.helper`, fixture `.clickfixture`). The README is rewritten for new users: purpose, status, install, connecting an agent, tools, safety and responsible use, limits, development. Added `SECURITY.md` (private reporting through GitHub), `CONTRIBUTING.md` (Developer Certificate of Origin sign-off), the Contributor Covenant 2.1, issue and pull-request templates, Dependabot, and a macOS checks workflow that runs automatically only once the repository is public. The policy and integration notes now state the license and the `list_apps` tool.
- Evidence: `pnpm check` passes (84 JavaScript, 154 Swift); the workflow and template YAML parse; the documentation-structure check passes; the open-source readiness check passes except the code of conduct's contact, since set to hello@andrewslabmd.com; it now passes.
- Live: the renamed build is a new app to macOS, so Accessibility and Screen Recording were granted again (once per identifier change; the old identifier's entries stay in System Settings until removed). On that build `test-native-clicks.mjs` passed 12/12 (AXCancel again left the menu open; Escape closed it) and `test-native-agents.mjs` 10/10.
- Test change: both live tests now fail only when a fixture comes to the front or the foreground guard catches an app jumping forward after OCU input. A user switching apps during a run (recorded by the guard as `user_switch`) is reported instead; one run had failed on exactly that while OCU input reached only the fixtures.
- Dependencies: Dependabot reported three medium advisories (ajv ReDoS with the unused `$data` option, fast-uri host normalization, yaml deep nesting in tests only). Updated ajv 8.18.0, fast-uri 3.1.8 and yaml 2.8.3; `pnpm check` and the live click test pass on the rebuilt app, whose permissions carried over.
- Remaining uncertainty: GitHub did not start the checks workflow or Dependabot's own runs on the private repository (`startup_failure`, no jobs created, Actions enabled for the repository); the reason is not visible through the API. The workflow has not yet run on GitHub's macOS image.

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
