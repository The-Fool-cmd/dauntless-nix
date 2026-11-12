# tools/RuntimeLoader (winmm.dll proxy) cross-compiled for Windows x64 with MinGW. No MSVC/Windows SDK needed:
# the crate is pure Rust + winapi. Upstream pins a 2026-03 nightly for its MSVC build; stable is enough here.
{ lib, pkgsCross }:
pkgsCross.mingwW64.rustPlatform.buildRustPackage {
  pname = "dauntless-nix-runtime-loader";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../../tools/RuntimeLoader;
    fileset = lib.fileset.unions [
      ../../tools/RuntimeLoader/Cargo.toml
      ../../tools/RuntimeLoader/Cargo.lock
      ../../tools/RuntimeLoader/src
      ../../tools/RuntimeLoader/LICENSE
    ];
  };
  cargoLock.lockFile = ../../tools/RuntimeLoader/Cargo.lock;
  # Static CRT pieces so winmm.dll imports only system DLLs (no libgcc/libwinpthread next to the game).
  RUSTFLAGS = "-C target-feature=+crt-static";
  doCheck = false;
  installPhase = ''
    runHook preInstall
    install -Dm644 target/x86_64-pc-windows-gnu/release/winmm.dll $out/winmm.dll
    install -Dm644 LICENSE $out/LICENSE.RuntimeLoader
    runHook postInstall
  '';
  meta.license = lib.licenses.asl20;
}
