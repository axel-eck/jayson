#!/usr/bin/env python3
"""Writes the Homebrew cask definition for a Jayson release."""
import argparse
import pathlib

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--sha256", required=True)
parser.add_argument("--repo", required=True, help="owner/repo on GitHub")
parser.add_argument("--output", required=True)
parser.add_argument("--notarized", action="store_true", help="omit the quarantine-stripping postflight step")
args = parser.parse_args()

# Not notarized builds: strip the quarantine flag after install so the app opens
# without a right-click > Open (pattern borrowed from briangtn/ScreenAlerts' cask).
postflight = "" if args.notarized else '''
  # Not notarized: drop the quarantine flag so the app opens without a right-click > Open.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Jayson.app"]
  end
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

  depends_on macos: :sonoma

  app "Jayson.app"
{postflight}
  zap trash: [
    "~/Library/Preferences/com.luccasoftware.Jayson.plist",
    "~/Library/Saved Application State/com.luccasoftware.Jayson.savedState",
  ]
end
'''
pathlib.Path(args.output).write_text(cask)
print(f"wrote {args.output}")
