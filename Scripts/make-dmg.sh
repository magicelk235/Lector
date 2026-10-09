#!/bin/bash
# Packages a Lector.app as the disk image people download: the app and an Applications
# link on the background from make-dmg-background.swift. Signing and notarizing the
# image are release.sh's.
#
# Plain hdiutil and a short Finder script: create-dmg's own Finder script fails on
# recent macOS, and only Finder writes a background that Finder will show.
#
# Usage: Scripts/make-dmg.sh <Lector.app> <output.dmg>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: make-dmg.sh <Lector.app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <Lector.app> <output.dmg>}"
[ -d "$APP" ] || { echo "FAILED: no app at $APP"; exit 1; }

VOL="Lector"
# Finder finds the disk by name, and only under /Volumes.
MOUNT="/Volumes/$VOL"
[ -e "$MOUNT" ] && { echo "FAILED: eject the Lector disk that's mounted at $MOUNT first"; exit 1; }
STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; rm -rf "$STAGE" "$RW"' EXIT

ditto "$APP" "$STAGE/Lector.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
swift "$ROOT/Scripts/make-dmg-background.swift" "$STAGE/.background/background.png"

hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -mountpoint "$MOUNT" -nobrowse -noautoopen >/dev/null
xcrun SetFile -a E "$MOUNT/Lector.app"
chflags hidden "$MOUNT/.background"

# The icon positions match the background's 640×440 layout. Finder keeps a strip above
# the icons even with the toolbar hidden, 68 points on macOS 27, so the window is that
# much taller than the background.
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set pathbar visible of container window to false
    set the bounds of container window to {200, 120, 840, 628}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.png"
    -- Out of sight for anyone whose Finder shows hidden files.
    set position of item ".background" of container window to {900, 160}
    set position of item "Lector.app" of container window to {180, 300}
    set position of item "Applications" of container window to {460, 300}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# The disk's icon is Lector's. Only now: Finder's `update` above deletes a volume icon,
# but without it Finder doesn't keep the path bar hidden.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
chflags hidden "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT"
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set position of item ".VolumeIcon.icns" of container window to {900, 300}
    delay 1
    close
  end tell
end tell
EOF

sync
# Finder can hold on to the volume for a moment after closing its window.
for attempt in 1 2 3 4 5; do
  hdiutil detach "$MOUNT" >/dev/null 2>&1 && break
  [ "$attempt" = 5 ] && hdiutil detach "$MOUNT" -force >/dev/null
  sleep 1
done
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
