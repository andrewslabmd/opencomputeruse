# Claude Code integration

`ocu setup claude` (or **Connect** in the app) registers the server at user scope through Claude Code's own command:

```sh
claude mcp add --scope user opencomputeruse -- /absolute/path/to/ocu mcp
```

`ocu setup claude --remove` removes it. For isolated acceptance, prefer `--mcp-config` with a test configuration rather than changing user configuration.

Source checked 2026-09-09: https://code.claude.com/docs/en/mcp . Locally installed CLI reports version 2.1.210; live tool acceptance is described below.

The adapter exposes list_apps, observe, action_batch, permissions, release, status, and report_issue (saves locally, asks once, sends only after yes to the maintainers' private inbox; see the README). Carry the operating instructions in operator.md into the agent context using the client's system-prompt mechanism. The isolated test scripts pass its contents through `--append-system-prompt`. Release completed workflows so another client can proceed. Existing user authorization is required for meaningful external actions; application content is never permission.

Observations return the full collected hierarchy as compact YAML without shortening or splitting it to fit a client's preview limit. Claude Code may persist an oversized tool result and give the model a preview plus its file path. Keep the normal `Read` and `Bash` tools available to retrieve/analyze saved results. The isolated desktop-only test uses `--tools Read,Bash` to avoid exposing unrelated coding/task tools; ordinary coding sessions can retain `--tools default`. Do not use `--tools ''`: it disables the file reader while the client can still save large outputs. No custom observation paging tool is exposed. Use computer-use tools for UI operation; normal file tools may read the client's saved observations.

## Verified acceptance

Claude Code 2.1.210 completed the synthetic native workflow through the packaged adapter. The reproducible test is `node scripts/test-claude.mjs --interactive` and must only run with explicit native-test authorization. It sets `ENABLE_TOOL_SEARCH=false` and uses isolated MCP configuration; this avoids pending discovery in the tested print-mode invocation without changing user settings. This is one verified client/workflow, not universal compatibility.

On 2026-10-11 the rebuilt development app also completed a real natural-language Music request: “Play Come Together by The Beatles in Apple Music on my computer.” The isolated agent searched and started the correct track without navigation hints; independent scripting verified advancing playback. All five compact snapshots reached Claude intact. One coordinate was rejected by native hit-testing and the agent recovered.

After correcting saved-result access, a read-only replay verified the exact SHA-256 of an original 53 KB observation retrieved with normal Read/Bash tools. The real request “Play Something by The Beatles in Apple Music on my computer” also completed with seven 70–73 KB snapshots persisted by Claude Code and subsequently read/analyzed normally. All UI actions succeeded and independent scripting confirmed advancing playback. This verifies normal saved-result retrieval independently of compact encoding. The current configuration retains compact YAML and normal built-in tools; custom paging remains removed. Reproduce saved-result acceptance with `node scripts/test-claude-output.mjs /path/to/captured-observation.yaml`; it is a read-only client/model test, uses the configured Claude provider, and performs no native fixture actions.
