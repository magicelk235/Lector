#!/bin/bash
# Builds a distributable Lector: universal, signed with Developer ID, notarized and
# stapled, as Lector.dmg for downloading, plus the Sparkle update channel (a zip of the
# app and a signed appcast.xml) for the copies already installed.
#
# Needs, once per Mac:
#   - a "Developer ID Application" certificate in the login keychain;
#   - notarization credentials saved with
#     `xcrun notarytool store-credentials <profile> --apple-id … --team-id V8K8L3ZSD5`
#     (the profile name goes in NOTARY_PROFILE; the team's existing one is the default);
#   - Sparkle's EdDSA private key in the login keychain (Sparkle's `generate_keys`);
#     its public half is SUPublicEDKey in project.yml.
#
# Usage: Scripts/release.sh                 build, sign, notarize, staple, appcast
#        Scripts/release.sh --no-notarize   stop after the signed DMG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build"
REL="$DERIVED/Build/Products/Release"
# Signing happens outside the repo: a synced folder can stamp Finder info on the bundle
# mid-sign, which codesign rejects as "detritus".
WORK="/private/tmp/lector-release"
APP="$WORK/Lector.app"
ENTITLEMENTS="$ROOT/Lector.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-viaduct-notary}"
OUT="$ROOT/Lector.dmg"
DIST="$ROOT/dist"
NOTARIZE=1
[ "${1:-}" = "--no-notarize" ] && NOTARIZE=0

SIGN_ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | grep -oE '[A-F0-9]{40}')"
[ -n "$SIGN_ID" ] || { echo "FAILED: no Developer ID Application identity in the keychain"; exit 1; }
echo "==> Signing identity: $SIGN_ID"

# The Xcode project is generated from project.yml; without this a bumped version never
# reaches Info.plist, and Sparkle would see no update.
echo "==> Generating the Xcode project"
(cd "$ROOT" && xcodegen generate --quiet)

echo "==> Building (Release, arm64 + x86_64, unsigned)"
rm -rf "$REL"
# The generic destination keeps both architectures; "My Mac" would build only this one.
xcodebuild -project "$ROOT/Lector.xcodeproj" -scheme Lector -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO >/dev/null

echo "==> Staging in $WORK"
rm -rf "$WORK" && mkdir -p "$WORK"
ditto "$REL/Lector.app" "$APP"
rm -rf "$REL/Lector.app"

ARCHS="$(lipo -archs "$APP/Contents/MacOS/Lector")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ;;
  *) echo "FAILED: built for '$ARCHS' only"; exit 1 ;;
esac

# Inside out: Sparkle's helpers, then every framework, then the app. A secure
# timestamp and the hardened runtime are what notarization requires, and any nested
# executable left unsigned fails it for the whole app.
echo "==> Signing"
xattr -cr "$APP"
sign() { codesign --force --sign "$SIGN_ID" --timestamp --options runtime "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE/Versions/B/XPCServices/"*.xpc "$SPARKLE/Versions/B/Updater.app" \
            "$SPARKLE/Versions/B/Autoupdate"; do
  [ -e "$item" ] && sign "$item"
done
for framework in "$APP/Contents/Frameworks/"*.framework; do
  sign "$framework"
done
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
WANT="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml" | head -1)"
[ "$VERSION" = "$WANT" ] || { echo "FAILED: built $VERSION, but project.yml says $WANT"; exit 1; }

echo "==> Building Lector.dmg ($VERSION)"
rm -f "$OUT"
create-dmg \
  --volname "Lector" \
  --window-pos 200 120 \
  --window-size 600 380 \
  --icon-size 128 \
  --icon "Lector.app" 160 170 \
  --app-drop-link 440 170 \
  --hide-extension "Lector.app" \
  --no-internet-enable \
  "$OUT" "$APP" >/dev/null
# A signed DMG lets Gatekeeper check the disk image itself, not only the app inside.
codesign --sign "$SIGN_ID" --timestamp "$OUT"

if [ "$NOTARIZE" = 0 ]; then
  rm -rf "$WORK"
  echo "==> Done, not notarized: $OUT (other Macs will refuse to open it)"
  exit 0
fi

echo "==> Notarizing (waits for Apple, usually a few minutes)"
xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$OUT"
xcrun stapler validate "$OUT"
# Sparkle installs the app from the zip, with no DMG around it, so the app needs its own
# ticket to open on a Mac that's offline. The DMG's notarization covers it.
xcrun stapler staple "$APP"

echo "==> Packaging the update"
rm -rf "$DIST" && mkdir -p "$DIST"
ZIP="$DIST/Lector-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$WORK"

GEN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "$GEN" ] || { echo "FAILED: generate_appcast not found at $GEN"; exit 1; }
# Only this release's zip is in dist, so the feed has one item: all Sparkle needs.
"$GEN" "$DIST" -o "$DIST/appcast.xml" \
  --download-url-prefix "https://github.com/magicelk235/Lector/releases/download/v$VERSION/"

echo "==> Done: $OUT, $ZIP, $DIST/appcast.xml"
echo "Publish with tag v$VERSION, or the appcast's download URL breaks:"
echo "  gh release create v$VERSION \"$OUT\" \"$ZIP\" \"$DIST/appcast.xml\" --title \"Lector $VERSION\" --notes-file notes.md"
