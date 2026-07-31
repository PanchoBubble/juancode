# juancode — build and launch the native app without an Xcode project.
#
# There's no signed release to download yet, so building from source is the way in:
#   make dev        fast debug build, then relaunch the app
#   make run        release build, then relaunch the app
#   make install    release build into ~/Applications (then Spotlight it)
#
# Everything is plain SwiftPM + pnpm underneath; nothing here is required to work
# on the repo.

.DEFAULT_GOAL := help
SHELL := /bin/bash

NATIVE      := apps/native
CONFIG      ?= release
APP         := $(NATIVE)/.build/juancode.app
INSTALL_DIR ?= $(HOME)/Applications
INSTALLED   := $(INSTALL_DIR)/juancode.app

.PHONY: help setup build bundle run dev install uninstall stop test check sidecar clean

help: ## Show this help
	@echo "juancode targets:"
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| sed -e 's/:.*## /\t/' \
		| awk -F'\t' '{ printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2 }'
	@echo
	@echo "  Requires: Swift 6 toolchain (Xcode 16+), Node >= 22, pnpm, and"
	@echo "  \`claude\` and/or \`codex\` on PATH and signed in."
	@echo "  Override the build config with CONFIG=debug|release (default: $(CONFIG))."

setup: ## Install the sidecar's Node dependencies
	pnpm install

build: ## Build the native app (release unless CONFIG=debug)
	cd $(NATIVE) && swift build -c $(CONFIG)

bundle: build ## Build and wrap it in juancode.app
	@scripts/bundle-app.sh $(CONFIG) $(abspath $(APP))

run: bundle stop ## Build, then (re)launch juancode.app
	@open $(APP)
	@echo "launched $(APP)"

dev: ## Fast debug build, then relaunch — the iteration loop
	@$(MAKE) --no-print-directory run CONFIG=debug

install: bundle stop ## Build a release bundle into ~/Applications and launch it
	@mkdir -p $(INSTALL_DIR)
	@rm -rf "$(INSTALLED)"
	@cp -R $(APP) "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "installed $(INSTALLED) — it's in Spotlight now"

uninstall: ## Remove the installed app (leaves ~/.juancode data alone)
	@rm -rf "$(INSTALLED)" && echo "removed $(INSTALLED)"

stop: ## Quit a running juancode (its agent sessions go with it)
	@# ps rather than pkill: pkill can't see the app when make runs inside a sandbox.
	@pids=$$(ps -eo pid=,command= | awk '/juancode\.app\/Contents\/MacOS\/juancode/ {print $$1}'); \
	if [ -n "$$pids" ]; then kill $$pids 2>/dev/null || true; sleep 1; fi

test: ## Run the Swift and Node test suites
	cd $(NATIVE) && swift test
	pnpm test

check: ## Everything CI would care about: typecheck, lint, both test suites
	pnpm check
	cd $(NATIVE) && swift test

sidecar: ## Run the Telegram/phone sidecar (needs the app running on :4280)
	pnpm dev:oracle

clean: ## Delete build products
	rm -rf $(NATIVE)/.build
