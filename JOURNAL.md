# Journal

Dated history of what changed and how it was verified. Earlier development took place in a private repository; this public repository starts from its state on 2026-10-16, summarized below. New entries record actual work, verification and remaining uncertainty, and contain no personal application data.

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
