{
  lib,
  stdenvNoCC,
  bashNonInteractive,
  signal-cli,
  jq,
  qrencode,
  coreutils,
  gawk,
  gnugrep,
  hostname,
}:

let
  runtimePath = lib.makeBinPath [
    coreutils
    gawk
    gnugrep
    hostname
    signal-cli
    jq
    qrencode
  ];
in
stdenvNoCC.mkDerivation {
  pname = "signal-send";
  version = "0.2.0";

  src = ../..;

  installPhase = ''
    runHook preInstall

    install -Dm755 pkgs/signal-send/signal-send "$out/libexec/signal-send"
    mkdir -p "$out/bin"
    printf '%s\n' '#!${bashNonInteractive}/bin/bash' > "$out/bin/signal-send"
    printf '%s\n' 'export PATH=${runtimePath}' >> "$out/bin/signal-send"
    printf 'exec %s %s "$@"\n' '${bashNonInteractive}/bin/bash' "$out/libexec/signal-send" >> "$out/bin/signal-send"
    chmod 0755 "$out/bin/signal-send"

    runHook postInstall
  '';

  meta = {
    description = "Send-only Signal group messaging helper";
    mainProgram = "signal-send";
    platforms = lib.platforms.linux;
  };
}
