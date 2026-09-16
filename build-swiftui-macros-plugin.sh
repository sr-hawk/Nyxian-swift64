#!/usr/bin/env bash
# Builds NyxianMacros/*.swift into libSwiftUIMacros.dylib and drops it into
# Frameworks/CoreCompiler/CoreCompilerSupportLibs/, where it rides the same
# cache Save/Restore steps as the lib_Compiler*.dylib files and gets
# embedded into Nyxian.app via the project's own "Embed Libraries" phase
# (see Nyxian.xcodeproj/project.pbxproj).
#
# WHY THIS IS A RAW SWIFTC INVOCATION, NOT AN XCODE TARGET:
#
# NyxianMacros/*.swift imports _CompilerSwiftDiagnostics, _CompilerSwiftSyntax,
# _CompilerSwiftSyntaxBuilder, _CompilerSwiftSyntaxMacros -- the underscore-
# prefixed module set the swift-6.4.x-DEVELOPMENT-SNAPSHOT toolchain (built
# by LLVM-On-iOS, see build-swift-toolchain.sh) builds for its own in-process
# compiler embedded in CoreCompiler.framework. Those modules' .swiftmodule
# files (in LLVM-On-iOS/SwiftToolchain-iphoneos/lib/swift/host/compiler/,
# copied into Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-
# modules/ by this Makefile) are binary modules produced by THAT SPECIFIC
# snapshot compiler build. Binary .swiftmodule files are compiler-version-
# locked -- Xcode's own bundled swiftc (a different build entirely) cannot
# read them, confirmed live: CI run 35050516832 failed archiving the
# NyxianMacros Xcode target with "unable to resolve module dependency:
# '_CompilerSwiftDiagnostics'" etc even with the correct -I search path
# wired in (SWIFT_INCLUDE_PATHS pointed straight at host-compiler-modules).
#
# The only compiler that CAN read those .swiftmodule files is a swiftc from
# the exact same snapshot build. LLVM-On-iOS's build-script invocation
# (--host-target=macosx-arm64 --cross-compile-hosts=iphoneos-arm64) produces
# TWO toolchain outputs from that one compiler source tree:
#   - swift-iphoneos-arm64 / llvm-iphoneos-arm64: an ARM64 Mach-O compiler
#     that runs ON iOS -- this is what gets installed as SwiftToolchain-
#     iphoneos and shipped in the app as CoreCompiler's on-device compiler.
#     It cannot execute on the macOS CI runner at all.
#   - intermediate-install/macosx-arm64 (and the merged
#     toolchain-macosx-arm64, built by swift/utils/recursive-lipo): a
#     macOS-executable swiftc from THE SAME compiler source/commit, built
#     with SWIFT_BUILD_SWIFT_SYNTAX=TRUE, used internally by build-script to
#     drive the iphoneos-arm64 cross-compile. This one runs on the CI
#     runner and, because it is the same compiler build, can read the
#     .swiftmodule files the iphoneos-arm64 side produced when told to
#     target arm64-apple-ios via -target/-sdk (an ordinary cross-compile,
#     same trick Xcode's own swiftc uses to target iOS from macOS).
#
# This script tries several candidate paths for that macOS-executable
# swiftc (build-swift-toolchain.sh's own copy_ios_install() checks some of
# these same paths for a *different* purpose -- assembling the on-device
# toolchain -- so their existence is not a new assumption, just a new use),
# picks the first one that actually EXECUTES on this machine (the only
# reliable way to tell "macOS Mach-O" from "iOS Mach-O" without parsing
# load commands by hand), and fails loudly if none do.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLOI_BUILD="${ROOT}/LLVM-On-iOS/build/LLVMClangSwift_iphoneos"
SUPPORT_LIBS="${ROOT}/Frameworks/CoreCompiler/CoreCompilerSupportLibs"
HOST_MODULES="${SUPPORT_LIBS}/host-compiler-modules"
OUT_DYLIB="${SUPPORT_LIBS}/libSwiftUIMacros.dylib"
IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
XCODE_TOOLCHAIN_SUFFIX="Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"

log() { printf '\033[32m\033[1m[*]\033[0m\033[32m %s\033[0m\n' "$*"; }
die() { printf '\033[31m\033[1m[!]\033[0m\033[31m %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "${HOST_MODULES}" ]] || die "missing ${HOST_MODULES} -- run the CoreCompilerSupportLibs bundling step first"

log "host-compiler-modules contents (ground truth for the module-lock diagnosis):"
find "${HOST_MODULES}" -maxdepth 1 \( -name '*.swiftmodule' -o -name '*.swiftdoc' -o -name '*.swiftinterface' -o -name '*.dylib' \) -print | sort

CANDIDATES=(
    "${LLOI_BUILD}/intermediate-install/macosx-arm64/${XCODE_TOOLCHAIN_SUFFIX}"
    "${LLOI_BUILD}/toolchain-macosx-arm64/${XCODE_TOOLCHAIN_SUFFIX}"
    "${LLOI_BUILD}/swift-macosx-arm64/bin/swiftc"
)

SWIFTC=""
for c in "${CANDIDATES[@]}"; do
    if [[ -x "${c}" ]]; then
        log "candidate ${c} exists, checking it actually runs on macOS..."
        if "${c}" -version >/dev/null 2>&1; then
            log "usable: ${c}"
            SWIFTC="${c}"
            break
        else
            log "exists but did not execute (likely an iOS-targeted binary, not macOS): ${c}"
        fi
    else
        log "not found: ${c}"
    fi
done

[[ -n "${SWIFTC}" ]] || die "no macOS-executable snapshot swiftc found under ${LLOI_BUILD} -- see the candidate log above; this script's path list needs updating to match the real LLVM-On-iOS build layout"

log "swiftc version:"
"${SWIFTC}" -version

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
    -o "${OUT_DYLIB}" \
    -module-name SwiftUIMacros \
    -target arm64-apple-ios16.0 \
    -sdk "${IOS_SDK_PATH}" \
    -I "${HOST_MODULES}" \
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
