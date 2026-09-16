#!/usr/bin/env bash
# STAGE B (cheap -- runs whenever libSwiftUIMacros.dylib is missing, cache
# hit or miss; see the Makefile's own comment on why this is a separate
# file target from Frameworks/CoreCompiler/CoreCompilerSupportLibs).
#
# Compiles NyxianMacros/*.swift into libSwiftUIMacros.dylib using:
#   - the macOS-executable snapshot swiftc build-plugin-swift-syntax-
#     modules.sh (Stage A) already cached at CoreCompilerSupportLibs/
#     host-swiftc-macos/bin/swiftc -- same compiler build as the one that
#     produced lib_Compiler*.dylib, so the -module-alias'd .swiftmodule
#     files below type-check consistently with it.
#   - the _Compiler*.swiftmodule files Stage A built (by compiling the
#     real swift-syntax source with -module-alias so they carry the same
#     mangled module identity as the shipped dylibs) at
#     CoreCompilerSupportLibs/plugin-build-modules/.
# NyxianMacros/*.swift already imports the underscore-prefixed names
# directly (import _CompilerSwiftDiagnostics etc) -- no aliasing needed on
# this side, just -I pointed at plugin-build-modules.
#
# At LINK time this links against the REAL lib_Compiler*.dylib files
# already shipped in CoreCompilerSupportLibs/host-compiler-modules/ (the
# ones Nyxian's in-process compiler actually loads at runtime), not
# against anything Stage A built -- Stage A's outputs exist purely to give
# the compiler type information at compile time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_LIBS="${ROOT}/Frameworks/CoreCompiler/CoreCompilerSupportLibs"
HOST_MODULES="${SUPPORT_LIBS}/host-compiler-modules"
PLUGIN_MODULES="${SUPPORT_LIBS}/plugin-build-modules"
SWIFTC="${SUPPORT_LIBS}/host-swiftc-macos/bin/swiftc"
OUT_DYLIB="${SUPPORT_LIBS}/libSwiftUIMacros.dylib"
IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

log() { printf '\033[32m\033[1m[*]\033[0m\033[32m %s\033[0m\n' "$*"; }
die() { printf '\033[31m\033[1m[!]\033[0m\033[31m %s\033[0m\n' "$*" >&2; exit 1; }

[[ -x "${SWIFTC}" ]] || die "missing cached swiftc at ${SWIFTC} -- Stage A (build-plugin-swift-syntax-modules.sh, part of the CoreCompilerSupportLibs recipe) did not run or did not finish; a full toolchain rebuild (CACHE_EPOCH bump) is needed if this cache doesn't have it yet"
"${SWIFTC}" -version >/dev/null || die "cached swiftc at ${SWIFTC} exists but does not run"
[[ -d "${PLUGIN_MODULES}" ]] || die "missing ${PLUGIN_MODULES} -- Stage A did not produce it"
[[ -d "${HOST_MODULES}" ]] || die "missing ${HOST_MODULES}"

log "plugin-build-modules contents:"
find "${PLUGIN_MODULES}" -maxdepth 1 -name '*.swiftmodule' | sort

# libSwiftUIMacros.dylib is embedded directly into Nyxian.app/Frameworks/
# (project.pbxproj's own "Embed Libraries" phase on the Nyxian target,
# dstSubfolderSpec 10 = Frameworks -- matches NXPhaseEngine.m's
# -load-plugin-library path, built from privateFrameworksURL). Its own
# _Compiler*.dylib dependencies physically live one level over, nested
# inside CoreCompiler.framework/CoreCompilerSupportLibs/ (the synchronized
# group the CoreCompiler target already embeds them through). This dylib
# gets its own explicit LC_RPATH for that -- unlike CoreCompiler's
# in-process swift-frontend binary (linked by the snapshot toolchain's own
# build, with its own baked-in rpath), a plugin dlopen'd by
# LibraryPluginProvider via an absolute path is not guaranteed to inherit
# the calling process's rpaths for its own unresolved @rpath/*.dylib loads
# across all dyld versions, so this is spelled out rather than assumed.
# UNVERIFIED: no way to test dlopen/dyld behavior from this machine (no
# iOS device or Xcode here) -- first real test is the phone install.
log "building libSwiftUIMacros.dylib with ${SWIFTC}"
"${SWIFTC}" \
    -emit-library \
    -whole-module-optimization \
    -o "${OUT_DYLIB}" \
    -module-name SwiftUIMacros \
    -target arm64-apple-ios16.0 \
    -sdk "${IOS_SDK_PATH}" \
    -I "${PLUGIN_MODULES}" \
    -L "${HOST_MODULES}" \
    -l_CompilerSwiftSyntax \
    -l_CompilerSwiftSyntaxMacros \
    -l_CompilerSwiftSyntaxBuilder \
    -l_CompilerSwiftDiagnostics \
    -Xlinker -install_name -Xlinker @rpath/libSwiftUIMacros.dylib \
    -Xlinker -rpath -Xlinker @loader_path/CoreCompiler.framework/CoreCompilerSupportLibs \
    "${ROOT}"/NyxianMacros/*.swift

[[ -f "${OUT_DYLIB}" ]] || die "build reported success but ${OUT_DYLIB} does not exist"
log "built ${OUT_DYLIB}"
file "${OUT_DYLIB}" || true
