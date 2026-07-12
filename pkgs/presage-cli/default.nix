{
  lib,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  cmake,
  protobuf,
  openssl,
  sqlite,
}:

rustPlatform.buildRustPackage rec {
  pname = "presage-cli";
  version = "0.8.0-dev-2026-06-04";

  src = fetchFromGitHub {
    owner = "whisperfish";
    repo = "presage";
    rev = "22251cc2d4503240df82aa27f1ba226324c05a29";
    hash = "sha256-M31TMN/l9WP28+xNE7A6nNUitORGpncY5xbON0kLjv4=";
  };

  patches = [ ./decryption-error-session-reset.patch ];

  cargoHash = "sha256-SNHalFjmA8wfSPPRVj0P4mb1Bw2zR2oXf/zQdYIVOM0=";

  nativeBuildInputs = [
    cmake
    pkg-config
    protobuf
  ];

  buildInputs = [
    openssl
    sqlite
  ];

  CFLAGS = "-I${lib.getDev openssl}/include";
  LIBRARY_PATH = "${lib.getLib openssl}/lib";

  cargoBuildFlags = [
    "-p"
    "presage-cli"
  ];

  doCheck = false;

  meta = {
    description = "Demo Signal CLI from the presage project";
    homepage = "https://github.com/whisperfish/presage";
    license = lib.licenses.agpl3Only;
    mainProgram = "presage-cli";
    platforms = lib.platforms.linux;
  };
}
