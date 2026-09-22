#!/bin/zsh
# Builds Assets/AppIcon.icns from Assets/logo.svg.
# usage: Scripts/make-icon.sh [--fg HEX] [--bg HEX]
set -euo pipefail
cd "$(dirname "$0")/.."

FG="#562C2C"
BG="#EFCB68"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fg) FG="$2"; shift 2 ;;
    --bg) BG="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

mkdir -p build/icon
python3 Scripts/recolor-logo.py Assets/logo.svg build/icon/mark.svg --fg "$FG" --bg "$BG"
rm -rf build/icon/AppIcon.iconset
swift Scripts/RenderIcon.swift build/icon/mark.svg build/icon/AppIcon.iconset "$BG"
iconutil -c icns build/icon/AppIcon.iconset -o Assets/AppIcon.icns
cp build/icon/AppIcon.iconset/icon_256x256.png Assets/AppIcon-256.png
echo "Wrote Assets/AppIcon.icns and Assets/AppIcon-256.png"
