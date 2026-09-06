# nix-signal-send

`signal-send` is a Bash compatibility wrapper around nixpkgs' `signal-cli`.
The flake declares `nixpkgs-unstable`; consumers should make its `nixpkgs` input
follow their existing unstable input. There is no custom signal-cli build.

## Migration from Presage

The new backend needs its own linked-device registration and group selection.
Presage's SQLite database and hex group master keys cannot be used as signal-cli
account state or base64 group IDs. The wrapper leaves the old files intact.
It does not silently fall back to them or migrate protocol sessions.

After installing the updated package, run as the sending user:

```bash
signal-send setup-device
SIGNAL_SEND_PROJECT=my-project signal-send setup-project
```

Scan the QR code with Signal on the primary phone under Settings → Linked
devices. Setup links a secondary device; it never registers or replaces the
primary account. An existing local signal-cli account makes setup idempotent,
but local account presence does not prove that the phone still trusts it.
If the linked-device limit is reached, review devices on the phone yourself.

Select each project's destination again from the numbered group list. Group
IDs come from `signal-cli --output json listGroups`; the wrapper never parses
human-readable group listings. Names containing newlines or tabs remain one
menu entry. Only groups where the account is a member and is not blocking the
group are offered.

State defaults to:

```text
~/.local/state/signal-send/
  signal-cli/                  # new linked-device state
  projects/<project>/group_id  # new base64 target
  cli.db3                      # existing Presage state, left untouched
  projects/<project>/group_master_key  # existing target, left untouched
```

Keep mutable device state outside Git and the Nix store. The dedicated directory
is intended for exactly one account per sender user/host.

## Commands and environment

```bash
signal-send setup
signal-send setup-device
signal-send setup-project
signal-send sync
signal-send status
signal-send projects
signal-send groups
signal-send select-group
signal-send discover-group
signal-send 'hello'
printf '%s\n' 'hello from stdin' | signal-send
signal-send --attach /tmp/report.md 'report attached'
```

`setup` combines device and project setup. `link` links only the device.
`reset-sessions` returns an explicit unsupported-operation error: the old
Presage-local reset has no equivalent here and is not emulated with a destructive
account operation.

The project comes from `SIGNAL_SEND_PROJECT`, then the nearest Git root basename,
then the working-directory basename. `SIGNAL_SEND_STATE_DIR` overrides the state
root; `SIGNAL_SEND_DEVICE_NAME` overrides the linked-device name.
`SIGNAL_SEND_DISCOVER_TIMEOUT` defaults to 120 seconds.

`SIGNAL_SEND_GROUP_KEY_FILE` retains its existing spelling for service callers,
but its content must now be a signal-cli base64 group ID. A Presage hex key is
rejected. `SIGNAL_SEND_DB` is rejected with migration instructions.

Sends invoke `signal-cli send` directly and preserve its failure status. They do
not request sync or receive first. `sync` separately requests contact/group data
from the primary device and receives pending messages with a five-second idle
timeout. Incoming message bodies are discarded from sync output; errors remain
visible. signal-cli owns account locking: overlapping CLI operations can wait
for its lock. This wrapper does not claim immediate dispatch during a receive.
A continuous-receive daemon is a separate design, not installed by this package.

Messages over 2000 UTF-8 bytes retain the existing behavior: a 200-character
preview plus a temporary text attachment containing the full original body.
Explicit attachments are preserved alongside it. Temporary message files are
private and cleaned after success, failure, or interruption. This wrapper does
not add Markdown-to-Signal styling or native inline long-message rendering.

## NixOS module

The flake exports `nixosModules.default`. Set `services.signal-send.enable = true`
and optionally `project`, `stateDir`, `user`, `group`, `createUser`, or `package`.
It installs a separate sync timer every five minutes, conditional on signal-cli's
local account index. Run setup as the configured state-owning user after
activation. The module defaults to `/var/lib/signal-send`, user `signal-send`,
and project `default`.

The existing `services.signal-send.groupKeyFile` option accepts a runtime file
containing the **new base64 group ID**. For a managed secret, update its encrypted
source explicitly; `select-group` refuses to overwrite a symlinked target.

The package must be built and installed, the device linked, and the group
reselected before live sending can work. A successful send exit code alone is
not proof that the recipient's phone and linked desktop displayed the message.

## Verification

`shellcheck pkgs/signal-send/signal-send tests/send-only.sh` checks shell syntax
and common errors. The offline contract test runs against a strict fake
signal-cli and exercises JSON group selection, attachments, input, migration
rejection, and failure statuses:

```bash
bash tests/send-only.sh pkgs/signal-send/signal-send "$(command -v bash)"
```

Flake checks also cover packaging and module timer wiring. Follow the consuming
repository's approval gate before Nix builds or runtime Signal operations.

CLI contract: https://github.com/AsamK/signal-cli/blob/master/man/signal-cli.1.adoc
