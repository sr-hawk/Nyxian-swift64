#!/usr/bin/env bash
# Runs inside the Frameworks/CoreCompiler/CoreCompilerSupportLibs: Makefile
# recipe, so it only executes on a full toolchain rebuild (cache MISS) and
# rides the same cache Save/Restore as everything else in that directory.
#
# This is Gap A / task item A from the SDK27-macro-plugins lane: shipping
# Apple's real in-process plugin loading infrastructure inside Nyxian.app,
# distinct from the underscored _Compiler*.dylib set (host-compiler-modules/,
# which the COMPILER uses internally) and distinct from Apple's own
# closed-source macro-plugin dylibs (SwiftUIMacros.dylib etc, which are
# owner-installed separately at runtime -- see NXBootstrap's pluginsURL /
# z97's push-plugins, never shipped in the repo or a release).
#
# What gets copied here is open-source Swift, built by LLVM-On-iOS's own
# iphoneos-arm64 toolchain build (the SAME build that produces the
# on-device compiler Nyxian already ships) -- so, unlike Apple's plugin
# dylibs, these are already the CORRECT platform (iOS) and architecture
# (arm64) for Nyxian's in-process compiler process to dlopen them.
#
# Per the task brief's fact 2/3 (measured in a prior session, not re-derived
# here): tools/swift-plugin-server/CMakeLists.txt builds
# libSwiftInProcPluginServer.dylib as a SHARED host library depending on
# SwiftCompilerPluginMessageHandling + SwiftLibraryPluginProvider, installed
# to lib/swift/host/libSwiftInProcPluginServer.dylib -- and LLVM-On-iOS's
# own build ALREADY produces it plus the whole non-underscored swift-syntax
# set flat in that same lib/swift/host/ directory (confirmed in the CI log
# of run 35094974426): libSwiftSyntax.dylib, libSwiftSyntaxMacros.dylib,
# libSwiftSyntaxMacroExpansion.dylib, libSwiftSyntaxBuilder.dylib,
# libSwiftParser.dylib, libSwiftParserDiagnostics.dylib,
# libSwiftDiagnostics.dylib, libSwiftBasicFormat.dylib,
# libSwiftOperators.dylib, libSwiftIfConfig.dylib, plus
# libSwiftLibraryPluginProvider.dylib and
# libSwiftCompilerPluginMessageHandling.dylib (the plugin server's own
# direct deps).
#
# UNVERIFIED BY THIS SCRIPT (first real test is the next full-rebuild CI
# run reaching this recipe): whether every one of the 13 names below is
# really flat in lib/swift/host/ with no nesting, exactly as fact 3 states.
# Each copy is done individually and loudly, not as one blind `cp -a` of
# the parent directory, so a wrong name shows up as a named "MISSING" line
# in the log instead of a silent partial copy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_HOST_DIR="${ROOT}/LLVM-On-iOS/SwiftToolchain-iphoneos/lib/swift/host"
DEST_DIR="${ROOT}/Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-plugin-libs"

log() { printf '\033[32m\033[1m[*]\033[0m\033[32m %s\033[0m\n' "$*"; }
die() { printf '\033[31m\033[1m[!]\033[0m\033[31m %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "${SRC_HOST_DIR}" ]] || die "missing ${SRC_HOST_DIR} -- LLVM-On-iOS's iphoneos-arm64 toolchain build did not run or did not install lib/swift/host as expected"

rm -rf "${DEST_DIR}"
mkdir -p "${DEST_DIR}"

NAMES=(
    libSwiftInProcPluginServer.dylib
    libSwiftLibraryPluginProvider.dylib
    libSwiftCompilerPluginMessageHandling.dylib
    libSwiftSyntax.dylib
    libSwiftSyntaxMacros.dylib
    libSwiftSyntaxMacroExpansion.dylib
    libSwiftSyntaxBuilder.dylib
    libSwiftParser.dylib
    libSwiftParserDiagnostics.dylib
    libSwiftDiagnostics.dylib
    libSwiftBasicFormat.dylib
    libSwiftOperators.dylib
    libSwiftIfConfig.dylib
)

missing=()
for name in "${NAMES[@]}"; do
    if [[ -f "${SRC_HOST_DIR}/${name}" ]]; then
        cp -a "${SRC_HOST_DIR}/${name}" "${DEST_DIR}/${name}"
    else
        missing+=("${name}")
    fi
done

log "host-plugin-libs contents:"
find "${DEST_DIR}" -maxdepth 1 -name '*.dylib' | sort

if [[ ${#missing[@]} -gt 0 ]]; then
    log "listing of ${SRC_HOST_DIR} for comparison (fact 3 may need re-measuring):"
    find "${SRC_HOST_DIR}" -maxdepth 2 | sort
    die "missing from ${SRC_HOST_DIR}: ${missing[*]}"
fi

[[ -f "${DEST_DIR}/libSwiftInProcPluginServer.dylib" ]] || die "libSwiftInProcPluginServer.dylib not staged -- NXPhaseEngine's -in-process-plugin-server-path will find nothing at runtime"

log "staged $(( ${#NAMES[@]} - ${#missing[@]} ))/${#NAMES[@]} in-process plugin host libraries"
