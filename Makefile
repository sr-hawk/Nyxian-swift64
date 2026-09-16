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
# v2 (current): NyxianMacros/*.swift is no longer an Xcode target at all
# (removed from project.pbxproj -- Xcode's swiftc can never read these
# modules no matter how it's invoked). build-swiftui-macros-plugin.sh
# compiles it directly with a macOS-executable swiftc from the SAME
# snapshot build (LLVM-On-iOS's --host-target=macosx-arm64 side, used
# internally to cross-compile the iphoneos-arm64 toolchain -- see that
# script's own header comment for the full reasoning), landing
# libSwiftUIMacros.dylib straight in CoreCompilerSupportLibs/ so it rides
# the same cache Save/Restore steps as everything else here and gets
# embedded via the project's own "Embed Libraries" phase, the same way
# lib_CompilerSwiftWarningControl.dylib already is.
Frameworks/CoreCompiler/CoreCompilerSupportLibs:
	cd LLVM-On-iOS; $(MAKE)
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/
	cp -r LLVM-On-iOS/CoreCompilerSupportLibs Frameworks/CoreCompiler/CoreCompilerSupportLibs/
	cp -r LLVM-On-iOS/LLVM.xcframework Frameworks/CoreCompiler/CoreCompilerSupportLibs/LLVM.xcframework
	rm -rf Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules
	cp -a LLVM-On-iOS/SwiftToolchain-iphoneos/lib/swift/host/compiler Frameworks/CoreCompiler/CoreCompilerSupportLibs/host-compiler-modules
	chmod +x build-swiftui-macros-plugin.sh
	./build-swiftui-macros-plugin.sh

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
