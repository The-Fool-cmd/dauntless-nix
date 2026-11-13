# tools/CatalogExporter (CatalogExporter.dll), built against your own SDK. Inject into your own 1.14.7 client with
# mystic_loader.ini; it reads export_flags.txt from and writes Items_Analysis\ to the game's working directory.
# Output is game data: never commit or publish it.
{ lib, stdenvNoCC, cmake, ninja, msvcToolchain, sdk }:
stdenvNoCC.mkDerivation {
  pname = "dauntless-nix-catalog-exporter";
  version = "0-unstable";
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      (lib.fileset.fileFilter (f: f.hasExt "cpp" || f.hasExt "h" || f.hasExt "hpp" || f.name == "CMakeLists.txt")
        ../../tools/CatalogExporter)
    ];
  };
  sourceRoot = "source/tools/CatalogExporter";
  nativeBuildInputs = [ cmake ninja ];
  cmakeFlags = [ "-GNinja" "-DCMAKE_TOOLCHAIN_FILE=${msvcToolchain}/toolchain.cmake" "-DCMAKE_BUILD_TYPE=Release" "-DMP_SDK_DIR=${sdk}" ];
  installPhase = "install -Dm644 CatalogExporter.dll $out/CatalogExporter.dll";
  dontFixup = true;
  meta.license = lib.licenses.agpl3Only; # links the game-derived SDK: build for yourself, do not publish
}
