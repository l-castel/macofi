PREFIX   ?= $(HOME)/.local
APPDIR   ?= /Applications
VERSION  := $(shell cat VERSION)
# Space-separated; e.g. ARCHS="arm64 x86_64" for a universal binary.
ARCHS    ?= $(shell uname -m)
# Code signing: "-" is ad-hoc. Set to a "Developer ID Application: …" identity to sign for
# distribution, and NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile to notarize.
SIGN_IDENTITY  ?= -
NOTARY_PROFILE ?=
GITHUB_REPO    ?= l-castel/macofi

SOURCES  := $(filter-out Sources/macofi/DefaultConfig.swift,$(wildcard Sources/macofi/*.swift))
APP      := build/Macofi.app
DIST     := build/dist
SIGN_FLAGS := $(if $(filter -,$(SIGN_IDENTITY)),,--options runtime --timestamp)

.PHONY: all icon app install uninstall config daemon undaemon matugen dist release clean

all: build/macofi

Sources/macofi/DefaultConfig.swift: config.example.toml
	{ echo '// Generated from config.example.toml by `make`; edit that file instead.'; \
	  echo 'let defaultConfigText = #"""'; cat $<; echo '"""#'; } > $@

build/Version.swift: VERSION
	@mkdir -p build
	echo 'let macofiVersion = "$(VERSION)"' > $@

build/MatugenTemplate.swift: matugen/macofi-colors.toml
	@mkdir -p build
	{ echo 'let matugenTemplate = #"""'; cat $<; echo '"""#'; } > $@

build/macofi: $(SOURCES) Sources/macofi/DefaultConfig.swift build/Version.swift build/MatugenTemplate.swift
	@mkdir -p build
	@for arch in $(ARCHS); do \
	  echo "swiftc ($$arch)"; \
	  swiftc -O -swift-version 5 -target $$arch-apple-macos13.0 \
	    -framework AppKit -framework Carbon $^ -o build/macofi-$$arch || exit 1; \
	done
	lipo -create $(foreach a,$(ARCHS),build/macofi-$(a)) -output $@

# Regenerates packaging/Macofi.icns and docs/icon.png from scripts/make-icon.swift.
icon:
	@mkdir -p build docs
	swiftc -O scripts/make-icon.swift -o build/make-icon
	rm -rf build/Macofi.iconset && build/make-icon build/Macofi.iconset docs/icon.png
	iconutil -c icns build/Macofi.iconset -o packaging/Macofi.icns

# An .app bundle (LSUIElement, so it never shows in the Dock).
app: build/macofi
	@rm -rf $(APP) && mkdir -p $(APP)/Contents/MacOS
	cp build/macofi $(APP)/Contents/MacOS/macofi
	cp Info.plist $(APP)/Contents/Info.plist
	@mkdir -p $(APP)/Contents/Resources
	cp packaging/Macofi.icns $(APP)/Contents/Resources/Macofi.icns
	plutil -replace CFBundleShortVersionString -string $(VERSION) $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string $(VERSION) $(APP)/Contents/Info.plist
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" $(APP)

install: app
	@mkdir -p $(PREFIX)/bin $(APPDIR)
	rm -rf $(APPDIR)/Macofi.app
	cp -R $(APP) $(APPDIR)/Macofi.app
	ln -sf $(APPDIR)/Macofi.app/Contents/MacOS/macofi $(PREFIX)/bin/macofi
	@echo "installed: $(APPDIR)/Macofi.app and $(PREFIX)/bin/macofi"
	@[ -t 0 ] && $(APPDIR)/Macofi.app/Contents/MacOS/macofi --setup-matugen || true

config:
	@mkdir -p $(HOME)/.config/macofi
	@if [ -e $(HOME)/.config/macofi/config.toml ]; then echo "~/.config/macofi/config.toml already exists"; \
	else cp config.example.toml $(HOME)/.config/macofi/config.toml && echo "wrote ~/.config/macofi/config.toml"; fi

AGENT := $(HOME)/Library/LaunchAgents/dev.macofi.plist

# Run `macofi --daemon` at login so the hotkey from the config is always live.
daemon: install
	@mkdir -p $(dir $(AGENT))
	@printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>Label</key><string>dev.macofi</string>' \
	  '<key>ProgramArguments</key><array><string>$(APPDIR)/Macofi.app/Contents/MacOS/macofi</string><string>--daemon</string></array>' \
	  '<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>' \
	  '<key>StandardErrorPath</key><string>$(HOME)/Library/Logs/macofi.log</string>' \
	  '</dict></plist>' > $(AGENT)
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "daemon running; it starts automatically at login"

undaemon:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)

# Ask (again) whether macofi may register its template with matugen. See README.
matugen: build/macofi
	build/macofi --setup-matugen

uninstall: undaemon
	rm -rf $(APPDIR)/Macofi.app $(PREFIX)/bin/macofi

# Release artifacts in build/dist: a .dmg and .zip of the app, plus a source tarball for the
# Homebrew formula (which builds on the user's machine, so it needs no signing).
dist: app
	@rm -rf $(DIST) && mkdir -p $(DIST)/dmg
	cp -R $(APP) $(DIST)/dmg/Macofi.app
	ln -s /Applications $(DIST)/dmg/Applications
	cp README.md LICENSE config.example.toml $(DIST)/dmg/
	hdiutil create -quiet -volname "Macofi $(VERSION)" -srcfolder $(DIST)/dmg -format UDZO -ov $(DIST)/Macofi-$(VERSION).dmg
	@rm -rf $(DIST)/dmg
	$(if $(filter -,$(SIGN_IDENTITY)),,codesign --force --timestamp --sign "$(SIGN_IDENTITY)" $(DIST)/Macofi-$(VERSION).dmg)
	$(if $(NOTARY_PROFILE),xcrun notarytool submit $(DIST)/Macofi-$(VERSION).dmg --keychain-profile "$(NOTARY_PROFILE)" --wait && xcrun stapler staple $(DIST)/Macofi-$(VERSION).dmg)
	ditto -c -k --keepParent $(APP) $(DIST)/Macofi-$(VERSION).zip
	tar -czf $(DIST)/macofi-$(VERSION)-src.tar.gz -s ',^,macofi-$(VERSION)/,' \
	  Makefile VERSION LICENSE Info.plist README.md config.example.toml Sources matugen packaging scripts
	@echo "artifacts in $(DIST):" && ls -1 $(DIST)

# dist + Formula/macofi.rb and Casks/macofi.rb with the right version and checksums.
# Upload build/dist/* to the GitHub release v$(VERSION), then commit Formula/ and Casks/.
release: dist
	scripts/render-brew.sh $(VERSION) $(GITHUB_REPO) $(DIST)

clean:
	rm -rf build
