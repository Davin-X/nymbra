.PHONY: help build test run pty-test screen-test check clean

help:
	@echo "make build       - release build"
	@echo "make test        - run the test harness"
	@echo "make run         - build and open Nymbra"
	@echo "make pty-test    - headless proof that the PTY runs a login shell"
	@echo "make screen-test - assertions against real shell output, fed through the parser"
	@echo "make check       - everything CI runs (build + tests + headless proofs)"
	@echo "make clean       - remove build output"

build:
	swift build -c release

test:
	swift run -c release NymbraCheck

run: build
	.build/release/Nymbra

pty-test: build
	.build/release/Nymbra --pty-test

screen-test: build
	@Scripts/emulation-checks.sh

check: test pty-test screen-test

clean:
	swift package clean
