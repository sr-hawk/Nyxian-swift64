.DEFAULT_GOAL := all

# Configuration
NXNAME := Nyxian
NXVERSION := $(shell awk -F= '/^VERSION/ {gsub(/[ \t]/,"",$$2); print $$2}' Config.xcconfig)
NXBUNDLE := com.cr4zy.nyxian

# Helper
comma := ,
define log_info
	echo "\033[32m\033[1m[*] \033[0m\033[32m$(1)\033[0m"
endef

define log_error
	echo "\033[31m\033[1m[!] \033[0m\033[31m$(1)\033[0m"; exit 1
endef

export PATH := /opt/homebrew/bin:/usr/local/bin:$(PATH)

define ensure_brew
	@if ! command -v brew >/dev/null 2>&1; then \
		printf '\033[33m\033[1m[?]\033[0m\033[33m homebrew not installed. Install now? [y/N] \033[0m'; \
		if [ -t 0 ]; then read ans; else ans=n; fi; \
		case "$$ans" in \
			[yY]|[yY][eE][sS]) \
				printf '\033[32m\033[1m[*]\033[0m\033[32m installing homebrew...\033[0m\n'; \
				/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { \
					printf '\033[31m\033[1m[!]\033[0m\033[31m homebrew install failed\033[0m\n'; exit 1; }; \
				echo >> ~/.zprofile; \
				echo 'eval "$(/opt/homebrew/bin/brew shellenv zsh)"' >> ~/.zprofile; \
				eval "$(/opt/homebrew/bin/brew shellenv zsh)"; \
				command -v brew >/dev/null 2>&1 || { \
					printf '\033[31m\033[1m[!]\033[0m\033[31m brew installed but not in PATH$(comma) open a new shell\033[0m\n'; exit 1; } ;; \
			*) \
				printf '\033[31m\033[1m[!]\033[0m\033[31m homebrew is required$(comma) see https://brew.sh\033[0m\n'; \
				exit 1 ;; \
		esac; \
	fi
endef

define ensure_brew_package
	@if ! brew list --versions $(1) >/dev/null 2>&1; then \
		printf '\033[33m\033[1m[?]\033[0m\033[33m %s not installed. Install via "brew install %s"? [y/N] \033[0m' '$(1)' '$(1)'; \
		if [ -t 0 ]; then read ans; else ans=n; fi; \
		case "$$ans" in \
			[yY]|[yY][eE][sS]) \
				printf '\033[32m\033[1m[*]\033[0m\033[32m installing %s...\033[0m\n' '$(1)'; \
				brew install $(1) || { printf '\033[31m\033[1m[!]\033[0m\033[31m failed to install %s\033[0m\n' '$(1)'; exit 1; } ;; \
			*) \
				printf '\033[31m\033[1m[!]\033[0m\033[31m %s is required\033[0m\n' '$(1)'; \
				exit 1 ;; \
		esac; \
	fi
endef

THEOS ?= $(HOME)/theos
export THEOS
export PATH := $(THEOS)/bin:$(PATH)

define ensure_macos
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		printf '\033[31m\033[1m[!]\033[0m\033[31m this build requires macOS$(comma) detected: %s\033[0m\n' "$$(uname -s)"; \
		exit 1; \
	fi
endef

define ensure_xcode
	@if xcode-select -p >/dev/null 2>&1 && [ -d "$$(xcode-select -p)/Platforms/iPhoneOS.platform" ]; then \
		: ; \
	else \
		printf '\033[33m\033[1m[?]\033[0m\033[33m Xcode (full IDE$(comma) not CLT) required. Open App Store? [y/N] \033[0m'; \
		if [ -t 0 ]; then read ans; else ans=n; fi; \
		if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ] || [ "$$ans" = "yes" ]; then \
			open 'macappstores://apps.apple.com/app/xcode/id497799835' 2>/dev/null || \
			open 'https://apps.apple.com/app/xcode/id497799835'; \
			printf '\033[33m\033[1m[i]\033[0m\033[33m after install: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer\033[0m\n'; \
		fi; \
		printf '\033[31m\033[1m[!]\033[0m\033[31m Xcode required$(comma) re-run make after install\033[0m\n'; \
		exit 1; \
	fi
endef

# For workflows
CHECK_DEPS ?= 1

ifeq ($(CHECK_DEPS),1)
# Dependency Checks
check:
	$(call ensure_macos)
	$(call ensure_xcode)
	$(call ensure_brew)
	$(call ensure_brew_package,pkgconf)
	$(call ensure_brew_package,cmake)
	$(call ensure_brew_package,libarchive)
	$(call ensure_brew_package,dpkg)
	$(call ensure_brew_package,openssl)
	$(call ensure_brew_package,ninja)
	@$(call log_info,all dependencies are installed)
else
check:
	@$(call log_info,all dependency check was skipped)
endif

# Targets
all: SCHEME := Nyxian
all: FILE := Nyxian.ipa
all: clean check compile package-app clean

# Dependencies
# NOTE (macro plugin support, v1 -- superseded, kept for history): copying
# LLVM-On-iOS/SwiftToolchain-iphoneos/lib/swift/host/compiler's .swiftmodule/
# .swiftdoc/.swiftinterface files alongside the lib_Compiler*.dylib files
# (the two cp/rm lines below) was NOT sufficient. Measured live, CI run
# 35050516832: with SWIFT_INCLUDE_PATHS correctly pointed at
# host-compiler-modules, Xcode's own swiftc still failed archiving the
# NyxianMacros target with "unable to resolve module dependency:
# '_CompilerSwiftDiagnostics'" (and the other three _Compiler* modules).
# Root cause: those .swiftmodule files are binary modules produced by the
# swift-6.4.x-DEVELOPMENT-SNAPSHOT compiler LLVM-On-iOS builds -- a
# DIFFERENT compiler build than Xcode's own bundled swiftc. Binary
# .swiftmodule files are compiler-version-locked; no search path fixes
# that.
#
# v2 (superseded 2026-09-16 same day, kept for history): removed the
# NyxianMacros Xcode target (Xcode's swiftc can never read these modules
# no matter how it's invoked) and tried compiling it directly with a
# macOS-executable swiftc from the SAME snapshot build instead. Measured
# live, CI run 35068589780 (the v4 rebuild): that swiftc DOES run and DOES
# report a clean, unambiguous error -- "no such module
# '_CompilerSwiftDiagnostics'" -- because host-compiler-modules/ contains
# ONLY *.dylib files for these four modules, confirmed by this recipe's
# own `find` diagnostic in that same log. There was never a .swiftmodule
# to find, at any compiler version -- v1's root-cause theory (binary
# module version lock) was wrong; the real issue is that LLVM-On-iOS's
# build never installs .swiftmodule/.swiftinterface for these targets
# anywhere, for any host.
#
# v3 (current): build the actual swift-syntax SOURCE ourselves (the exact
# revision this snapshot compiler embeds -- LLVM-On-iOS's own
# build-swift-toolchain.sh fetches it as a sibling of the swift checkout,
# LLVM-On-iOS/swift-syntax/, via `swift/utils/update-checkout`), with
# -module-alias <Real>=_Compiler<Real> for each of the 9 targets
# NyxianMacros needs (transitively) so the resulting .swiftmodule files
# identify themselves under the same mangled names as the dylibs already
# shipped -- see build-plugin-swift-syntax-modules.sh's own header for the
# full reasoning and the measured dependency graph. Split into two Make
# targets so only the expensive part (needs the transient LLVM-On-iOS
# build tree + swift-syntax checkout, which only exist during a full
# rebuild) is gated on this directory; libSwiftUIMacros.dylib itself is a
# separate file target below so a future cache HIT still rebuilds it if
# it's missing, without forcing another multi-hour toolchain rebuild.
Frameworks/CoreCompiler/CoreCompilerSupportLibs:
	cd LLVM-On-iOS; $(MAKE)
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/
	cp -r LLVM-On-iOS/CoreCompilerSupportLibs Frameworks/CoreCompiler/CoreCompilerSupportLibs/
	cp -r LLVM-On-iOS/LLVM.xcframework Frameworks/CoreCompiler/CoreCompilerSupportLibs/LLVM.xcframework
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules
	cp -a LLVM-On-iOS/SwiftToolchain-iphoneos/lib/swift/host/compiler Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules
	find Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules -maxdepth 1 \( -name '*.swiftmodule' -o -name '*.swiftdoc' -o -name '*.swiftinterface' -o -name '*.dylib' \) | sort
	chmod +x build-plugin-swift-syntax-modules.sh
	./build-plugin-swift-syntax-modules.sh

# libSwiftUIMacros.dylib is its OWN file target (not folded into the
# directory recipe above) so it still gets (re)built on a cache HIT of
# Frameworks/CoreCompiler/CoreCompilerSupportLibs if it's simply missing --
# e.g. right now, since the v4 cache was saved from a run that failed
# before ever producing it (Save CoreCompiler support libs runs
# `if: always()`, precisely so a real toolchain rebuild is never thrown
# away over an unrelated downstream failure).
Frameworks/CoreCompiler/CoreCompilerSupportLibs/libSwiftUIMacros.dylib: Frameworks/CoreCompiler/CoreCompilerSupportLibs
	chmod +x build-swiftui-macros-plugin.sh
	./build-swiftui-macros-plugin.sh

# Helper
update-config:
	chmod +x version.sh
	./version.sh

# Methods
compile: Frameworks/CoreCompiler/CoreCompilerSupportLibs/libSwiftUIMacros.dylib
	chmod +x version.sh
	./version.sh
	xcodebuild \
		-project Nyxian.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath build/Nyxian.xcarchive \
		archive \
		CODE_SIGN_IDENTITY="" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=NO

package-app:
	cp -r  build/Nyxian.xcarchive/Products/Applications Payload
	-rm $(FILE)
	zip -r $(FILE) ./Payload

clean:
	rm -rf Payload
	rm -rf build
	rm -rf tmp
	-rm *.zip

clean-artifacts:
	-rm *.ipa

clean-all: clean clean-artifacts
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs
	cd LLVM-On-iOS; make clean; git reset --hard
