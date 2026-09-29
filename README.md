# Proof of concept: Codex Remote Control from an Ubuntu container

## Summary

This proof of concept runs Codex CLI and its Remote Control daemon in an Ubuntu
Docker container, pairs the daemon with a ChatGPT account, and controls Codex
from the ChatGPT mobile app.

The setup was validated on September 29, 2026 with:

- Ubuntu 24.04.5 LTS
- Codex CLI 0.159.1
- Docker Desktop on macOS with an ARM64 Linux container
- ChatGPT on iOS
- a non-root container user named `codex`

The working live container was named `codex-phone-ubuntu-ready`. Its Codex
daemon reported `connected`, and the iOS app could browse the container's home
directory and use `/home/codex/workspace` as a project.

This is an experimental proof of concept, not a production deployment pattern.
The official Remote documentation currently describes mobile setup through a
ChatGPT desktop host on macOS or Windows. The Codex command reference separately
documents `codex remote-control start`, `stop`, and `pair`.

- [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands#codex-remote-control)

## Architecture

No inbound container port is published. The Codex daemon makes an outbound
connection to the Remote Control relay.

```text
ChatGPT mobile app
        |
        | authenticated Remote Control relay
        v
Codex app-server daemon in Ubuntu
        |
        +-- /home/codex/.codex       login, enrollment, daemon state
        +-- /home/codex/workspace    project files
```

## Files

- `Dockerfile` builds Ubuntu with Bubblewrap, Git, Node.js, npm, and a pinned
  Codex CLI release.
- `compose.yaml` starts the container with persistent volumes and the runtime
  security option required by the current iOS folder-discovery flow.

Credentials are created at runtime. They are not embedded in the image.

## Reproduce the proof of concept

### 1. Build and start the container

From this directory:

```bash
docker compose build
docker compose up -d
docker compose exec codex codex --version
```

Expected version:

```text
codex-cli 0.159.1
```

To test a different release without editing the files:

```bash
CODEX_VERSION=0.159.1 docker compose build
```

### 2. Authenticate Codex

Start device authentication:

```bash
docker compose exec codex codex login --device-auth
```

Open the URL shown by the command, enter its one-time code, and complete login
with the ChatGPT account that will be used on the phone. Complete any required
multi-factor authentication. Do not copy `auth.json` into the image or share it
as part of the handoff.

Confirm login:

```bash
docker compose exec codex codex login status
```

### 3. Start Remote Control

Start the managed app-server daemon:

```bash
docker compose exec codex codex remote-control start --json
```

A healthy result includes:

```json
{
  "mode": "daemon",
  "status": "connected",
  "serverName": "codex-phone-ubuntu",
  "timedOut": false
}
```

The real response also contains an environment ID and daemon metadata.

### 4. Pair the phone

Generate a short-lived pairing code:

```bash
docker compose exec codex codex remote-control pair
```

In the ChatGPT mobile app, open Remote, add a connection, and enter the pairing
code. Use the same ChatGPT account and workspace on the CLI and phone.

After pairing, add `/home/codex/workspace` as the project folder.

## The seccomp issue

### Symptom

The container and Remote Control daemon were healthy, but the iOS folder picker
displayed:

```text
Could Not Load Folder
Could not find the remote home folder.
```

The directory existed, `$HOME` was `/home/codex`, and it was owned by the
non-root `codex` user. Changing paths, ownership, the container hostname, and the
Codex configuration did not fix the error.

### What iOS was actually doing

The iOS client was asking app-server to execute the equivalent of:

```sh
cd "$HOME" && pwd -P
```

It submitted that command with an explicit read-only sandbox policy. A
client-supplied `sandboxPolicy` overrides the user's configured default for that
request, so configuring Codex with a less restrictive default did not bypass the
probe's sandbox.

On Linux, Codex implements this sandbox with Bubblewrap. Bubblewrap first asks
the kernel to create a new user namespace, then creates the isolated filesystem,
PID, and network views needed to run the command safely.

### Why it failed in Docker

There were two sandbox layers:

```text
Docker container
  └── default Docker seccomp filter
      └── Codex read-only sandbox
          └── Bubblewrap requests a new user namespace
              └── blocked before the home-directory command can run
```

Seccomp is a Linux kernel syscall filter. Docker's default seccomp policy denied
the namespace-creation operation Bubblewrap needed. Bubblewrap exited before it
ran `pwd`, producing no home-directory path. The iOS app then translated that
failed probe into the misleading message that the home folder could not be
found.

The failure was reproduced directly in the original container:

```bash
codex sandbox -c 'sandbox_mode="read-only"' \
  /bin/sh -lc 'cd "$HOME" && pwd -P'
```

Result:

```text
bwrap: No permissions to create new namespace, likely because the kernel does
not allow non-privileged user namespaces.
```

The message mentions the kernel because Bubblewrap sees an `EPERM` result; in
this case, the outer Docker seccomp policy was the component denying the call.

This matches the diagnosis in
[openai/codex issue #45880](https://github.com/openai/codex/issues/45880).
The Codex source also shows that:

- [`command/exec` accepts a per-request sandbox policy](https://github.com/openai/codex/blob/rust-v0.159.1/codex-rs/app-server-protocol/src/protocol/v2/command_exec.rs#L95-L108).
- [app-server applies that policy instead of the configured default](https://github.com/openai/codex/blob/rust-v0.159.1/codex-rs/app-server/src/request_processors/command_exec_processor.rs#L242-L261).
- [the Linux Bubblewrap path explicitly requests a user namespace](https://github.com/openai/codex/blob/rust-v0.159.1/codex-rs/linux-sandbox/src/bwrap.rs#L371-L376).

### Workaround used by this POC

The container is started with:

```yaml
security_opt:
  - seccomp=unconfined
```

That removes Docker's outer seccomp filter, allowing Bubblewrap to create the
nested namespace. The same probe then succeeds:

```text
/home/codex
```

We tested the controls independently on this Docker Desktop host:

- `seccomp=unconfined` alone: probe succeeded.
- `apparmor=unconfined` alone: probe still failed.
- Therefore, the working handoff relaxes seccomp only; AppArmor remains enabled.

## Validate the running setup

Confirm the exact home-directory probe used during diagnosis:

```bash
docker compose exec codex \
  codex sandbox -c 'sandbox_mode="read-only"' \
  /bin/sh -lc 'cd "$HOME" && pwd -P'
```

Expected output:

```text
/home/codex
```

Confirm the managed daemon:

```bash
docker compose exec codex codex app-server daemon version
```

Confirm Remote Control is connected; `start` is idempotent:

```bash
docker compose exec codex codex remote-control start --json
```

## Security considerations

`seccomp=unconfined` is the largest caveat in this POC. It removes one of
Docker's defense-in-depth layers and exposes the container to a broader set of
Linux syscalls. Codex's inner Bubblewrap sandbox still operates, but it does not
replace the container runtime's outer security boundary.

For this reason:

- Treat this as a development experiment, not a production multi-tenant design.
- Run it on a dedicated or disposable Docker host/VM.
- Mount only the project data the agent actually needs.
- Do not mount the Docker socket, host root filesystem, or unrelated secrets.
- Do not publish app-server directly to a shared or public network.
- Prefer a narrowly tailored seccomp profile that permits the namespace calls
  Bubblewrap needs if this moves beyond a POC.
- Remove the workaround after the iOS client switches to filesystem APIs or
  handles sandbox startup failure correctly.

The named `codex-home` volume contains ChatGPT credentials and Remote Control
enrollment state. Protect it as a secret-bearing volume.

## Troubleshooting

### The phone still cannot find the home folder

Run the validation probe above. If it emits a Bubblewrap namespace error,
inspect the effective Docker security options and host policy. Some Linux hosts
may impose additional AppArmor, SELinux, or unprivileged-user-namespace limits
beyond seccomp.

### Remote Control does not become connected

Check authentication and restart the daemon:

```bash
docker compose exec codex codex login status
docker compose exec codex codex remote-control stop --json
docker compose exec codex codex remote-control start --json
```

Confirm that the phone and CLI use the same ChatGPT account and workspace.

### Pairing fails

Generate a new code because pairing codes expire:

```bash
docker compose exec codex codex remote-control pair
```

### State disappears after rebuilding

Use `docker compose up -d` without deleting the named volumes. Authentication
and daemon state live in `codex-home`; project data lives in `codex-workspace`.

## Stop or remove the POC

Stop the container while retaining credentials and workspace data:

```bash
docker compose down
```

To permanently delete the POC's credentials, enrollment, and workspace data,
remove its named volumes as an explicit cleanup step:

```bash
docker compose down --volumes
```

That final command is destructive and requires a new login and pairing if the
POC is started again.

## Result

The experiment demonstrated that Codex CLI can run as a headless Remote Control
host inside Ubuntu Docker and be driven from the ChatGPT iOS app. The key
container-specific requirement was allowing Bubblewrap's nested user namespace;
on the tested host, relaxing Docker seccomp was sufficient.
