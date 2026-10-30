# Open Computer Use for Claude Code

Use Mac apps in the background without taking over your mouse or keyboard.
This plugin connects Claude Code to the Open Computer Use menu-bar app and
includes setup help and its operating instructions. Plugin version: **0.1.3**.
Requires a local Mac with macOS 15 or later on Apple silicon.

## Install

In Claude Code:

```text
/plugin marketplace add andrewslabmd/opencomputeruse
/plugin install opencomputeruse@opencomputeruse
```

Restart Claude Code, then run `/opencomputeruse:operate`. The skill checks for
the app and guides setup if needed. You can also start by downloading
[Open-Computer-Use.dmg](https://github.com/andrewslabmd/opencomputeruse/releases/latest/download/Open-Computer-Use.dmg),
dragging **Open Computer Use** to **Applications**, and opening it. In its
menu bar, choose **Review… → Allow…** for Accessibility and Screen Recording,
then enable **Open Computer Use** in System Settings. If a grant is already
enabled but still denied, choose **Fix** and enable it again.

The plugin launches this stdio server automatically:

```sh
"/Applications/Open Computer Use.app/Contents/MacOS/ocu" mcp
```

If the app was missing when the plugin started, install and open it, then
restart Claude Code. Check `/mcp` for `plugin:opencomputeruse:opencomputeruse`.
Use either this plugin or the app's **Connect** button for Claude Code; both
launch the same server, so configuring both exposes duplicate tool sets. If
you already connected through the app, review that existing connection before
switching; the plugin does not remove it for you.

Ask for a Mac app task, or invoke `/opencomputeruse:operate` explicitly to
load the guidance. Skills load when invoked; enabling the MCP server alone
does not load the full operating instructions. The app's permissions allow
local UI access; observations and requested screenshots go to Claude Code
and its configured model provider. The operating guide preserves the user's
authorization and asks before sharing bug reports.

## Local review and maintenance

From the repository root, validate without installing:

```sh
claude plugin validate --strict integrations/claude-code/plugin
claude plugin validate --strict --profile directory integrations/claude-code/plugin
claude plugin validate --strict .claude-plugin/marketplace.json
claude plugin validate --strict integrations/claude-code/plugin/skills
```

For a later local installation, use `/plugin marketplace add /absolute/path/to/opencomputeruse`
instead of the GitHub command above. The repository-root
`.claude-plugin/marketplace.json` points to this plugin directory; only files
inside this directory are bundled with the plugin.

Keep the plugin and marketplace versions aligned with `package.json`.
`skills/operate/operator.md` is an exact copy of
`integrations/claude-code/operator.md`; update it whenever the canonical guide
changes. It must be bundled because installed plugins cannot read files
outside their cached directory. Check synchronization from the repository root:

```sh
cmp integrations/claude-code/operator.md integrations/claude-code/plugin/skills/operate/operator.md
```

`assets/icon.png` is the existing README app icon resampled to 512 px for the
directory's minimum image size.

Packaging follows Claude Code's official docs for
[plugins](https://code.claude.com/docs/en/plugins),
[manifests](https://code.claude.com/docs/en/plugins-reference),
[marketplaces](https://code.claude.com/docs/en/plugin-marketplaces),
[MCP in plugins](https://code.claude.com/docs/en/mcp#plugin-provided-mcp-servers),
and [skills](https://code.claude.com/docs/en/skills).
