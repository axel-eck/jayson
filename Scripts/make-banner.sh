#!/bin/zsh
# Builds Assets/banner.svg and Assets/banner.png (the README header) from Assets/logo.svg.
# Needs the Raleway family installed (https://fonts.google.com/specimen/Raleway).
# usage: Scripts/make-banner.sh [--fg HEX] [--bg HEX] [--font PostScriptName]
set -euo pipefail
cd "$(dirname "$0")/.."

FG="#562C2C"
BG="#EFCB68"
FONT="RalewayRoman-SemiBold"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fg) FG="$2"; shift 2 ;;
    --bg) BG="$2"; shift 2 ;;
    --font) FONT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done

mkdir -p build/banner
python3 Scripts/recolor-logo.py Assets/logo.svg build/banner/mark.svg --fg "$FG" --bg "$BG" --scale 1
swift Scripts/RenderBanner.swift build/banner/mark.svg Assets/banner.svg Assets/banner.png --fg "$FG" --bg "$BG" --font "$FONT"
