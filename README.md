# nix-signal-send

`nix-signal-send` packages a send-only Signal group message helper for NixOS.
It builds `presage-cli` from a pinned upstream revision and wraps it with a
`signal-send` command focused on one operational target group.

The normal send path is not a daemon:

```text
signal-send "alert text"
  -> opens the local presage SQLite linked-device DB
  -> reads the selected group master key
  -> connects to Signal
  -> sends the message
  -> exits
```

## First Run

Install the package and run:

```bash
signal-send setup
```

Setup creates a private state directory, starts Signal secondary-device linking,
and prints a QR code. Scan it from Signal on your phone:

```text
Signal -> Settings -> Linked devices -> Link new device
```

After linking, setup performs a quiet sync and asks you to select the target
group. If no groups are available yet, it enters discovery mode and asks you to
send a small message from your phone into the target group. That group activity
allows the local linked device to learn the group metadata.

## Commands

```bash
signal-send status
signal-send groups
signal-send select-group
signal-send discover-group
signal-send "hello from NixOS"
printf '%s\n' "hello from stdin" | signal-send
signal-send --attach /tmp/rebuild.log "log attached"
```

## State

The presage SQLite DB is mutable linked-device state. Keep it out of SOPS and
out of the Nix store.

Per-user default:

```text
~/.local/state/signal-send/cli.db3
~/.local/state/signal-send/group_master_key
```

NixOS module default:

```text
/var/lib/signal-send/cli.db3
```

The group master key can be kept as a local `0600` file for simple use. For
declarative NixOS use, move that key into SOPS and expose it as a runtime file,
then set:

```nix
services.signal-send.groupKeyFile =
  "/run/secrets/signal-send/groups/default/master_key";
```

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
            groupKeyFile = "/run/secrets/signal-send/groups/default/master_key";
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
For the first run, leave `groupKeyFile` unset so setup can write
`/var/lib/signal-send/group_master_key`. After setup, move that value into SOPS,
expose it at runtime, and then set `groupKeyFile` to the SOPS-managed path.

## Security Notes

`presage-cli send-to-group` currently accepts the group key and message as
command-line arguments. That means they may be visible briefly to same-host
process inspectors. Use a dedicated local user for service-style usage on shared
machines, and treat a future direct Rust CLI with file/stdin-only secret passing
as the hardening path.

The selected group key identifies the Signal V2 group for this linked device.
Treat it as secret operational material.
