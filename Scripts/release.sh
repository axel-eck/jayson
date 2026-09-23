#!/bin/zsh
# Produces a distributable release: universal app, zip, SHA-256, and a Homebrew cask file.
#
# usage: Scripts/release.sh
#
# Environment:
#   GITHUB_REPO        owner/repo hosting the GitHub Releases (default: axel-eck/jayson)
#   HOMEBREW_TAP       owner/tap-name users will `brew tap` (default: axel-eck/tap)
#   CODESIGN_IDENTITY  Developer ID identity; when set together with NOTARY_PROFILE the
#                      zip is notarized and the app stapled
#   NOTARY_PROFILE     keychain profile created with `xcrun notarytool store-credentials`
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
GITHUB_REPO="${GITHUB_REPO:-axel-eck/jayson}"
HOMEBREW_TAP="${HOMEBREW_TAP:-axel-eck/tap}"
DIST="dist"
ZIP="$DIST/Jayson-$VERSION.zip"

Scripts/fetch-typescript.sh
Scripts/build-app.sh release --universal
rm -rf "$DIST" && mkdir -p "$DIST"

if [[ -n "${CODESIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent build/Jayson.app "$DIST/notarize.zip"
  xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/Jayson.app
  rm "$DIST/notarize.zip"
fi

ditto -c -k --keepParent build/Jayson.app "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

python3 Scripts/make-cask.py \
  --version "$VERSION" --sha256 "$SHA" --repo "$GITHUB_REPO" \
  --output "$DIST/jayson.rb"

cat <<MSG

Release v$VERSION
  archive : $ZIP
  sha256  : $SHA
  cask    : $DIST/jayson.rb

Next steps:
  git tag v$VERSION && git push origin v$VERSION
  gh release create v$VERSION "$ZIP" --title "Jayson $VERSION" --generate-notes
  copy $DIST/jayson.rb to the tap repo as Casks/jayson.rb and push

Users then run:
  brew install --cask $HOMEBREW_TAP/jayson
MSG
