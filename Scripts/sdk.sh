#!/bin/zsh
# Selects a macOS SDK the Command Line Tools can fully compile SwiftUI against.
# Beta SDKs (e.g. MacOSX27) turn @State into a macro whose plugin only ships with Xcode,
# so prefer the newest non-beta SDK when the default one is newer than the running OS.
sdks_dir="/Library/Developer/CommandLineTools/SDKs"
os_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ -n "${SDKROOT:-}" ]]; then
  echo "$SDKROOT"
  exit 0
fi
candidate=""
for sdk in "$sdks_dir"/MacOSX${os_major}*.sdk(N) "$sdks_dir"/MacOSX*.sdk(N); do
  if [[ -d "$sdk" && ! -L "$sdk" ]]; then candidate="$sdk"; break; fi
done
echo "${candidate:-$(xcrun --show-sdk-path)}"
