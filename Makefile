# cc-ios — convenience wrappers around tools/*.sh
#
#   make tui       interactive, verifiable setup (live status board)
#   make setup     one-shot onboarding (preflight → assets → project)
#   make doctor    check the build environment
#   make sim       build + run in the iOS Simulator
#   make device    build + sign + install on a connected iPhone
#   make sync      set up wireless (Tailscale) save sync: write + push cc-sync.json
#   make mods      install CCLoader + the in-game mod manager + title buttons
#   make harness   boot the game in a macOS WKWebView (writes proof.png)
#   make assets    (re)copy your CrossCode assets + transcode audio
#   make project   regenerate the Xcode project
#   make clean     remove build output
#
# Most targets just call the scripts in tools/. Pass extra flags via ARGS=, e.g.:
#   make setup ARGS="--yes --with-mods"
#   make device ARGS="--bundle-id com.you.ccios"

ARGS ?=

.PHONY: tui setup doctor sim device sync mods harness assets project clean help

help:
	@grep '^#' Makefile | sed 's/^#//; s/^ //'

tui:
	tools/setup-tui.sh $(ARGS)

setup:
	tools/setup.sh $(ARGS)

doctor:
	tools/preflight.sh $(ARGS)

sim:
	tools/run-sim.sh $(ARGS)

device:
	tools/ios-build.sh $(ARGS)

sync:
	tools/setup-sync.sh $(ARGS)

mods:
	tools/setup-ccloader.sh $(ARGS)
	tools/setup-ccloader.sh --add-mod mods/ccios-title-buttons

harness:
	swift run webkit-harness --settle 8 --out proof.png $(ARGS)

assets:
	tools/sync-assets.sh

project:
	cd app && xcodegen generate

clean:
	rm -rf build app/cc-ios.xcodeproj proof.png
