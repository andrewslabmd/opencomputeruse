# Security policy

## Supported versions

OpenComputerUse is pre-release software. Only the latest commit on `main` is
supported.

## Reporting a vulnerability

Please do not open a public issue for a security problem.

Report it privately through GitHub: open this repository's **Security** tab
and choose **Report a vulnerability**. Include what you found, how to
reproduce it, and its impact. If you cannot use GitHub, email
[hello@andrewslabmd.com](mailto:hello@andrewslabmd.com).

This is a small project maintained on a best-effort basis: reports are read and
answered as soon as practical, usually within a couple of weeks, but there is
no guaranteed response time.

## Scope

In scope, for example:

- Input (keystrokes, clicks) reaching an app or window other than the target
  the agent observed.
- An action changing the foreground app or moving the physical pointer.
- A client using the local host without its token, or one agent acting in
  another agent's app or observation.
- Observations, screenshots or logs written where other users can read them.

Out of scope: behavior that requires an attacker who already runs code as your
macOS user (the documented trust boundary), and what an agent decides to do
with the access you gave it. See [docs/POLICIES.md](docs/POLICIES.md).
