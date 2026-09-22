.PHONY: build test app run install icon clean

export SDKROOT := $(shell Scripts/sdk.sh)

build:
	swift build 2>&1 | grep -vE "ld: warning: search path" || true

test:
	swift run JaysonCoreChecks 2>&1 | grep -vE "ld: warning: search path"

app:
	Scripts/build-app.sh release

run: app
	open build/Jayson.app

# Copies the release build into ~/Applications so Spotlight and Launchpad can find it.
# (Spotlight does not reliably index symlinked .app bundles, hence a copy.)
INSTALL_DIR ?= $(HOME)/Applications
install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/Jayson.app"
	ditto build/Jayson.app "$(INSTALL_DIR)/Jayson.app"
	@echo "Installed to $(INSTALL_DIR)/Jayson.app"

icon:
	Scripts/make-icon.sh

clean:
	rm -rf .build build
