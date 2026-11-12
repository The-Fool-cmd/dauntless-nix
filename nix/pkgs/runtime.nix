# MysticParadox.dll (+ the MinGW winmm.dll loader) for one deployment.
#   sdk         Dumper-7 CppSDK output from your own 1.14.7 install (game-derived: keep it local; see docs/LINUX.md
#               for adding it to the store with `nix-store --add-fixed` + requireFile).
#   publicHost  compiled in as MP_PUBLIC_HOST (clients may override with MYSTICPARADOX_BACKEND_URL at run time).
{ lib, stdenvNoCC, cmake, ninja, msvcToolchain, runtimeLoader, sdk, publicHost }:
stdenvNoCC.mkDerivation {
  pname = "dauntless-nix-runtime";
  version = "0-unstable";
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      (lib.fileset.difference ../../ParadoxRuntime (lib.fileset.unions [
        (lib.fileset.maybeMissing ../../ParadoxRuntime/SDK)
        (lib.fileset.maybeMissing ../../ParadoxRuntime/SDK.hpp)
        (lib.fileset.maybeMissing ../../ParadoxRuntime/deployment_config.generated.h)
        (lib.fileset.maybeMissing ../../ParadoxRuntime/x64)
      ]))
      ../../tools/CatalogExporter/StoreRuntimeExporter.cpp
      (lib.fileset.maybeMissing ../../tools/CatalogExporter/StoreRuntimeExporter.h)
      (lib.fileset.fileFilter (f: f.hasExt "h" || f.hasExt "hpp") ../../tools/CatalogExporter)
    ];
  };
  sourceRoot = "source/ParadoxRuntime";
  nativeBuildInputs = [ cmake ninja ];
  cmakeFlags = [
    "-GNinja"
    "-DCMAKE_TOOLCHAIN_FILE=${msvcToolchain}/toolchain.cmake"
    "-DCMAKE_BUILD_TYPE=Release"
    "-DMP_SDK_DIR=${sdk}"
    "-DMP_PUBLIC_HOST=${publicHost}"
  ];
  installPhase = ''
    runHook preInstall
    install -Dm644 MysticParadox.dll $out/MysticParadox.dll
    install -Dm644 ${runtimeLoader}/winmm.dll $out/winmm.dll
    runHook postInstall
  '';
  dontFixup = true;
  meta.license = lib.licenses.agpl3Only; # links the game-derived SDK: build for yourself, do not publish
}
