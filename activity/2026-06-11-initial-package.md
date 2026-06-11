# Initial package scaffold

Created the initial `nix-signal-send` repository as a standalone Nix flake.

The implementation packages a pinned `presage-cli` revision, adds a
`signal-send` wrapper for setup, linking, group discovery, selection, and
send-only use, and provides a NixOS module that installs the helper and creates
private mutable state.

The design keeps the presage SQLite linked-device database out of SOPS and out
of the Nix store. Group keys can be selected locally for simple use or supplied
later through a runtime secret file for NixOS/SOPS integration. This repo does
not wire the module into any host configuration.

Follow-up hardening removed generated shell wrappers that enabled automatic
failure modes, made group-listing failures explicit without relying on
`pipefail`, and clarified that NixOS/SOPS use should initialize the local group
key first, then move that key into SOPS and consume it through `groupKeyFile`.
