.PHONY: build test app run icon clean

export SDKROOT := $(shell Scripts/sdk.sh)

build:
	swift build 2>&1 | grep -vE "ld: warning: search path" || true

test:
	swift run JaysonCoreChecks 2>&1 | grep -vE "ld: warning: search path"

app:
	Scripts/build-app.sh release

run: app
	open build/Jayson.app

icon:
	Scripts/make-icon.sh

clean:
	rm -rf .build build
