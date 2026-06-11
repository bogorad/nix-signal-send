{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.signal-send;
  defaultPresageCli = pkgs.callPackage ../../pkgs/presage-cli { };
  defaultPackage = pkgs.callPackage ../../pkgs/signal-send {
    presage-cli = defaultPresageCli;
  };
  configuredPackage = pkgs.writeShellScriptBin "signal-send" ''
    export SIGNAL_SEND_STATE_DIR=${lib.escapeShellArg cfg.stateDir}
    ${lib.optionalString (
      cfg.groupKeyFile != null
    ) "export SIGNAL_SEND_GROUP_KEY_FILE=${lib.escapeShellArg cfg.groupKeyFile}"}
    exec ${lib.getExe cfg.package} "$@"
  '';
in
{
  options.services.signal-send = {
    enable = lib.mkEnableOption "send-only Signal group messaging helper";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "nix-signal-send.packages.${pkgs.system}.signal-send";
      description = "signal-send package to install and wrap.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/signal-send";
      description = "Mutable presage linked-device state directory.";
    };

    groupKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/signal-send/groups/default/master_key";
      description = "Optional file containing the selected Signal V2 group master key.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "signal-send";
      description = "User that owns the mutable Signal linked-device state.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "signal-send";
      description = "Group that owns the mutable Signal linked-device state.";
    };

    createUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Create the state-owning system user and group.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ configuredPackage ];

    users.groups = lib.mkIf cfg.createUser {
      ${cfg.group} = { };
    };

    users.users = lib.mkIf cfg.createUser {
      ${cfg.user} = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.stateDir;
        createHome = false;
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0700 ${cfg.user} ${cfg.group} -"
    ];
  };
}
