.PHONY: build test app run install release icon banner typescript clean

export SDKROOT := $(shell Scripts/sdk.sh)

build:
	swift build 2>&1 | grep -vE "ld: warning: search path" || true

test:
	swift run JaysonCoreChecks 2>&1 | grep -vE "ld: warning: search path"

# Downloads the TypeScript compiler used by pipeline script steps (not committed, ~9 MB).
typescript: Resources/TypeScript/typescript.js

Resources/TypeScript/typescript.js:
	Scripts/fetch-typescript.sh

app: typescript
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

release:
	Scripts/release.sh

icon:
	Scripts/make-icon.sh

banner:
	Scripts/make-banner.sh

clean:
	rm -rf .build build
