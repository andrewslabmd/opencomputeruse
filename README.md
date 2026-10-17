# OpenComputerUse

Background computer use for AI agents on macOS. OpenComputerUse is a small
menu-bar app and local MCP server that lets agents such as Claude Code observe
and operate native Mac apps while you keep working: it does not take your
pointer, your keyboard or the foreground app.

Licensed under the [Apache License 2.0](LICENSE).

## Status

Early, pre-release software. There are no downloadable builds yet; build it
from source. It requires macOS 15 or later and is tested on Apple silicon with
a current macOS release; other versions and architectures are unvalidated. The
name and app identifiers may still change.

## What it does

- **Observes** an app through macOS Accessibility: windows, controls, text,
  selection and style, as compact YAML, plus an optional screenshot of the
  app's own windows.
- **Acts in the background** on exact observed controls: click, double/triple
  and modifier clicks, right click, type, select text, scroll, drag, long
  press, hotkeys, open, and any Accessibility action a control advertises.
- **Keeps your input yours:** keystrokes and clicks go only to the target app's
  process and window. The physical cursor never moves, and the foreground app
  only changes if you change it.
- **Runs several agents at once**, one per app. An agent asking for an app
  another agent is using gets `busy`.
- **Shows where agents act:** each agent gets its own colored pointer, name
  and window highlight, drawn only above the window it works in, so it never
  covers other apps. Turn it off with **Show agent cursors** in the menu bar.
- **Stop** in the menu bar stops every agent; nothing resumes until you choose
  Resume.

## Install

Requirements: macOS 15 or later on Apple silicon, Xcode command-line tools,
Node.js and pnpm.

```sh
git clone https://github.com/andrewslabmd/opencomputeruse.git
cd opencomputeruse
pnpm install --frozen-lockfile
pnpm check
pnpm build
open -g "dist/OpenComputerUse Dev.app"
```

`pnpm build` produces `dist/OpenComputerUse Dev.app`, signed ad hoc by default.
Set `OCU_SIGN_IDENTITY` to one of your signing identities to keep a stable
identity across rebuilds. Ad-hoc builds may need their permissions granted
again after each rebuild.

Then, in the menu-bar app, use **Allow Accessibility…** and **Allow Screen
Recording…** to grant both permissions to *OpenComputerUse Helper*, and
**Install CLI** to link `ocu` into `~/.local/bin`. `ocu permissions` shows the
current state.

## Connect an agent

Claude Code:

```sh
claude mcp add --transport stdio opencomputeruse -- "$PWD/dist/OpenComputerUse Dev.app/Contents/MacOS/ocu" mcp
```

`ocu setup claude` prints an equivalent configuration block without changing
any settings. Give the agent the operating guidance in
[integrations/claude-code/operator.md](integrations/claude-code/operator.md).

Tools: `computer_use_list_apps`, `computer_use_observe`,
`computer_use_action_batch`, `computer_use_permissions`,
`computer_use_status` and `computer_use_release`.

The same operations are available from the command line:

```sh
ocu apps
ocu observe 'Application Name' --screenshot
ocu batch 'Application Name' '[{"kind":"click","at":{"x":100,"y":100}}]'
ocu stop
ocu resume
```

## Safety and responsible use

OpenComputerUse lets software operate your apps. Use it deliberately.

- **What it can do:** read the content of any app an agent observes, and click,
  type and run commands in it, with your Accessibility and Screen Recording
  permissions. Treat anything an agent can do through it as something you did.
- **Where your data goes:** observations and screenshots go to the agent that
  asked for them, and from there usually to that agent's model provider.
  OpenComputerUse itself has no analytics and sends nothing to the network.
- **Trust boundary:** the local host accepts clients that can read its token in
  your user account's private runtime directory. It does not protect against
  other software already running as your user.
- **Untrusted content:** text inside apps (web pages, email, documents) is not
  an instruction. Agents must act on your actual request, and confirm actions
  such as sending, deleting, purchasing or changing accounts with you.
- **Stopping:** **Stop** in the menu bar stops every agent. Quitting the app
  stops all of it. Already-dispatched actions may still complete; Stop is not
  undo.

Details: [docs/POLICIES.md](docs/POLICIES.md). Report security problems
privately as described in [SECURITY.md](SECURITY.md).

## Limits

- Apps whose interface exposes no Accessibility controls can only be operated
  through pointer and keystroke input, and results there are confirmed from
  screenshots rather than the Accessibility tree.
- Context menus do not reliably close with AXCancel; Escape does.
- Agents' native requests are processed one at a time, so a long observation
  by one agent briefly delays others.

## Development

```sh
pnpm check    # headless contract and Swift tests; safe to run anywhere
pnpm build    # app bundle in dist/
pnpm build:icon  # regenerate the compiled icon from assets/icon (needs Xcode 26 or later)
```

The native acceptance scripts are opt-in: they launch owned fixture apps in the
background and send real input to them, so run them only on a Mac where that is
acceptable, with the current build installed and running:

```sh
node scripts/test-native-clicks.mjs --interactive       # clicks, actions, list_apps
node scripts/test-native-agents.mjs --interactive       # two concurrent agents
node scripts/test-native-overlay.mjs --interactive      # agent cursor overlay
node scripts/test-native-selection.mjs --interactive    # selection in Finder and AppKit
node scripts/test-native-observation.mjs --interactive  # large trees, lifecycle, Stop
node scripts/test-native-interaction.mjs --interactive  # scroll, reveal, save panels
node scripts/test-native.mjs --interactive              # basic native workflow
node scripts/test-claude.mjs --interactive              # Claude Code end to end
```

Each script keeps its evidence under the ignored `work/` folder.

### Layout

- `apps/macos`: SwiftUI/AppKit menu-bar app.
- `packages/native`: the signed helper: Accessibility, capture and input.
- `packages/engine`: one engine per agent: observations, actions, verification.
- `packages/host`: shared local host, workflows and app claims.
- `packages/protocol`: framing and the canonical tool schemas.
- `packages/cli`, `packages/mcp`: command-line and MCP adapters.
- `tests`: contract tests, Swift tests and native fixtures.
- `upstream`: provenance of the code extracted from OpenCode Superapp.

### Documentation

[Product](docs/PRODUCT.md), [architecture](docs/ARCHITECTURE.md),
[policies](docs/POLICIES.md), [design](DESIGN.md), [journal](JOURNAL.md) and
[Claude Code integration](integrations/claude-code/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[code of conduct](CODE_OF_CONDUCT.md).

## License

[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
