{
  description = "NixOS package and module for sending Signal group messages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
            }
          )
        );
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          signal-send = pkgs.callPackage ./pkgs/signal-send { };
        in
        {
          inherit signal-send;
          inherit (pkgs) signal-cli;
          default = signal-send;
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          app = {
            type = "app";
            program = "${self.packages.${system}.signal-send}/bin/signal-send";
            meta.description = "Send a message to a configured Signal group";
          };
        in
        {
          default = app;
          signal-send = app;
        }
      );

      nixosModules.default = import ./modules/nixos;

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

      checks = forAllSystems (pkgs: {
        module-sync-timer =
          let
            system = pkgs.stdenv.hostPlatform.system;
            moduleSystem = nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  system.stateVersion = "26.05";
                  services.signal-send = {
                    enable = true;
                    package = pkgs.writeShellScriptBin "signal-send" "exit 0";
                  };
                }
              ];
            };
            service = moduleSystem.config.systemd.services.signal-send-sync;
            timer = moduleSystem.config.systemd.timers.signal-send-sync;
          in
          assert
            service.unitConfig.ConditionPathExists == "/var/lib/signal-send/signal-cli/data/accounts.json";
          assert pkgs.lib.hasSuffix " sync" service.serviceConfig.ExecStart;
          assert timer.timerConfig.OnUnitActiveSec == "5min";
          pkgs.runCommand "signal-send-module-sync-timer" { } ''
            touch "$out"
          '';
        shellcheck =
          pkgs.runCommand "signal-send-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; }
            ''
              shellcheck ${./pkgs/signal-send/signal-send} ${./tests/send-only.sh}
              touch "$out"
            '';
        send-only =
          pkgs.runCommand "signal-send-send-only"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.diffutils
                pkgs.gawk
                pkgs.gnugrep
                pkgs.hostname
                pkgs.jq
              ];
              # The byte-vs-character length check only distinguishes a
              # regression under a UTF-8 locale, which the sandbox lacks.
              LOCALE_ARCHIVE = "${pkgs.glibcLocalesUtf8}/lib/locale/locale-archive";
            }
            ''
              bash ${./tests/send-only.sh} ${./pkgs/signal-send/signal-send} ${pkgs.bash}/bin/bash
              touch "$out"
            '';
      });
    };
}
