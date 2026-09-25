#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build -c release --package-path "$ROOT"
APP="$ROOT/.build/Toastune.app"
RES="$ROOT/Sources/Toastune/Resources"
# Start from an empty bundle so files from earlier builds never linger.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Toastune" "$APP/Contents/MacOS/Toastune"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$RES/spotify.js" "$APP/Contents/Resources/spotify.js"
cp "$RES/music.js" "$APP/Contents/Resources/music.js"
cp -R "$RES/en.lproj" "$RES/zh-Hans.lproj" "$APP/Contents/Resources/"
# The Icon Composer icon needs Xcode's actool; without it, fall back to the prebuilt .icns.
if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$RES/AppIcon.icon" --compile "$APP/Contents/Resources" --platform macosx \
        --minimum-deployment-target 14.0 --app-icon AppIcon \
        --output-partial-info-plist "$ROOT/.build/icon-partial.plist" >/dev/null
else
    cp "$RES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Signs ad hoc by default. Set SIGN_IDENTITY (e.g. an "Apple Development" identity) so that
# notification and automation permissions survive rebuilds. The hardened runtime blocks Apple
# Events unless the entitlement allows them, which the player scripts depend on.
codesign --force --options runtime --entitlements "$ROOT/Toastune.entitlements" \
    --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
