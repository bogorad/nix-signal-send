# Repository Instructions

This repo is managed with Beads and roborev.

- Use beads skill.
- Do not wire this module into a host NixOS configuration from this repo.
- Do not commit plaintext Signal group keys or presage SQLite state.
- Keep mutable Signal linked-device state out of the Nix store.
- Prefer targeted checks: `nix fmt -- --check`, `nix flake check`, `shellcheck`,
  and focused `nix eval`/`nix build` commands.
