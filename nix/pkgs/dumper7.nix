# Dumper-7 (Unreal SDK generator), built with the clang-cl toolchain. Upstream has no license file, so this is
# built locally from upstream's source and must never be redistributed. Run it inside the 1.14.7 client via
# mystic_loader.ini (see docs/LINUX.md).
{ lib, stdenvNoCC, fetchFromGitHub, cmake, ninja, msvcToolchain }:
stdenvNoCC.mkDerivation {
  pname = "dumper7";
  version = "0-unstable-2026-10-26";
  src = fetchFromGitHub {
    owner = "Encryqed";
    repo = "Dumper-7";
    rev = "2c1eae303f3d775f6f59aee6e95990d9ce2e1966";
    hash = "sha256-RSXYNJ4NG8Ts6hu9fCrJfGQkuDrOAyyh2QIWRXITMZ4=";
  };
  # Upstream includes cmake/common.cmake but the file is Common.cmake (breaks on case-sensitive filesystems).
  postPatch = ''
    substituteInPlace CMakeLists.txt --replace-fail cmake/common.cmake cmake/Common.cmake
    # The CMake files pin C++20, but the code uses C++23 "deducing this"; the upstream .vcxproj uses stdcpp23.
    substituteInPlace CMakeLists.txt --replace-fail cxx_std_20 cxx_std_23
    substituteInPlace cmake/CompilerFlags.cmake \
      --replace-fail 'set(CMAKE_CXX_STANDARD 20)' 'set(CMAKE_CXX_STANDARD 23)' \
      --replace-fail '/std:c++20' '/std:c++latest'
  '';
  nativeBuildInputs = [ cmake ninja ];
  cmakeFlags = [
    "-GNinja"
    "-DCMAKE_TOOLCHAIN_FILE=${msvcToolchain}/toolchain.cmake"
    "-DCMAKE_BUILD_TYPE=Release"
  ];
  installPhase = ''
    runHook preInstall
    mkdir -p $out
    find . -maxdepth 2 -name '*.dll' -exec install -m644 {} $out/ \;
    runHook postInstall
  '';
  dontFixup = true;
  meta.license = lib.licenses.unfree; # no upstream license: all rights reserved, do not redistribute
}
