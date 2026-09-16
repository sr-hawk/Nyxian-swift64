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
# NOTE (macro plugin support -- history of v1..v3 hand-rolled NyxianMacros
# build attempts, and why that whole route is now DELETED, lives in
# `~/Desktop/LANE - nyxian-macros.md`; short version: v1 (binary
# .swiftmodule search path) and v2 (Xcode target) both failed because
# LLVM-On-iOS never installs .swiftmodule/.swiftinterface for the
# _Compiler*-aliased targets; v3 (build swift-syntax from source with
# -module-alias) worked but only ever existed to re-implement ONE macro
# (@State) that Apple's own SwiftUIMacros.dylib already implements,
# correctly, for all 70 SDK 27 macro names -- superseded entirely, see
# the commit that removed NyxianMacros/, build-swiftui-macros-plugin.sh,
# and build-plugin-swift-syntax-modules.sh.
#
# Current (task item A): stage libSwiftInProcPluginServer.dylib and the
# non-underscored swift-syntax host libraries LLVM-On-iOS's OWN
# iphoneos-arm64 build already produces (lib/swift/host/, a sibling of the
# lib/swift/host/compiler/ this recipe already copies as
# host-compiler-modules/ above) -- see stage-in-process-plugin-libs.sh's own
# header for the full reasoning. These are the REAL Apple in-process-plugin-
# server mechanism (distinct from Apple's own closed-source macro-plugin
# dylibs -- SwiftUIMacros.dylib etc -- which are never shipped here,
# owner-installed separately, see NXBootstrap's pluginsURL / z97's
# push-plugins).
Frameworks/CoreCompiler/CoreCompilerSupportLibs:
	cd LLVM-On-iOS; $(MAKE)
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/
	cp -r LLVM-On-iOS/CoreCompilerSupportLibs Frameworks/CoreCompiler/CoreCompilerSupportLibs/
	cp -r LLVM-On-iOS/LLVM.xcframework Frameworks/CoreCompiler/CoreCompilerSupportLibs/LLVM.xcframework
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules
	cp -a LLVM-On-iOS/SwiftToolchain-iphoneos/lib/swift/host/compiler Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules
	find Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules -maxdepth 1 \( -name '*.swiftmodule' -o -name '*.swiftdoc' -o -name '*.swiftinterface' -o -name '*.dylib' \) | sort
	chmod +x stage-in-process-plugin-libs.sh
	./stage-in-process-plugin-libs.sh

# Helper
update-config:
	chmod +x version.sh
	./version.sh

# Methods
compile: Frameworks/CoreCompiler/CoreCompilerSupportLibs
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
