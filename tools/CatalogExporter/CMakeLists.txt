# CMake build of CatalogExporter.dll, equivalent to the Release|x64 configuration of CatalogExporter.vcxproj.
# Added by dauntless-nix for cross-builds without Visual Studio (clang-cl + lld-link + MSVC CRT/Windows SDK;
# nix/pkgs/msvc-toolchain.nix). The .vcxproj stays the reference.
#
#   cmake -G Ninja -DCMAKE_TOOLCHAIN_FILE=<toolchain> -DMP_SDK_DIR=<CppSDK dir> <this dir>
cmake_minimum_required(VERSION 3.20)
project(CatalogExporter LANGUAGES CXX)

set(MP_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../ParadoxRuntime" CACHE PATH
    "Directory holding the Dumper-7 CppSDK output (SDK.hpp and SDK/). Default: ParadoxRuntime, as the .vcxproj.")
if(NOT EXISTS "${MP_SDK_DIR}/SDK.hpp")
  message(FATAL_ERROR "MP_SDK_DIR=${MP_SDK_DIR} has no SDK.hpp (docs/GENERATING_SDK.md).")
endif()

add_library(CatalogExporter SHARED
  dllmain.cpp ProgressionExporter.cpp CombatExporter.cpp SkinsExporter.cpp SlayersPathExporter.cpp HuntExporter.cpp
  TableInventoryExporter.cpp DropTableExporter.cpp CurrencyExporter.cpp StoreRuntimeExporter.cpp MasteryExporter.cpp
  "${MP_SDK_DIR}/SDK/Basic.cpp" "${MP_SDK_DIR}/SDK/CoreUObject_functions.cpp"
  "${MP_SDK_DIR}/SDK/Engine_functions.cpp" "${MP_SDK_DIR}/SDK/Archon_functions.cpp")
set_target_properties(CatalogExporter PROPERTIES
  CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON MSVC_RUNTIME_LIBRARY MultiThreaded)
target_include_directories(CatalogExporter PRIVATE "${MP_SDK_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}")
target_compile_definitions(CatalogExporter PRIVATE NDEBUG _WINDOWS _USRDLL)
if(MSVC)
  target_compile_options(CatalogExporter PRIVATE /W3 /EHsc /bigobj /permissive-)
endif()
