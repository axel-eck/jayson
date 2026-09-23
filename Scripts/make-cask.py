#!/usr/bin/env python3
"""Writes the Homebrew cask definition for a Jayson release."""
import argparse
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--sha256", required=True)
parser.add_argument("--repo", required=True, help="owner/repo on GitHub")
parser.add_argument("--output", required=True)
parser.add_argument("--notarized", action="store_true", help="omit the quarantine caveat")
args = parser.parse_args()

caveat = "" if args.notarized else '''
  caveats <<~EOS
    Jayson is not notarized with an Apple Developer ID yet, so Gatekeeper will
    refuse to open it the first time. Either remove the quarantine flag:

      xattr -dr com.apple.quarantine "#{appdir}/Jayson.app"

    or right-click Jayson.app in #{appdir} and choose Open once.
  EOS
'''

cask = f'''cask "jayson" do
  version "{args.version}"
  sha256 "{args.sha256}"

  url "https://github.com/{args.repo}/releases/download/v#{{version}}/Jayson-#{{version}}.zip"
  name "Jayson"
  desc "JSON viewer and editor with JSONPath search and JSON Schema validation"
  homepage "https://github.com/{args.repo}"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Jayson.app"

  zap trash: [
    "~/Library/Preferences/com.luccasoftware.Jayson.plist",
    "~/Library/Saved Application State/com.luccasoftware.Jayson.savedState",
  ]
{caveat}end
'''
pathlib.Path(args.output).write_text(cask)
print(f"wrote {args.output}")
