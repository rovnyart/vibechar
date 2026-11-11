# Secret Drop

Accepted implementation scope, 2026-11-12. First delivery is local, for Mac and
terminal; no provider account or per-secret MCP setup is required.

## User workflow

- Paste Secret for Agent creates a private scratch from the system clipboard,
  opens access and copies a ready-to-send instruction in one action.
- Copy for Agent shares an existing nonempty private scratch without naming it.
- Paste the instruction into a local agent chat. It contains an opaque reference
  and executable path, never the private value.
- The agent runs `vibechar run <reference> --env API_TOKEN -- <program> [args...]`.
  The helper injects the value into the child environment and preserves exit status.
- The editor shows open access and use count, with an explicit Stop action.

## Contract

- Explicit export from one private buffer, chosen before collection. No enumeration
  or automatic exposure of other buffers. One raw UTF-8 value per reference.
- References use independent random routing and access tokens. The holder on the
  same OS user account may reuse access for multiple commands. This is not verified
  identity of a particular chat or model. Treat the reference as an access pass.
- A real edit, undo/redo, tab close, Stop, or editor exit revokes future requests.
  Grants expire after 30 minutes without a successful use. Metadata polling does
  not extend access. The Mac GUI also listens for screen lock, sleep and session
  resignation to revoke all its grants; actual OS-event delivery needs qualification.
  The terminal has no lock/sleep hooks in this increment.
- Local Unix sockets only, owner-only runtime directory/socket, checked peer UID,
  bounded requests and timeouts. No TCP listener, secret files or grant registry.
- The editor serves values only; it cannot execute requested commands. The CLI
  starts the command in the agent's existing execution environment and permissions.
- Values never enter CLI arguments or helper error messages. Literal occurrences
  are masked in child stdout/stderr, including matches split across read chunks.
  A trusted command still receives the actual value and can retain, transform or
  transmit it; this is not isolation from agent-generated code. Already delivered
  values cannot be retrieved by revoking a reference.
- Nonempty UTF-8 up to 64 KiB, excluding NUL, for the environment-variable path.
  No dotenv inference, direct plaintext-read command, network relay or MCP server
  in this increment. Clipboard access is explicit; no background monitoring.
- App-owned recovery continues excluding private text and all grant data. The
  existing private-mode limits around OS memory, clipboard history and explicit
  exports remain. Terminal access is on the terminal host, not implicitly the Mac
  at the other end of SSH. Cloud/remote agents cannot use this local reference.

## Controls and delivery

| Action | Mac | Terminal |
| --- | --- | --- |
| Paste Secret for Agent | Agent menu, Option+Cmd+V | F8 |
| Copy for Agent | Give to Agent / Copy Again, Shift+Cmd+C | Ctrl+G / F7 |
| Close current access | Stop, Agent menu | F9 closes all |
| Close all access in this editor | Agent menu | F9 |

The Mac bundle includes `Contents/Helpers/vibechar`. Instructions use its quoted
absolute path, so no PATH installation is necessary. Terminal instructions use the
running executable's absolute path. Both clients can serve a local command through
either helper; their document/recovery sessions remain separate. Keep the source
editor open. Repeated Copy for Agent reuses a live reference without renewing its
idle timeout; copying after expiry creates a fresh one.

Clipboard support uses AppKit on Mac GUI and pbcopy/pbpaste in the macOS terminal.
Linux TUI selects wl-copy/wl-paste under Wayland or xclip under X11; these tools
must be installed. Missing clipboard support reports an error and closes a grant
if instruction copying fails. Manual bracketed paste into a private tab is also
supported; copying an instruction still needs a clipboard provider.

The local runtime is `/tmp/vibechar-drop-<uid>/`, containing socket files only.
Hosts create random endpoints lazily, remove their socket on normal exit, and hold
values and grant records only in memory. A forced kill can leave a stale socket
file, which serves nothing; random instance IDs prevent its reuse on restart.
For isolated tests or custom local environments, `VIBECHAR_HANDOFF_DIR` changes
that directory for both editor and helper. It must be owned by the user and have
no group/other permissions. `VIBECHAR_COPY_COMMAND` / `VIBECHAR_PASTE_COMMAND` select
clipboard provider executables (paths only, no shell evaluation). The copy provider
receives the instruction on stdin; the paste provider emits text on stdout.

Neither a reference nor an environment variable proves an agent's identity or
enforces how its code uses a secret. Only share with a trusted task. Closing access
prevents later fetches; a command which already fetched the value can continue.

## Delivery and acceptance

- [x] Shared in-memory broker and automatic document revocation.
- [x] CLI run, output masking and child exit-status preservation.
- [x] Mac commands, visible status, Stop, clipboard fast path and lock/sleep hooks.
- [x] Terminal equivalents and explicit clipboard integration.
- [x] Tests: exact child injection, reuse, revoked/wrong/expired references, edits,
  close/quit, no recovery bytes, output masking, CLI failure before child execution.
- [x] Native and real PTY end-to-end checks with disposable fixtures only.
- [ ] Actual OS lock/sleep behavior and Linux runtime acceptance.
- [ ] Local commit and Art's hands-on feedback before the next feature.
