# Rust CLI Locking And Check

Replaced the Bash `signal-send` wrapper with a Rust CLI while keeping
`presage-cli` as the Signal backend.

Why:

- `signal-send-sync.timer` and manual `signal-send` commands could race on the
  same presage SQLite linked-device state.
- `status` could report misleading state while another sync process was active.
- `status` also did not prove that the selected project group key matched a
  group currently known to presage.

What changed:

- All commands that touch presage state take an exclusive state-directory lock.
- Sends run `sync-contacts` and `sync --stop-after-empty-queue` before
  `send-to-group`.
- Added `signal-send check`, which verifies the linked device, project group
  key, and current group list agree, and prints the selected group label without
  printing the key.
- Group-key selection writes now create the temporary key file with mode `0600`
  before any secret bytes are written.
- Status/project listing now reports invalid group keys as `invalid` instead of
  `selected`.

Evidence:

- Bead: `nix-signal-send-rzv`.
- Remote build host: `ts-claw.lan`.
- Checks passed: `cargo fmt --check`, `cargo test`, explicit `nix fmt` check,
  `nix flake check --no-update-lock-file`, and
  `nix build --no-update-lock-file .#signal-send`.
- Local final build and live check passed with
  `SIGNAL_SEND_PROJECT=nix-config result/bin/signal-send check`, reporting
  `selected-group: Nix-config: None`.
- Roborev job 3 found two Rust-port regressions; both were fixed. Roborev job 4
  reported no issues.
- Stale roborev Beads `nix-signal-send-k6m`, `nix-signal-send-3d4`, and
  `nix-signal-send-ri3` were closed.

Remaining boundary:

- The patch is staged but not committed or pushed.
- Consuming nix-config has not been repinned or deployed.
