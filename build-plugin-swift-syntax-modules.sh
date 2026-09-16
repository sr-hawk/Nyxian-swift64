#!/usr/bin/env bash
# STAGE A (expensive -- runs only during a full toolchain rebuild, as part
# of the Frameworks/CoreCompiler/CoreCompilerSupportLibs Makefile recipe).
#
# Measured live, CI run 35068589780: LLVM-On-iOS/SwiftToolchain-iphoneos/
# lib/swift/host/compiler/ contains ONLY *.dylib files for the four
# _Compiler* modules NyxianMacros imports -- no .swiftmodule/.swiftinterface
# at all (confirmed by this script's own predecessor's `find` diagnostic,
# and by the compile failure itself: "no such module '_CompilerSwiftDiagnostics'"
# is Swift's real "I looked and there is nothing to import" error, not a
# version-mismatch rejection). So there is nothing to fix a search path
# to -- the type information these modules would provide was never
# installed anywhere in this toolchain's shipped output.
#
# Real fix: build the ACTUAL swift-syntax source (the same revision this
# snapshot compiler embeds -- LLVM-On-iOS's own build-swift-toolchain.sh
# fetches it as a sibling of the swift checkout via `swift/utils/
# update-checkout`, landing at LLVM-On-iOS/swift-syntax/) ourselves, with
# the macOS-executable snapshot swiftc (same one build-swiftui-macros-
# plugin.sh already uses), and `-module-alias <Real>=_Compiler<Real>` for
# every dependency so the resulting .swiftmodule files identify themselves
# under the SAME mangled names as the dylibs Nyxian's in-process compiler
# already has loaded at runtime. -module-alias (SE-0339) is exactly the
# real mechanism Apple's own tooling uses for a compiler's embedded,
# renamed copy of swift-syntax -- this project's own module names
# (_CompilerSwiftSyntax etc) are that exact convention, not something
# LLVM-On-iOS invented.
#
# Only -emit-module is needed here (no -emit-library/link): NyxianMacros's
# FINAL dylib links against the REAL lib_Compiler*.dylib files already
# embedded in CoreCompiler.framework, not against anything built here --
# these .swiftmodule files exist purely to let the compiler type-check
# NyxianMacros' source against the right (aliased) type identities.
# _SwiftSyntaxCShims (a real swift-syntax target: SwiftSyntax's own
# Syntax.swift/RawSyntaxArena.swift import it) is handled the same way --
# -Xcc -I its include/ dir for the modulemap is enough for type-checking;
# its one .c file's actual symbols already exist inside the shipped
# lib_CompilerSwiftSyntax.dylib, so nothing here needs to compile or link
# it.
#
# Real, measured dependency graph (grepped from swiftlang/swift-syntax's
# own Sources/*/*.swift import lines, excluding Documentation.docc
# tutorial snippets which are not part of the compiled library):
#   SwiftSyntax            -> _SwiftSyntaxCShims
#   SwiftBasicFormat       -> SwiftSyntax
#   SwiftDiagnostics       -> SwiftSyntax
#   SwiftParser            -> SwiftSyntax
#   SwiftParserDiagnostics -> SwiftBasicFormat, SwiftDiagnostics
#   SwiftOperators         -> SwiftDiagnostics, SwiftParser, SwiftSyntax
#   SwiftSyntaxBuilder     -> SwiftBasicFormat, SwiftDiagnostics, SwiftParser,
#                             SwiftParserDiagnostics, SwiftSyntax
#   SwiftIfConfig          -> SwiftDiagnostics, SwiftOperators, SwiftSyntax,
#                             SwiftSyntaxBuilder
#   SwiftSyntaxMacros      -> SwiftDiagnostics, SwiftIfConfig, SwiftSyntax,
#                             SwiftSyntaxBuilder
# Only these 9 targets are built -- the full dylib set also has
# SwiftLexicalLookup/SwiftIDEUtils/SwiftSyntaxMacroExpansion/
# SwiftCompilerPluginMessageHandling/SwiftWarningControl, none of which
# NyxianMacros imports (directly or transitively through the above).
#
# Bash-3.2 compatible on purpose (macOS system /usr/bin/env bash, no
# homebrew bash installed by this Makefile) -- no associative arrays.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPPORT_LIBS="${ROOT}/Frameworks/CoreCompiler/CoreCompilerSupportLibs"
SWIFT_SYNTAX_SRC="${ROOT}/LLVM-On-iOS/swift-syntax"
MODULES_OUT="${SUPPORT_LIBS}/plugin-build-modules"
SWIFTC_CACHE_DIR="${SUPPORT_LIBS}/host-swiftc-macos"
IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"

log() { printf '\033[32m\033[1m[*]\033[0m\033[32m %s\033[0m\n' "$*"; }
die() { printf '\033[31m\033[1m[!]\033[0m\033[31m %s\033[0m\n' "$*" >&2; exit 1; }

[[ -d "${SWIFT_SYNTAX_SRC}" ]] || die "missing ${SWIFT_SYNTAX_SRC} -- expected LLVM-On-iOS's own swift-source fetch (Scripts/build-swift-toolchain.sh fetch -> swift/utils/update-checkout) to have cloned it as a sibling of the swift checkout"

# Snapshot the macOS-executable snapshot swiftc into the cached tree FIRST,
# so both this script and future cache-hit runs (build-swiftui-macros-
# plugin.sh) use one single copy from one single place.
CANDIDATES=(
    "${ROOT}/LLVM-On-iOS/build/LLVMClangSwift_iphoneos/intermediate-install/macosx-arm64/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    "${ROOT}/LLVM-On-iOS/build/LLVMClangSwift_iphoneos/toolchain-macosx-arm64/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
    "${ROOT}/LLVM-On-iOS/build/LLVMClangSwift_iphoneos/swift-macosx-arm64/bin/swiftc"
)
RAW_SWIFTC=""
for c in "${CANDIDATES[@]}"; do
    if [[ -x "${c}" ]] && "${c}" -version >/dev/null 2>&1; then
        RAW_SWIFTC="${c}"
        log "usable macOS-executable swiftc: ${c}"
        break
    fi
    log "not usable: ${c}"
done
[[ -n "${RAW_SWIFTC}" ]] || die "no macOS-executable snapshot swiftc found"

RAW_SWIFTC_BINDIR="$(dirname "${RAW_SWIFTC}")"
rm -rf "${SWIFTC_CACHE_DIR}"
mkdir -p "${SWIFTC_CACHE_DIR}/bin"
cp -a "${RAW_SWIFTC_BINDIR}/." "${SWIFTC_CACHE_DIR}/bin/"
SWIFTC="${SWIFTC_CACHE_DIR}/bin/swiftc"
[[ -x "${SWIFTC}" ]] || die "copied swiftc is not executable at ${SWIFTC}"
"${SWIFTC}" -version >/dev/null || die "copied swiftc at ${SWIFTC} does not run -- relocation broke it (rpath/relative-path dependency?)"
log "cached swiftc at ${SWIFTC}, confirmed runnable after the copy"

rm -rf "${MODULES_OUT}"
mkdir -p "${MODULES_OUT}"

CSHIMS_INCLUDE="${SWIFT_SYNTAX_SRC}/Sources/_SwiftSyntaxCShims/include"
[[ -d "${CSHIMS_INCLUDE}" ]] || die "missing ${CSHIMS_INCLUDE} -- swift-syntax layout changed, update this script"

# name|deps(space-separated, may be empty)
TARGETS=(
    "SwiftSyntax|"
    "SwiftBasicFormat|SwiftSyntax"
    "SwiftDiagnostics|SwiftSyntax"
    "SwiftParser|SwiftSyntax"
    "SwiftParserDiagnostics|SwiftBasicFormat SwiftDiagnostics"
    "SwiftOperators|SwiftDiagnostics SwiftParser SwiftSyntax"
    "SwiftSyntaxBuilder|SwiftBasicFormat SwiftDiagnostics SwiftParser SwiftParserDiagnostics SwiftSyntax"
    "SwiftIfConfig|SwiftDiagnostics SwiftOperators SwiftSyntax SwiftSyntaxBuilder"
    "SwiftSyntaxMacros|SwiftDiagnostics SwiftIfConfig SwiftSyntax SwiftSyntaxBuilder"
)
ALL_NAMES="SwiftSyntax SwiftBasicFormat SwiftDiagnostics SwiftParser SwiftParserDiagnostics SwiftOperators SwiftSyntaxBuilder SwiftIfConfig SwiftSyntaxMacros"

built_marker() { echo "${MODULES_OUT}/.built-$1"; }

build_one() {
    local name="$1" deps="$2"
    local srcdir="${SWIFT_SYNTAX_SRC}/Sources/${name}"
    [[ -d "${srcdir}" ]] || die "missing ${srcdir} -- swift-syntax layout changed, update this script"

    local files=()
    while IFS= read -r f; do files+=("${f}"); done < <(find "${srcdir}" -name '*.swift' -not -path '*/Documentation.docc/*')
    [[ ${#files[@]} -gt 0 ]] || die "no .swift files found under ${srcdir}"

    local alias_flags=()
    local n
    for n in ${ALL_NAMES}; do
        alias_flags+=(-module-alias "${n}=_Compiler${n}")
    done

    log "building _Compiler${name} (${#files[@]} files, deps: ${deps:-none})"
    "${SWIFTC}" \
        -emit-module \
        -module-name "_Compiler${name}" \
        -emit-module-path "${MODULES_OUT}/_Compiler${name}.swiftmodule" \
        "${alias_flags[@]}" \
        -target arm64-apple-ios16.0 \
        -sdk "${IOS_SDK_PATH}" \
        -I "${MODULES_OUT}" \
        -Xcc -I -Xcc "${CSHIMS_INCLUDE}" \
        -parse-as-library \
        -whole-module-optimization \
        -emit-object -o "${MODULES_OUT}/_Compiler${name}.o" \
        "${files[@]}"
    touch "$(built_marker "${name}")"
}

# Fixed-point retry: don't assume the dependency list above is complete or
# perfectly ordered -- keep looping over whatever hasn't built yet until
# either everything succeeds or a full pass makes no progress, then report
# exactly what's stuck and why.
remaining=("${TARGETS[@]}")
last_error=""
for pass in 1 2 3 4 5 6 7 8 9; do
    [[ ${#remaining[@]} -eq 0 ]] && break
    log "=== pass ${pass}, ${#remaining[@]} target(s) left: $(printf '%s ' "${remaining[@]%%|*}") ==="
    next_remaining=()
    progressed=0
    for entry in "${remaining[@]}"; do
        name="${entry%%|*}"
        deps="${entry#*|}"
        [[ "${deps}" == "${entry}" ]] && deps=""
        if [[ -f "$(built_marker "${name}")" ]]; then
            continue
        fi
        if out=$(build_one "${name}" "${deps}" 2>&1); then
            printf '%s\n' "${out}"
            progressed=1
        else
            printf '%s\n' "${out}"
            last_error="${out}"
            next_remaining+=("${entry}")
        fi
    done
    remaining=("${next_remaining[@]+"${next_remaining[@]}"}")
    if [[ ${#remaining[@]} -gt 0 && ${progressed} -eq 0 ]]; then
        log "no progress this pass -- stopping rather than looping forever"
        break
    fi
done

if [[ ${#remaining[@]} -gt 0 ]]; then
    log "FAILED to build: $(printf '%s ' "${remaining[@]%%|*}")"
    log "last error was:"
    printf '%s\n' "${last_error}" >&2
    die "swift-syntax module build did not reach a fixed point -- see the per-target errors above in this same log"
fi

log "all swift-syntax modules built. Contents of ${MODULES_OUT}:"
find "${MODULES_OUT}" -maxdepth 1 -name '*.swiftmodule' | sort
