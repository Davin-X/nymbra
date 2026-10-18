# Where SwiftPM put the products, asked for at parse time rather than assumed:
# `.build/release` is a symlink SwiftPM maintains and it is not always there, and
# asking *inside* a recipe can race the build that just finished.
bin = $(shell swift build -c release --show-bin-path 2>/dev/null)

.PHONY: help build test run app launch install dist pty-test screen-test resize-test window-test tabs-test mouse-test shell-integration-test notify-test lint architecture check clean

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
	@echo "make shell-integration-test - a real zsh, reporting what it is doing"
	@echo "make notify-test - a long command in a background tab, announced"
	@echo "make timeline-test - command history with exit status, duration, directory"
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

# The command palette, driven with real key events. That is the point of it: a
# text field's own `keyDown` is never called while the field is being edited, so
# a palette that reads its arrows there is a palette whose arrows do nothing.
# It also used to throw before drawing its first row, which no review caught.
palette-test: build
	"$(bin)/Nymbra" --palette-test

# Find, end to end: a real shell prints, the bar is typed into, and the highlight
# is judged by the pixels the view draws rather than by its own bookkeeping —
# which is how a highlight drawn a screenful from its match was found.
find-test: build
	"$(bin)/Nymbra" --find-test

# The settings window: what each control loaded, the shortcut recorder's rules,
# and that closing the window releases the event monitor it installs.
settings-test: build
	"$(bin)/Nymbra" --settings-test

mouse-test: build
	"$(bin)/Nymbra" --mouse-test

# Shell integration, asserted against a real zsh: the marks a terminal needs,
# and the user's own startup file still running. Nothing is shown.
shell-integration-test: build
	"$(bin)/Nymbra" --shell-integration-test

# A notification when a command that took a while finishes. The duration is what
# the shell's own marks measure, so this one needs a real zsh as well. Nothing is
# shown, and nothing is actually posted — see the seam in the test.
notify-test: build
	"$(bin)/Nymbra" --notify-test

# Command timeline: every finished command recorded with its line, directory,
# exit status and duration — searchable and persisted. Needs a real zsh with
# shell integration.
timeline-test: build
	"$(bin)/Nymbra" --timeline-test

check: architecture test pty-test screen-test resize-test window-test tabs-test palette-test find-test settings-test mouse-test shell-integration-test notify-test timeline-test

clean:
	swift package clean
