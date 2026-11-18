#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
bundle="${1:-"$root/build/纸笺.app"}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$root/Resources/prepare_paper_notes.py" "$root/Resources/transcription_prompt.txt" \
  "$root/Resources/PaperNotes.icns" "$root/Resources/preview.html" \
  "$root/Resources/preview.bundle.js" "$bundle/Contents/Resources/"
cp -R "$root/Resources/PreviewLicenses" "$bundle/Contents/Resources/"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
  "$root"/Sources/*.swift -o "$bundle/Contents/MacOS/PaperNotes"
codesign --force --sign - "$bundle"
