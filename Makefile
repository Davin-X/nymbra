# Where SwiftPM put the products, asked for at parse time rather than assumed:
# `.build/release` is a symlink SwiftPM maintains and it is not always there, and
# asking *inside* a recipe can race the build that just finished.
bin = $(shell swift build -c release --show-bin-path 2>/dev/null)

.PHONY: help build test run app launch install dist pty-test screen-test resize-test window-test tabs-test mouse-test lint architecture check clean

help:
	@echo "make build       - release build"
	@echo "make test        - run the test harness"
	@echo "make lint        - run SwiftLint, if it is installed (not part of check)"
	@echo "make run         - build and open Nymbra from the terminal"
	@echo "make app         - build Nymbra.app, with its icon"
	@echo "make launch      - build Nymbra.app and open it from Finder"
	@echo "make install     - copy Nymbra.app to /Applications (or ~/Applications)"
	@echo "make dist        - zip Nymbra.app so it can be handed to someone else"
	@echo "make pty-test    - headless proof that the PTY runs a login shell"
	@echo "make screen-test - assertions against real shell output, fed through the parser"
	@echo "make resize-test - proof that the view and the shell agree on the grid"
	@echo "make window-test - close a window, get a working one back"
	@echo "make tabs-test   - make, switch and close tabs without a window"
	@echo "make mouse-test  - mouse reporting bytes, asserted headlessly"
	@echo "make check       - everything CI's check job runs (guard + build + tests + proofs)"
	@echo "make clean       - remove build output"

build:
	swift build -c release

# SwiftLint is deliberately not part of `check`, and not part of CI either: the
# job that ran it was removed and `.swiftlint.yml` went with it. The target stays
# for anyone who keeps their own config, but a *strict* lint with no config fails
# on a codebase that never adopted the default rules — which made `make check`
# red on any machine that happened to have swiftlint installed, and red for a
# different reason (`sourcekitdInProc` failing to load under Command Line Tools
# alone) on any machine that had it but no full Xcode. Neither is a statement
# about this code.
lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict; \
	else \
		echo "swiftlint not installed; skipping (add one and 'make lint' will run it)"; \
	fi

# The guard CI runs first. The core targets must stay UI-free, and until this was
# a prerequisite of `check` the promise in `make help` — that `check` runs what CI
# runs — was not quite true.
architecture:
	@Scripts/check-architecture.sh

# `build` first, deliberately: the suite starts real shells, and the program
# that gives a shell its terminal (NymbraSpawn) is looked for beside the binary
# that is running. `swift run` on its own is not guaranteed to have built it.
test: build
	swift run -c release NymbraCheck

run: build
	"$(bin)/Nymbra"

app:
	@Scripts/make-app.sh

launch: app
	open build/Nymbra.app

install: app
	@if [ -w /Applications ]; then \
		rm -rf /Applications/Nymbra.app; \
		cp -R build/Nymbra.app /Applications/; \
		echo "installed: /Applications/Nymbra.app"; \
	else \
		mkdir -p "$(HOME)/Applications"; \
		rm -rf "$(HOME)/Applications/Nymbra.app"; \
		cp -R build/Nymbra.app "$(HOME)/Applications/"; \
		echo "installed: $(HOME)/Applications/Nymbra.app"; \
	fi

dist: app
	@rm -f build/Nymbra.zip
	@cd build && xattr -cr Nymbra.app 2>/dev/null || true
	@cd build && ditto -c -k --keepParent --noextattr --norsrc Nymbra.app Nymbra.zip
	@echo "dist: build/Nymbra.zip ($$(du -h build/Nymbra.zip | cut -f1))"

pty-test: build
	"$(bin)/Nymbra" --pty-test

screen-test: build
	@Scripts/emulation-checks.sh

resize-test: build
	"$(bin)/Nymbra" --resize-test

# Closing the window with the red button used to be a dead end. A window is
# created here, but never shown, and the shell it starts is a real one.
window-test: build
	"$(bin)/Nymbra" --window-test

tabs-test: build
	"$(bin)/Nymbra" --tabs-test
mouse-test: build
	"$(bin)/Nymbra" --mouse-test

check: architecture test pty-test screen-test resize-test window-test tabs-test mouse-test

clean:
	swift package clean
