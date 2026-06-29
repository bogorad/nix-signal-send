{
  lib,
  rustPlatform,
  makeWrapper,
  presage-cli,
  bash,
}:

rustPlatform.buildRustPackage {
  pname = "signal-send";
  version = "0.1.0";

  src = ../..;

  cargoLock.lockFile = ../../Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];

  nativeCheckInputs = [ bash ];

  preCheck = ''
    export TEST_BASH=${bash}/bin/bash
  '';

  postInstall = ''
    wrapProgram "$out/bin/signal-send" \
      --prefix PATH : ${lib.makeBinPath [ presage-cli ]}
  '';

  meta = {
    description = "Send-only Signal group messaging helper";
    mainProgram = "signal-send";
    platforms = lib.platforms.linux;
  };
}
