#!/usr/bin/env python3
"""Recolour the Jayson logo and lay it out for a macOS app icon.

usage: recolor-logo.py <logo.svg> <out.svg> [--fg HEX] [--bg HEX] [--scale N]

The source logo is black artwork on a white page. Black shapes become the
foreground colour, white shapes become the background colour (so the face of the
shield matches the icon tile), and the white page background is dropped so the
renderer can paint the rounded tile underneath.
"""
import argparse
import pathlib
import re

parser = argparse.ArgumentParser()
parser.add_argument("source")
parser.add_argument("output")
parser.add_argument("--fg", default="#562C2C", help="colour for the black artwork")
parser.add_argument("--bg", default="#EFCB68", help="colour for the white artwork (tile colour)")
parser.add_argument("--scale", type=float, default=1.28, help="scale of the mark inside the 1024pt canvas")
args = parser.parse_args()

svg = pathlib.Path(args.source).read_text()
paths = re.findall(r'<path d="([^"]+)" fill="([^"]+)"', svg)
if not paths:
    raise SystemExit("no <path> elements found in the logo")

body = []
for d, fill in paths:
    if d.startswith("M0 0H1024V1024H0V0Z"):
        continue  # page background
    colour = args.fg if fill.lower() in ("black", "#000", "#000000") else args.bg
    body.append(f'<path d="{d}" fill="{colour}"/>')

s = args.scale
out = (
    '<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">'
    f'<g transform="translate(512 512) scale({s}) translate(-512 -512)">' + "".join(body) + "</g></svg>"
)
pathlib.Path(args.output).write_text(out)
print(f"wrote {args.output} ({len(body)} paths, fg={args.fg}, bg={args.bg})")
