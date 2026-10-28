---
name: operate
description: Set up Open Computer Use and operate native Mac apps in the background. Use when asked to click, type, scroll, inspect app windows, or complete a task in a Mac app, or when Open Computer Use is missing or cannot connect.
---

# Open Computer Use

Use this skill before operating Mac apps through Open Computer Use. It requires
a local Mac with macOS 15 or later on Apple silicon. Claude Code must run on
the Mac you want to operate; a Linux or cloud session cannot launch this local
executable.

## Check installation and permissions

1. Use Bash to check the bundled executable without launching it:

   ```sh
   if test -x "/Applications/Open Computer Use.app/Contents/MacOS/ocu"; then
     printf 'Open Computer Use is installed.\n'
   else
     printf 'Open Computer Use is missing from /Applications.\n'
   fi
   ```

2. If it is missing, tell the user to download
   [Open-Computer-Use.dmg](https://github.com/andrewslabmd/opencomputeruse/releases/latest/download/Open-Computer-Use.dmg),
   open it, drag **Open Computer Use** to **Applications**, and open the app.
   It lives in the menu bar. This plugin expects that exact installation path.
   Do not download or install software on the user's behalf without their
   authorization. Stop here until the app is installed.

3. Read the complete [operating instructions](operator.md) bundled beside this
   skill before calling any computer-use tools. Follow them throughout the task.

4. Use the plugin's `computer_use_permissions` tool to read permission status.
   If it is unavailable, follow the connection recovery in step 5.
   If Accessibility or Screen Recording is missing, tell the user to click the
   app's menu-bar icon, choose **Review…**, then **Allow…** for each permission,
   and enable **Open Computer Use** in System Settings. Accessibility lets it
   read and operate app controls; Screen Recording lets it capture the target
   app's window. If already enabled but still reported as denied, choose
   **Fix** next to the permission and enable it again. If macOS asks to quit
   and reopen, follow that prompt; open the app again if needed. The user
   grants these permissions; the tools only report their state.

5. The plugin already declares the MCP server; do not run `ocu setup claude`,
   `claude mcp add`, or the app's **Connect** button to add a second copy.
   If tools are unavailable (including after installing the missing app), tell
   the user to open the app and restart Claude Code, then inspect `/mcp` for
   `plugin:opencomputeruse:opencomputeruse`. If it still fails, report the
   connection error and stop; do not alter their client configuration.

## Operate

Apply the bundled operating instructions to the user's request. Plugin MCP
tools have the prefix `mcp__plugin_opencomputeruse_opencomputeruse__`, for
example `mcp__plugin_opencomputeruse_opencomputeruse__computer_use_observe`.
Use the tools actually exposed by the client rather than a second manually
configured server.

Keep normal Read and Bash tools available to retrieve complete observations
when Claude Code saves large results to files. Use computer-use tools for UI
actions. Release the workflow when finished and report the verified outcome or
the exact blocker.
