{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.signal-send;
  defaultPackage = pkgs.callPackage ../../pkgs/signal-send { };
  configuredPackage = pkgs.writeShellScriptBin "signal-send" ''
    export SIGNAL_SEND_STATE_DIR=${lib.escapeShellArg cfg.stateDir}
    export SIGNAL_SEND_PROJECT=${lib.escapeShellArg cfg.project}
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
      description = "Mutable signal-cli linked-device and project state directory.";
    };

    groupKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/signal-send/groups/default/group_id";
      description = "Optional file containing a signal-cli base64 group ID, not a Presage master key. The option name is retained for compatibility.";
    };

    project = lib.mkOption {
      type = lib.types.str;
      default = "default";
      example = "nightly-alerts";
      description = "Optional project id used for state-local project group keys when groupKeyFile is unset.";
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

    systemd.services.signal-send-sync = {
      description = "Drain Signal linked-device queue for signal-send";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig.ConditionPathExists = "${cfg.stateDir}/signal-cli/data/accounts.json";

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = "${lib.getExe configuredPackage} sync";
        TimeoutStartSec = "2min";
      };
    };

    systemd.timers.signal-send-sync = {
      description = "Run signal-send linked-device queue sync";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        RandomizedDelaySec = "15s";
        Persistent = true;
      };
    };
  };
}
