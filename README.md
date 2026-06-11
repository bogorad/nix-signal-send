# nix-signal-send

`nix-signal-send` packages a send-only Signal group message helper for NixOS.
It builds `presage-cli` from a pinned upstream revision and wraps it with a
`signal-send` command.

The default model is one Signal linked device per user/host, with separate
project targets stored in local user state:

```text
~/.local/state/signal-send/
  cli.db3
  projects/
    edgeiq/group_master_key
    artwalls-app/group_master_key
```

The send path is not a daemon:

```text
signal-send "alert text"
  -> opens the shared local presage SQLite linked-device DB
  -> resolves the current project id
  -> reads that project's selected group master key
  -> connects to Signal
  -> sends the message
  -> exits
```

## Device Onboarding

Device onboarding is the original Signal secondary-device protocol. It should
happen once for each user/host pair:

```bash
signal-send setup-device
```

That command creates the shared state directory, starts Signal secondary-device
linking, and prints a QR code. Scan it from Signal on your phone:

```text
Signal -> Settings -> Linked devices -> Link new device
```

After linking, the command performs the initial sync. This step creates the
shared presage SQLite DB:

```text
~/.local/state/signal-send/cli.db3
```

Do not put this DB in Git, SOPS, or the Nix store. It is mutable linked-device
state.

## Project Onboarding

Project onboarding selects the Signal group for the current project:

```bash
cd ~/git/edgeiq
signal-send setup-project
```

The project id is resolved in this order:

```text
SIGNAL_SEND_PROJECT
nearest .git root basename
current directory basename
```

If the linked device already knows groups, setup asks you to choose one. If no
groups are known yet, it enters discovery mode and asks you to send a small
message from your phone into the target group so the linked device learns the
metadata.

The selected group key is stored under user state:

```text
~/.local/state/signal-send/projects/<project>/group_master_key
```

For the common local workflow, there is no SOPS step and no project-local secret
file.

## Quick Start

From any project directory:

```bash
signal-send setup
signal-send "hello from this project"
```

`setup` runs device onboarding first, then project onboarding. The device step
is idempotent; once the shared DB is linked, it will not create another Signal
linked device.

## Commands

```bash
signal-send setup
signal-send setup-device
signal-send setup-project
signal-send status
signal-send projects
signal-send groups
signal-send select-group
signal-send discover-group
signal-send "hello from NixOS"
printf '%s\n' "hello from stdin" | signal-send
signal-send --attach /tmp/rebuild.log "log attached"
```

Use `SIGNAL_SEND_PROJECT` when the inferred directory name is ambiguous:

```bash
SIGNAL_SEND_PROJECT=edgeiq-prod signal-send setup-project
SIGNAL_SEND_PROJECT=edgeiq-prod signal-send "prod deploy failed"
```

Use `SIGNAL_SEND_GROUP_KEY_FILE` only when an external runtime secret or service
wrapper should supply the group key path directly.

## NixOS Module

This repository provides `nixosModules.default`.

Example shape:

```nix
{
  inputs.nix-signal-send.url = "github:OWNER/nix-signal-send";

  outputs = { nixpkgs, nix-signal-send, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      modules = [
        nix-signal-send.nixosModules.default
        {
          services.signal-send = {
            enable = true;
            project = "nightly-alerts";
          };
        }
      ];
    };
  };
}
```

This repo does not wire the module into any host configuration by itself.

After applying the module in a host configuration, initialize the linked-device
state as the configured state owner:

```bash
sudo -u signal-send -H signal-send setup
```

If you set `services.signal-send.user` to another user, run setup as that user.
If you set `services.signal-send.project`, the wrapper exports
`SIGNAL_SEND_PROJECT` so the project group key lives under:

```text
/var/lib/signal-send/projects/<project>/group_master_key
```

## SOPS

SOPS is not part of the normal local project workflow.

Use SOPS only when a group key must travel with declarative host configuration
or be restored on another host. In that case, expose the decrypted value as a
runtime file and set:

```nix
services.signal-send.groupKeyFile =
  "/run/secrets/signal-send/groups/default/master_key";
```

When `groupKeyFile` points at a managed secret such as `/run/secrets/...`, do
not run `signal-send select-group` against that path. Select the group with a
normal local project target first, then update the encrypted secret source.

## Security Notes

`presage-cli send-to-group` currently accepts the group key and message as
command-line arguments. That means they may be visible briefly to same-host
process inspectors. Use a dedicated local user for service-style usage on shared
machines, and treat a future direct Rust CLI with file/stdin-only secret passing
as the hardening path.

The selected group key identifies the Signal V2 group for this linked device.
Treat it as secret operational material.
