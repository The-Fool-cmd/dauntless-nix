# clang-cl + lld-link targeting x86_64-pc-windows-msvc, with Microsoft's CRT/STL and Windows SDK from nixpkgs'
# `windows.sdk` (xwin, pinned manifest + hash). The SDK only evaluates when
# config.microsoftVisualStudioLicenseAccepted = true, i.e. when whoever builds has accepted Microsoft's terms.
# Output: $out/toolchain.cmake for CMake projects, plus $out/bin/{cl,link} convenience wrappers.
{ lib, runCommand, windows, llvmPackages_21 }:
let
  sdk = windows.sdk;
  sdkVer = "10.0.26100";
  clang = llvmPackages_21.clang-unwrapped;
  lld = llvmPackages_21.lld;
  llvm = llvmPackages_21.llvm;
  compileFlags = lib.concatStringsSep " " [
    "--target=x86_64-pc-windows-msvc"
    "/vctoolsdir ${sdk}/crt"
    "/winsdkdir ${sdk}/sdk"
    "-fms-compatibility-version=19.44"   # MSVC 17.14 / toolset v143, matching the CRT
    "/Brepro"                             # no timestamps in objects
    # MSVC accepts constexpr functions that can never be constant; clang errors by default. Keep MSVC's behaviour.
    "-Wno-invalid-constexpr"
    # MSVC truncates out-of-range enumerators with a warning (Dumper-7 emits `enum : uint8 { X_MAX = 256 }`).
    "-Wno-c++11-narrowing"
  ];
  linkFlags = lib.concatStringsSep " " [
    "/libpath:${sdk}/crt/lib/x64"
    "/libpath:${sdk}/sdk/lib/${sdkVer}/um/x64"
    "/libpath:${sdk}/sdk/lib/${sdkVer}/ucrt/x64"
    "/Brepro"                             # reproducible PE timestamp
  ];
in
runCommand "dauntless-nix-msvc-toolchain" {
  passthru = { inherit sdk clang lld llvm compileFlags linkFlags; };
} ''
  mkdir -p $out/bin
  cat > $out/toolchain.cmake <<EOF
  set(CMAKE_SYSTEM_NAME Windows)
  set(CMAKE_SYSTEM_PROCESSOR AMD64)
  set(CMAKE_C_COMPILER   ${clang}/bin/clang-cl)
  set(CMAKE_CXX_COMPILER ${clang}/bin/clang-cl)
  set(CMAKE_LINKER       ${lld}/bin/lld-link)
  set(CMAKE_AR           ${llvm}/bin/llvm-lib)
  set(CMAKE_RC_COMPILER  $out/bin/rc)
  set(CMAKE_MT           ${llvm}/bin/llvm-mt)
  set(CMAKE_C_FLAGS_INIT   "${compileFlags}")
  set(CMAKE_CXX_FLAGS_INIT "${compileFlags}")
  set(CMAKE_EXE_LINKER_FLAGS_INIT    "${linkFlags}")
  set(CMAKE_SHARED_LINKER_FLAGS_INIT "${linkFlags}")
  set(CMAKE_MODULE_LINKER_FLAGS_INIT "${linkFlags}")
  # Static CRT (/MT), as upstream: the game folder ships an older msvcp140.dll.
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  EOF
  cat > $out/bin/cl <<EOF
  #!/bin/sh
  exec ${clang}/bin/clang-cl ${compileFlags} "\$@"
  EOF
  cat > $out/bin/link <<EOF
  #!/bin/sh
  exec ${lld}/bin/lld-link ${linkFlags} "\$@"
  EOF
  # llvm-rc preprocesses .rc files by running `clang` found on PATH.
  cat > $out/bin/rc <<EOF
  #!/bin/sh
  PATH=${clang}/bin:\$PATH exec ${llvm}/bin/llvm-rc "\$@"
  EOF
  chmod +x $out/bin/*
''
