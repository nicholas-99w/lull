# See Docs/DEVELOPMENT.md > Building.
PROJECT      := Lull.xcodeproj
DERIVED      := build/DerivedData
SCHEMES      := Lull lulld lullctl
XCB          := xcodebuild -project $(PROJECT) -derivedDataPath $(DERIVED) -destination 'generic/platform=macOS'
SIGN_VARS    := $(if $(APPLE_TEAM_ID),APPLE_TEAM_ID=$(APPLE_TEAM_ID)) $(if $(SIGNING_IDENTITY),SIGNING_IDENTITY="$(SIGNING_IDENTITY)")

.PHONY: gen build release check-release test lint clean dev-bundle pkg dist release-assets

gen:
	xcodegen generate --quiet

$(PROJECT): project.yml
	xcodegen generate --quiet

build: $(PROJECT)
	@for s in $(SCHEMES); do \
		$(XCB) -scheme $$s -configuration Debug $(SIGN_VARS) build -quiet || exit 1; \
	done

# Release builds are ad-hoc signed by default, which is production-ready for Jamf
# policy deployment (SECURITY.md > How the parts trust each other). For Developer ID signing,
# set APPLE_TEAM_ID and SIGNING_IDENTITY here or in Config/Signing.local.xcconfig.
# A real identity without a Team ID is a mistake, so refuse it. check-signing.sh
# then checks what was actually built, however it was configured.
release: $(PROJECT)
	@if [ -n "$(SIGNING_IDENTITY)" ] && [ "$(SIGNING_IDENTITY)" != "-" ] && [ -z "$(APPLE_TEAM_ID)" ]; then \
		echo "error: SIGNING_IDENTITY is set but APPLE_TEAM_ID is empty" >&2; exit 1; \
	fi
	@for s in $(SCHEMES); do \
		$(XCB) -scheme $$s -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=NO $(SIGN_VARS) build -quiet || exit 1; \
	done
	@APPLE_TEAM_ID="$(APPLE_TEAM_ID)" Scripts/check-signing.sh | sed 's/^/signing: /'

# Installer package from the Release build (PKG_CONFIG=Debug for a test-only Debug package).
pkg:
	Scripts/make-pkg.sh --config $(or $(PKG_CONFIG),Release)

# One-shot release build: generate, test, Apple silicon Release build, escape-hatch
# check, installer package (build/pkg/Lull-<version>-<build>.pkg). A signed package
# is also notarised and stapled (needs NOTARY_PROFILE; Scripts/notarize.sh).
dist:
	$(MAKE) gen
	$(MAKE) test
	$(MAKE) release
	$(MAKE) check-release
	Scripts/make-pkg.sh --notarize

# Everything for a GitHub Release (package, Jamf kit, checksums, notes).
release-assets:
	Scripts/make-release.sh

# The --self-test also proves the markers are detectable in a Debug build, so a pass isn't vacuous.
check-release:
	python3 Scripts/check-debug-guards.py
	Scripts/check-release-hatches.sh
	@if [ -d build/DerivedData/Build/Products/Debug/Lull.app ]; then Scripts/check-release-hatches.sh --self-test; \
	else echo "note: no Debug build; skipping marker self-test (run 'make build')"; fi

# Everything a test Mac needs, in one tarball: copy it over, untar, then
#   sudo ./dev-install.sh --i-am-on-a-test-mac --products . [--dev-config example-dev.plist]
# CONFIG=Release bundles the Release build instead (no Debug escape hatches!).
CONFIG ?= Debug
dev-bundle:
	@test -d $(DERIVED)/Build/Products/$(CONFIG)/Lull.app || { echo "build first (make build / make release)"; exit 1; }
	rm -rf build/lull-dev && mkdir -p build/lull-dev
	cp -R $(DERIVED)/Build/Products/$(CONFIG)/Lull.app $(DERIVED)/Build/Products/$(CONFIG)/lulld $(DERIVED)/Build/Products/$(CONFIG)/lullctl build/lull-dev/
	cp Scripts/dev-install.sh Scripts/dev-uninstall.sh Scripts/uninstall.sh Scripts/jamf/portal-enrol.sh Resources/LaunchDaemon.plist.template Resources/LaunchAgent.plist.template Config/example-dev.plist build/lull-dev/
	tar -C build -czf build/lull-dev-$(CONFIG).tar.gz lull-dev
	@echo "wrote build/lull-dev-$(CONFIG).tar.gz"

# swift test covers LullCore, LullDaemonKit and LullAgentKit. The Xcode targets have no test bundles yet, so we
# build them to make sure they still compile; switch to `xcodebuild test` once
# app-level tests exist.
test: $(PROJECT)
	python3 Scripts/check-debug-guards.py
	swift test
	@for s in $(SCHEMES); do \
		$(XCB) -scheme $$s -configuration Debug build -quiet || exit 1; \
	done

lint:
	@if xcrun --find swift-format >/dev/null 2>&1; then \
		xcrun swift-format lint --recursive Sources Tests; \
	else \
		echo "swift-format not available; skipping lint"; \
	fi

clean:
	rm -rf build .build $(PROJECT)
