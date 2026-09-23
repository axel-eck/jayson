#!/bin/zsh
# Downloads the TypeScript compiler (typescript.js) and the ES2020 standard library
# declarations into Resources/TypeScript so pipeline script steps can transpile and
# type-check TypeScript inside JavaScriptCore. The folder is not committed; run this
# once (or `make typescript`). Set TYPESCRIPT_VERSION to pin a different release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${TYPESCRIPT_VERSION:-5.6.3}"
BASE="https://cdn.jsdelivr.net/npm/typescript@${VERSION}/lib"
DEST="Resources/TypeScript"
mkdir -p "$DEST"

fetch() {
  local name="$1"
  if [[ -s "$DEST/$name" ]]; then return 0; fi
  echo "  $name"
  curl -fsSL --retry 3 -o "$DEST/$name.part" "$BASE/$name"
  mv "$DEST/$name.part" "$DEST/$name"
}

echo "Fetching TypeScript $VERSION into $DEST"
fetch typescript.js

# Follow `/// <reference lib="…" />` directives starting from the ES2020 lib so every
# file the compiler will ask for is present.
typeset -A seen
queue=(lib.es2020.d.ts)
while (( ${#queue} > 0 )); do
  name="${queue[1]}"; shift queue
  [[ -n "${seen[$name]:-}" ]] && continue
  seen[$name]=1
  fetch "$name"
  for ref in $(grep -oE 'reference lib="[^"]+"' "$DEST/$name" | sed -E 's/reference lib="([^"]+)"/\1/'); do
    queue+=("lib.${ref}.d.ts")
  done
done
echo "$VERSION" > "$DEST/VERSION"
echo "Done: $(ls "$DEST" | wc -l | tr -d ' ') files, $(du -sh "$DEST" | cut -f1)"
