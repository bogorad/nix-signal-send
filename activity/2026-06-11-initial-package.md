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
