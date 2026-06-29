{
  description = "NixOS package and module for sending Signal group messages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

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
          presage-cli = pkgs.callPackage ./pkgs/presage-cli { };
          signal-send = pkgs.callPackage ./pkgs/signal-send {
            inherit presage-cli;
          };
        in
        {
          inherit presage-cli signal-send;
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

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          signal-send = self.packages.${system}.signal-send;
        }
      );
    };
}
