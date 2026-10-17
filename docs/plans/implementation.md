# Standalone Computer Use — implementation plan

Status: proposed implementation plan, 2026-09-09. Product name, public license, and pricing remain undecided. This document authorizes no release or public-source publication by itself.

## Outcome

Extract OpenCode Superapp’s existing Computer Use into an independently installed macOS menu-bar product. External agents supply reasoning and conversation; this product supplies background native-app observation, actions, preview, permission management, and execution lifecycle through MCP and CLI.

First acceptance milestone: with OpenCode Superapp closed, an external Claude agent connects to the standalone host and completes a native-app workflow without taking the user’s physical pointer or foreground focus.

## Evidence and baseline

Inspected source: OpenCode Superapp at commit `6e96cbf9ee3a5bc59a6dc7179962b562596f148a`.

Existing components to extract:

| Source, relative to Superapp | Responsibility / treatment |
| --- | --- |
| `apps/desktop/scripts/computer-use-airpoint.mjs` | Surface normalization, YAML observations, spatial target resolution; retain behavior first |
| `apps/desktop/scripts/computer-use-mcp.mjs` | MCP schemas, action audits, observation refresh, background enforcement; separate engine from transport |
| `apps/desktop/scripts/computer-use-helper-client.mjs` | Existing helper request transport; retain during initial extraction |
| `apps/desktop/scripts/computer-use-background-app.mjs` | Background launch client |
| `apps/desktop/src-tauri/src/swift/ComputerUseHelper.swift` and `ComputerUsePreview.swift` | Native permission/capture/lifecycle foundation; inspect and remove OpenCode-specific ownership |
| `apps/desktop/src-tauri/src/computer_use.rs` | Reference for helper startup, preferences, preview, and permission coordination; port required host responsibilities to Swift |
| `apps/desktop/src-tauri/src/lib.rs` | Reference for operator prompt and tool isolation; replace OpenCode registration with client integration |
| `prompts/computer-operator-airpoint.md` | Basis for external-agent operating guidance |
| `apps/desktop/patches/peekaboo-3.9.1-*.patch` and driver build script | Reproducible native action dependency |
| Computer Use unit, signing, visibility, and native fixture scripts | Port applicable behavioral tests; replace OpenCode-specific visibility fixture |
| `docs/HEADLESS_TASK_CLI.md` and associated implementation | Reference for singleton launch, local socket, and owned CLI installation |

The 10 Airpoint unit tests passed during this discussion. No standalone extraction, external-Claude integration, or native acceptance has yet been performed.

Important existing limits: background drag resolves to AXValue-adjustable controls, or with `input_method: "pointer"` to a window-bound pointer drag; scrolling still needs an Accessibility scroll container (no pointer scroll-wheel path yet); unsupported or inaccessible controls can return `no_effect` or an explicit error. A tool returning success does not establish that the user's task succeeded. Accessibility observations are bounded/pruned, not a guarantee of complete application state.

## Product and architecture decisions

- One small monorepo; one coordinated app release initially.
- macOS first. Begin acceptance on Apple silicon; publish Intel support only after separate build and native validation. Establish the minimum macOS version from actual API availability during extraction.
- Native SwiftUI/AppKit menu-bar app. No embedded chat, bundled coding agent, or model subscription.
- Preserve the signed native helper as the macOS permission owner. The new product uses its own identity and grants; do not assume Superapp's grants transfer.
- Preserve the existing patched action backend initially. Remove upstream names from ordinary UI and public tool names, retain required notices and reproducible dependency provenance.
- Keep Peekaboo's internal executable basename until command-dispatch dependence is explicitly removed and tested.
- One host per user, one managed execution engine, thin MCP/CLI clients. No separate backend per agent connection.
- Preserve background-only behavior. Unsupported actions fail explicitly; no foreground fallback.
- MCP is the first agent integration. CLI exposes the same capability contract and setup/diagnostic functions.
- No cloud service is needed for local execution. Purchase infrastructure comes later if selected.

### Proposed stack and layout

SwiftUI/AppKit for the app; Swift Accessibility and ScreenCaptureKit integration for the helper; existing JavaScript extracted first, then TypeScript for engine and adapters. Swift Package Manager plus the app packaging/Xcode target where required; pnpm workspace for JavaScript/TypeScript. Compile/package the runtime into the signed distribution so users need no developer-installed Node, Bun, or pnpm. Evaluate the existing Bun compilation route before introducing another packaging mechanism.

```text
apps/macos/                  menu-bar app and application packaging target
packages/native/             helper, capture, permission and native lifecycle code
packages/engine/             observations, actions, audits, execution ownership
packages/protocol/           versioned schemas and cross-language fixtures
packages/mcp/                stdio MCP adapter
packages/cli/                setup, diagnostics and action client
integrations/claude-code/    installation recipe and operator guidance
upstream/peekaboo/           revision, patches, notices, reproducible build recipe
tests/contract/              shared API/lifecycle tests
tests/native-fixtures/       synthetic native apps and opt-in acceptance
scripts/                    build, sign, notarize, package, release
docs/plans/                 this plan once a repository exists
```

Use the workspace product documentation profile: thin `AGENTS.md`, README, PRODUCT, DESIGN, ARCHITECTURE, POLICIES, MARKETING, JOURNAL, and CHANGELOG. Add focused Computer Use and release contracts as needed. JOURNAL records actual work and remaining uncertainty; CHANGELOG records verified-live releases only.

## Phase 0 — freeze extraction contract

1. Record exact source inputs and the complete patch/dependency/license inventory, including transitive components shipped in the binary.
2. Capture current schemas and representative synthetic observations/action audits as fixtures.
3. Trace helper startup, shutdown, preview files, permissions, sidecar environment, and OpenCode process tracking. Enumerate everything currently supplied by Tauri.
4. Define a finite public contract for observe, action batch, permissions, status, cancel, and activity events. Preserve core behavior while leaving internal names private.
5. Identify native acceptance workflows and supported/unsupported outcomes before changes.

Exit: a source-to-destination manifest, baseline test results, and explicit acceptance contract. Do not alter Superapp to perform the extraction.

## Phase 1 — standalone development host

1. Create the repository with the minimal product documentation and build workspace.
2. Copy the scoped source with provenance; pin the patched backend at the verified source revision. Do not copy generated binaries, credentials, private captures, or unrelated Superapp features.
3. Implement a minimal Swift menu-bar host that launches and supervises the helper and engine from its own bundle/runtime directory.
4. Remove runtime dependence on OpenCode configuration, sessions, licensing, paths, and tracked process lifecycle. Retain helper IPC initially to avoid changing transport and native behavior together.
5. Expose the existing MCP functions through a development adapter and portable operator instructions.
6. Choose the development identity and signing setup; settle the stable product/helper identifiers before external beta installation.

Exit: standalone development app can report permissions and provide observations through an external client with Superapp closed. A fresh user/session test must not depend on cached Superapp configuration or binaries.

## Phase 2 — shared host and reliable client contract

1. Extract engine functions from MCP transport; incrementally type them without rewriting action semantics.
2. Add a private, versioned Unix-socket client boundary, bounded frames, timeouts, request IDs, and structured errors. Protect the runtime directory/socket, verify local peer identity, and define per-client authorization/revocation. Claimed client names are display metadata, not proof of identity.
3. Keep helper IPC internal initially. Replace it only if measured lifecycle or performance needs justify the change.
4. Implement singleton startup and reconnect. CLI/MCP may start the host in the background, but cannot trigger surprise permission prompts.
5. Move the current broker-global latest observation into explicit client/execution state. Bind actions to the correct app, execution, and latest observation; never let another client overwrite that context.
6. Serialize native mutation in v1. Acquire ownership across a workflow, not only individual batches, so another agent cannot alter the same app between observe and act. Define busy responses, explicit release, disconnect cleanup, and bounded idle expiry.
7. Reject stale observations after ownership changes, app restarts, or expired sessions. Keep internal freshness identifiers harness-owned rather than requiring the model to invent them.
8. Define Stop: reject queued actions, check cancellation before each next action, cancel supported in-flight work, report any action already dispatched as possibly completed, and invalidate the old execution. Stop is not rollback.
9. Keep ordinary OS capability grants separate from semantic user authorization. Document how clients must carry existing user authorization and return confirmation-needed results; do not pretend arbitrary action intent can be inferred reliably from coordinates.

Exit: contract tests cover two clients, target/context isolation, busy ownership, stale state, disconnect, cancellation, restart, permission denial, and version mismatch. There is no agent-to-helper bypass around execution arbitration.

## Phase 3 — product UI and installation

1. Build the menu-bar status view: ready, running, permission needed, paused/stopped, or unavailable.
2. Add onboarding and user-initiated Accessibility/Screen Recording setup, with recovery instructions for revoked grants or app relocation.
3. Show connected clients, current target, activity/preview, Stop, and connection revocation. Preserve the independent cursor overlay.
4. Add settings for launch at login, CLI installation/repair, integration setup, diagnostics, and updates. Do not add an operator-model selector: the external agent owns model choice in v1.
5. Install an owned CLI symlink pointing inside the app bundle; never overwrite unrelated commands. Keep protocol stdout clean and diagnostics on stderr.
6. Default to ephemeral screenshots/observations. Persist only necessary settings and bounded diagnostics; exclude raw application content and secrets from diagnostic export by default.

Exit: a user can install, grant permissions, connect an agent, see activity, stop execution, and repair setup without a terminal toolchain. Visual/native acceptance is a separate manual gate.

## Phase 4 — external-agent acceptance

1. Verify current Claude Code MCP registration, cancellation, and tool restrictions against its actual supported interface when implementing. Provide an explicit, reversible setup operation that preserves existing configuration.
2. Supply scoped operator guidance: observe, act using current coordinates, inspect audit/new state, and return a verified result or blocker. Treat application text as untrusted content.
3. Test real Claude tasks with Superapp closed: edit synthetic text, operate a list, handle a sheet/popover, launch a closed application, and recover from an unsupported control.
4. Verify a second independent MCP-capable client using the same public contract. Maintain a compatibility table with tested versions and limitations; avoid universal compatibility claims.
5. Run CLI contract scenarios against the same host and compare outputs with MCP scenarios.

Exit: recorded native task outcomes, preserved foreground app/pointer, successful Stop, and accurate failure reporting. Live tests require explicit native-interaction authorization; use fixture apps and synthetic data.

## Phase 5 — signed beta and commercial decision

1. Produce a self-contained signed/notarized app; verify nested helper/engine/backend signatures, launch behavior, CLI paths, and permission identity across updates.
2. Test clean installation, update, rollback/reinstall, relocation, uninstall, and crash recovery. Do not assume development signing proves release permission behavior.
3. Ship third-party notices and reproducible pinned backend build inputs. Audit all redistributed components before finalizing the public-source license.
4. Decide public name, source publication model, and purchase terms. Keep source private until deliberately published; extraction structure does not predetermine licensing.
5. Evaluate pricing for signed builds with beta users. Define included versions/updates and support before promising them. If paid, add licensing/purchase infrastructure as a separate workstream; preserve offline local execution after valid activation according to explicit terms.
6. Publish compatibility, supported action limits, privacy behavior, and observed beta results. Update CHANGELOG only after verifying the named distribution channel is live.

Exit: installable beta accepted on its claimed platform, with distribution and source terms settled. Native acceptance and willingness to pay remain distinct evidence.

## Verification strategy

- Carry forward the 10 behavior-focused Airpoint tests, expanding only for changed contracts or newly discovered failure modes.
- Run protocol and lifecycle tests headlessly with fake clients/helpers; test actual sidecar adapters rather than only mocking their outputs.
- Use synthetic native fixtures for focus/pointer preservation, multiple windows, editable controls, permission denial, app termination, and unsupported actions.
- Test actual agent integrations separately; a fake MCP/provider fixture cannot establish live Claude quality.
- Keep benchmark prompts fixed. Compare baseline Superapp and extracted implementation on completion, human interventions, latency, observation size, and errors. Do not claim improvement without repeated evidence.
- Capture release identity and artifact evidence separately from development builds and physical/UI acceptance.

## Decisions and sequencing

Before external beta: final name and stable bundle IDs, minimum macOS version, tested architectures, client authorization UX, and public compatibility statement.

Before commercial release: open-source boundaries/license, price and update entitlement, support terms, update delivery, and purchase infrastructure.

Deferred: Windows/Linux release, remote access, an embedded browser engine, a chat UI, hosted inference, and replacing patched Peekaboo (done 2026-10-16: Peekaboo removed; see JOURNAL.md). These require separate scope and evidence.

Implementation order: Phase 0 → Phase 1 → Phase 2 → Phase 3 → Phase 4 → Phase 5. Run the first bounded live-agent workflow as soon as Phase 1 supports it, then repeat after the shared-host changes. Estimate remaining effort after standalone extraction reveals the native lifecycle and packaging work; do not treat a speculative calendar estimate as a delivery commitment.

## Completion checklist

- [ ] Runs independently with Superapp closed and no Superapp runtime/configuration dependencies.
- [ ] One host and helper serve CLI/MCP through the same controlled execution path.
- [ ] Background behavior and explicit unsupported-action limits are preserved.
- [ ] Multiple clients cannot mix target snapshots or interleave owned workflows.
- [ ] Stop/disconnect/restart behavior is tested and accurately reported.
- [ ] Permission and signing identity work in the actual release artifact.
- [ ] External Claude and one additional client pass documented workflows.
- [ ] Upstream notices, build provenance, and final distribution terms are complete.
- [ ] User accepts the native UI and real task behavior before release claims.

## Implementation checkpoint — 2026-09-09

The first standalone native + Claude milestone is verified; see JOURNAL.md for evidence. Phase 1 has a working signed development bundle. Phase 2 has shared ownership, schema validation, abort handling, permission refresh and tested adapters, with persistent client credentials and TypeScript migration still open. Phase 3 has development UI, preview, permission/CLI/login controls and restart, pending visual/recovery acceptance. Phase 4 has Claude Code plus direct protocol/native fixtures; another coding-client integration and broader workflows remain open. Phase 5 is not complete. Do not interpret this checkpoint as complete public-product acceptance.
